# frozen_string_literal: true

require "net/http"
require "json"

module DiscourseJournals
  class MappingApplier
    class PausedError < StandardError; end

    API_BASE_URL = "https://journal.scholay.com/api/open/journals"
    BYIDS_BATCH_SIZE = 50
    API_CONCURRENCY = 4
    UPSERT_CONCURRENCY = 4
    DELETE_BATCH_SIZE = BulkTopicDeleter::BATCH_SIZE
    GC_EVERY_N_GROUPS = 2
    COVER_JOB_BATCH_SIZE = 200

    attr_reader :stats

    def initialize(analysis:, progress_callback: nil, cancel_check: nil, resume_checkpoint: nil, resume_stats: nil)
      @analysis = analysis
      @progress_callback = progress_callback
      @cancel_check = cancel_check
      @rate_limiter = ApiRateLimiter.new
      @checkpoint = (resume_checkpoint || {}).transform_keys(&:to_s)
      @update_map = {}
      @create_ids = []
      @topics_to_delete = []
      @stats = (resume_stats || { deleted: 0, updated: 0, created: 0, skipped: 0, errors: 0 }).transform_keys(&:to_sym)
      @system_user = Discourse.system_user
      @cover_topic_ids = []
      @mutex = Mutex.new
    end

    def run!
      build_action_plan

      resume_phase = @checkpoint["phase"]
      total_actions = @update_map.size + @create_ids.size

      Rails.logger.info(
        "[DiscourseJournals::MappingApplier] run! phase=#{resume_phase.inspect}, " \
        "checkpoint=#{@checkpoint.inspect}, stats=#{@stats.inspect}, " \
        "api_actions=#{total_actions}, deletes=#{@topics_to_delete.size}",
      )

      if resume_phase == "api_sync"
        Rails.logger.info("[DiscourseJournals::MappingApplier] SKIPPING deletes, resuming api_sync at offset #{@checkpoint["api_offset"]}")
        execute_api_sync(skip_offset: @checkpoint["api_offset"].to_i)
      else
        delete_offset = resume_phase == "deletes" ? @checkpoint["delete_offset"].to_i : 0
        Rails.logger.info("[DiscourseJournals::MappingApplier] Starting deletes at offset #{delete_offset}")
        execute_deletes(skip_offset: delete_offset)
        execute_api_sync(skip_offset: 0)
      end

      enqueue_cover_jobs
      JournalTagManager.reset_cache!

      @stats
    end

    private

    def check_cancelled!
      raise PausedError, "应用已被用户暂停" if @cancel_check&.call
    end

    def publish_progress(percent, message)
      @progress_callback&.call(percent, message, @stats)
    end

    def save_checkpoint(phase, offset_key, offset_value)
      cp = { "phase" => phase, offset_key => offset_value }
      @analysis.update_columns(apply_checkpoint: cp)
    end

    def increment_stat(key, amount = 1)
      @mutex.synchronize { @stats[key] += amount }
    end

    def build_action_plan
      publish_progress(0, "正在构建执行计划...")

      details = MappingAnalysis
        .where(id: @analysis.id)
        .pick(:details_data) || {}

      plan = details["_action_plan"]

      if plan
        @update_map = (plan["updates"] || {}).transform_keys(&:to_i).transform_values(&:to_i)
        @create_ids = (plan["creates"] || []).map(&:to_i)
        @topics_to_delete = (plan["deletes"] || []).map(&:to_i)
      else
        process_exact_matches(details["exact_1to1"] || [])
        process_forum_1_to_api_n(details["forum_1_to_api_n"] || [])
        process_forum_n_to_api_1(details["forum_n_to_api_1"] || [])
        process_forum_n_to_api_m(details["forum_n_to_api_m"] || [])
        process_forum_only(details["forum_only"] || [])
        process_api_only(details["api_only"] || [])
      end

      details = nil
      GC.start

      total_actions = @update_map.size + @create_ids.size
      total_deletes = @topics_to_delete.size
      publish_progress(
        1,
        "执行计划已构建：#{total_actions} 个 API 操作（更新+新建），#{total_deletes} 个话题待删除",
      )
    end

    def process_exact_matches(entries)
      entries.each do |entry|
        forum = entry["forum"]&.first
        api = entry["api"]&.first
        next unless forum && api
        @update_map[api["api_id"]] = forum["topic_id"]
      end
    end

    def process_forum_1_to_api_n(entries)
      entries.each do |entry|
        forum = entry["forum"]&.first
        apis = entry["api"] || []
        next unless forum && apis.any?

        apis.each_with_index do |api, idx|
          if idx == 0
            @update_map[api["api_id"]] = forum["topic_id"]
          else
            @create_ids << api["api_id"]
          end
        end
      end
    end

    def process_forum_n_to_api_1(entries)
      entries.each do |entry|
        forums = entry["forum"] || []
        api = entry["api"]&.first
        next unless forums.any? && api

        @update_map[api["api_id"]] = forums.first["topic_id"]
        forums[1..].each do |f|
          @topics_to_delete << f["topic_id"]
        end
      end
    end

    def process_forum_n_to_api_m(entries)
      entries.each do |entry|
        forums = entry["forum"] || []
        apis = entry["api"] || []
        next if forums.empty? || apis.empty?

        pair_count = [forums.size, apis.size].min

        pair_count.times do |i|
          @update_map[apis[i]["api_id"]] = forums[i]["topic_id"]
        end

        if forums.size > pair_count
          forums[pair_count..].each { |f| @topics_to_delete << f["topic_id"] }
        end

        if apis.size > pair_count
          apis[pair_count..].each { |a| @create_ids << a["api_id"] }
        end
      end
    end

    def process_forum_only(entries)
      entries.each do |entry|
        (entry["forum"] || []).each { |f| @topics_to_delete << f["topic_id"] }
      end
    end

    def process_api_only(entries)
      entries.each do |entry|
        apis = entry["api"] || []
        next if apis.empty?
        @create_ids << apis.first["api_id"]
      end
    end

    def all_api_ids
      @update_map.keys + @create_ids
    end

    def lookup_action(api_id)
      topic_id = @update_map[api_id]
      if topic_id
        [:update, topic_id]
      else
        [:create, nil]
      end
    end

    # ──── Phase 1: Bulk SQL delete of orphaned / excess topics ────
    def execute_deletes(skip_offset: 0)
      total = @topics_to_delete.size
      return if total.zero?

      remaining_ids = @topics_to_delete[skip_offset..] || []
      return if remaining_ids.empty?

      publish_progress(2, "开始批量删除多余话题 (共 #{total} 个，从 ##{skip_offset + 1} 继续)...")

      base_offset = skip_offset

      remaining_ids.each_slice(DELETE_BATCH_SIZE).with_index do |batch_ids, batch_idx|
        check_cancelled!

        deleted_count = bulk_delete_topic_batch(batch_ids)
        increment_stat(:deleted, deleted_count)
        skipped = batch_ids.size - deleted_count
        increment_stat(:skipped, skipped) if skipped > 0

        processed = base_offset + [((batch_idx + 1) * DELETE_BATCH_SIZE), remaining_ids.size].min
        processed = [processed, total].min

        save_checkpoint("deletes", "delete_offset", processed)
        persist_stats

        pct = (2 + processed.to_f / total * 3).round(1)
        publish_progress(pct, "批量删除中... #{processed}/#{total} (已删除 #{@stats[:deleted]})")
      end

      save_checkpoint("deletes", "delete_offset", total)
      persist_stats
      update_category_stats_after_delete
      publish_progress(5, "删除完成：#{@stats[:deleted]} 个话题已永久删除")
    end

    def bulk_delete_topic_batch(topic_ids)
      BulkTopicDeleter.delete_batch(topic_ids)
    end

    def update_category_stats_after_delete
      BulkTopicDeleter.update_category_stats(SiteSetting.discourse_journals_category_id)
    end

    # ──── Phase 2: Pipeline fetch + parallel transform/upsert ────
    def execute_api_sync(skip_offset: 0)
      ids = all_api_ids
      total = ids.size
      return if total.zero?

      remaining_ids = ids[skip_offset..] || []
      return if remaining_ids.empty?

      Rails.logger.info(
        "[DiscourseJournals::MappingApplier] execute_api_sync: total=#{total}, skip_offset=#{skip_offset}, remaining=#{remaining_ids.size}",
      )
      publish_progress(5, "开始同步 API 数据 (共 #{total} 条，从 ##{skip_offset + 1} 继续)...")

      JournalTagManager.warm_caches!

      processed = 0
      base_offset = skip_offset
      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      connections = API_CONCURRENCY.times.map { create_persistent_connection }

      begin
        batch_groups = remaining_ids.each_slice(BYIDS_BATCH_SIZE).each_slice(API_CONCURRENCY).to_a
        prefetch_rows = nil
        prefetch_thread = nil

        batch_groups.each_with_index do |concurrent_batches, batch_group_idx|
          check_cancelled!

          rows = if prefetch_thread
            prefetch_thread.join
            r = prefetch_rows
            prefetch_thread = nil
            prefetch_rows = nil
            r
          else
            safe_fetch(connections, concurrent_batches)
          end

          next_group = batch_groups[batch_group_idx + 1]
          if next_group
            prefetch_thread = Thread.new do
              prefetch_rows = safe_fetch(connections, next_group)
            end
          end

          prepared_items = parallel_transform(rows)
          rows = nil

          updates, creates = prepared_items.partition { |item| item[:action] == :update }

          parallel_upsert(updates)
          creates.each { |item| serial_upsert(item) }

          processed += prepared_items.size
          report_progress(processed, base_offset, total, start_time)

          save_checkpoint("api_sync", "api_offset", base_offset + processed)
          persist_stats

          GC.start if batch_group_idx % GC_EVERY_N_GROUPS == 0
        end

        if prefetch_thread
          prefetch_thread.join
          prefetch_thread = nil
        end
      ensure
        prefetch_thread&.join rescue nil
        connections.each do |conn|
          conn&.finish rescue nil
        end
      end

      publish_progress(
        100,
        "同步完成：#{@stats[:updated]} 更新, #{@stats[:created]} 新建, #{@stats[:deleted]} 删除, #{@stats[:errors]} 错误",
      )
    end

    def safe_fetch(connections, concurrent_batches)
      fetch_byids_concurrent(connections, concurrent_batches)
    rescue StandardError => e
      batch_ids = concurrent_batches.flatten
      Rails.logger.error(
        "[DiscourseJournals::MappingApplier] Batch fetch failed (#{batch_ids.size} ids), skipping: #{e.class}: #{e.message}",
      )
      increment_stat(:errors, batch_ids.size)
      connections.replace(reconnect_all!(connections))
      []
    end

    def parallel_transform(rows)
      return [] if rows.empty?

      queue = Queue.new
      rows.each { |r| queue << r }
      UPSERT_CONCURRENCY.times { queue << :done }

      result = []
      result_mutex = Mutex.new

      threads = UPSERT_CONCURRENCY.times.map do
        Thread.new do
          while (row = queue.pop) != :done
            api_id = row.dig("unified", "id")
            next unless api_id

            action, topic_id = lookup_action(api_id)
            next unless action

            begin
              journal_params = ApiDataTransformer.transform(row)
              prepared = JournalUpserter.new(
                system_user: @system_user,
                defer_images: true,
              ).normalize_and_render(journal_params)

              result_mutex.synchronize do
                result << { api_id: api_id, action: action, topic_id: topic_id, prepared: prepared }
              end
            rescue StandardError => e
              Rails.logger.error(
                "[DiscourseJournals::MappingApplier] Transform failed for api_id=#{api_id}: #{e.class}: #{e.message}",
              )
              increment_stat(:errors)
            end
          end
        end
      end

      threads.each(&:join)
      result
    end

    def parallel_upsert(items)
      return if items.empty?

      queue = Queue.new
      items.each { |item| queue << item }
      UPSERT_CONCURRENCY.times { queue << :done }

      threads = UPSERT_CONCURRENCY.times.map do
        Thread.new do
          while (item = queue.pop) != :done
            begin
              upserter = JournalUpserter.new(system_user: @system_user, defer_images: true)
              upserter.upsert_prepared!(item[:prepared], existing_topic_id: item[:topic_id])
              increment_stat(:updated)
              tid = upserter.last_topic_id
              @mutex.synchronize { @cover_topic_ids << tid } if tid
            rescue StandardError => e
              Rails.logger.error(
                "[DiscourseJournals::MappingApplier] Upsert failed for api_id=#{item[:api_id]}: #{e.class}: #{e.message}",
              )
              increment_stat(:errors)
            end
          end
        end
      end

      threads.each(&:join)
    end

    def serial_upsert(item)
      upserter = JournalUpserter.new(system_user: @system_user, defer_images: true)
      upserter.upsert_prepared!(item[:prepared])
      increment_stat(:created)
      tid = upserter.last_topic_id
      @mutex.synchronize { @cover_topic_ids << tid } if tid
    rescue StandardError => e
      Rails.logger.error(
        "[DiscourseJournals::MappingApplier] Create failed for api_id=#{item[:api_id]}: #{e.class}: #{e.message}",
      )
      increment_stat(:errors)
    end

    def report_progress(processed, base_offset, total, start_time)
      return if processed % 20 != 0

      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time
      speed = (processed.to_f / elapsed).round(0)
      remaining = total - (base_offset + processed)
      eta = speed > 0 ? (remaining.to_f / speed).round(0) : 0
      eta_str = format_eta(eta)

      pct = (5 + (base_offset + processed).to_f / total * 95).round(1)
      publish_progress(
        pct,
        "同步中... #{base_offset + processed}/#{total} (#{@stats[:updated]} 更新, #{@stats[:created]} 新建, #{speed} 条/秒#{eta_str})",
      )
    end

    def persist_stats
      @analysis.update_columns(apply_stats: @stats.transform_keys(&:to_s))
    end

    def create_persistent_connection
      uri = URI(API_BASE_URL)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = 30
      http.read_timeout = 120
      http.keep_alive_timeout = 120
      http.start
      http
    end

    def reconnect!(http)
      http.finish
    rescue StandardError
      nil
    ensure
      http.start
    end

    def reconnect_all!(connections)
      connections.map do |conn|
        conn&.finish rescue nil
        create_persistent_connection
      rescue StandardError => e
        Rails.logger.warn("[DiscourseJournals::MappingApplier] Reconnect failed: #{e.message}")
        nil
      end.compact
    end

    def fetch_byids_concurrent(connections, id_batches)
      threads = id_batches.each_with_index.map do |ids, idx|
        conn = connections[idx % connections.size]
        Thread.new { fetch_byids_persistent(conn, ids) }
      end

      threads.flat_map(&:value)
    end

    def fetch_byids_persistent(http, api_ids)
      ids_param = api_ids.join(",")
      path = "/api/open/journals/byIds?ids=#{ids_param}&full=1"
      retries = 0
      max_retries = 5

      begin
        @rate_limiter.throttle!
        request = Net::HTTP::Get.new(path)
        response = http.request(request)

        unless response.is_a?(Net::HTTPSuccess)
          raise "API byIds 请求失败: #{response.code} #{response.message}"
        end

        data = JSON.parse(response.body)
        unless data["success"]
          raise "API byIds 返回错误: #{data["error"] || "Unknown"}"
        end

        (data.dig("data", "rows") || [])
      rescue Net::OpenTimeout, Net::ReadTimeout, OpenSSL::SSL::SSLError, Errno::ECONNRESET, EOFError, IOError => e
        retries += 1
        if retries <= max_retries
          wait = retries * 3
          Rails.logger.warn(
            "[DiscourseJournals::MappingApplier] byIds retry #{retries}/#{max_retries}: #{e.class}: #{e.message}",
          )
          begin
            reconnect!(http)
          rescue StandardError => re
            Rails.logger.warn("[DiscourseJournals::MappingApplier] Reconnect failed: #{re.message}")
          end
          sleep wait
          retry
        end
        raise "API byIds 请求失败 (重试 #{max_retries} 次后): #{e.message}"
      end
    end

    def enqueue_cover_jobs
      return if @cover_topic_ids.empty?

      publish_progress(100, "正在排队封面图片处理任务 (#{@cover_topic_ids.size} 个话题)...")

      @cover_topic_ids.uniq.each_slice(COVER_JOB_BATCH_SIZE) do |batch|
        Jobs.enqueue(Jobs::DiscourseJournals::ProcessJournalCovers, topic_ids: batch)
      end

      Rails.logger.info(
        "[DiscourseJournals::MappingApplier] Enqueued cover processing for #{@cover_topic_ids.size} topics",
      )
    end

    def format_eta(seconds)
      return "" if seconds <= 0
      if seconds < 60
        ", 约 #{seconds}s"
      elsif seconds < 3600
        mins = seconds / 60
        secs = seconds % 60
        secs > 0 ? ", 约 #{mins}m#{secs}s" : ", 约 #{mins}m"
      else
        hours = seconds / 3600
        mins = (seconds % 3600) / 60
        mins > 0 ? ", 约 #{hours}h#{mins}m" : ", 约 #{hours}h"
      end
    end

  end
end
