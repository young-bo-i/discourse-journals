# frozen_string_literal: true

require "net/http"
require "json"

module DiscourseJournals
  class MappingApplier
    class PausedError < StandardError; end

    API_BASE_URL = "https://journal.scholay.com/api/open/journals"
    BYIDS_BATCH_SIZE = 50
    API_CONCURRENCY = 5
    DELETE_CONCURRENCY = 5
    UPSERT_CONCURRENCY = 3
    CHECKPOINT_INTERVAL = 50

    attr_reader :stats

    def initialize(analysis:, progress_callback: nil, cancel_check: nil, resume_checkpoint: nil, resume_stats: nil)
      @analysis = analysis
      @progress_callback = progress_callback
      @cancel_check = cancel_check
      @checkpoint = (resume_checkpoint || {}).transform_keys(&:to_s)
      @api_actions = {}
      @topics_to_delete = []
      @stats = (resume_stats || { deleted: 0, updated: 0, created: 0, skipped: 0, errors: 0 }).transform_keys(&:to_sym)
      @error_details = []
      @system_user = Discourse.system_user
      @stats_mutex = Mutex.new
    end

    def run!
      build_action_plan

      resume_phase = @checkpoint["phase"]

      if resume_phase == "api_sync"
        execute_api_sync(skip_offset: @checkpoint["api_offset"].to_i)
      else
        delete_offset = resume_phase == "deletes" ? @checkpoint["delete_offset"].to_i : 0
        execute_deletes(skip_offset: delete_offset)
        execute_api_sync(skip_offset: 0)
      end

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
      @stats_mutex.synchronize { @stats[key] += amount }
    end

    def build_action_plan
      publish_progress(0, "正在构建执行计划...")
      details = @analysis.details_data || {}

      process_exact_matches(details["exact_1to1"] || [])
      process_forum_1_to_api_n(details["forum_1_to_api_n"] || [])
      process_forum_n_to_api_1(details["forum_n_to_api_1"] || [])
      process_forum_n_to_api_m(details["forum_n_to_api_m"] || [])
      process_forum_only(details["forum_only"] || [])
      process_api_only(details["api_only"] || [])

      total_actions = @api_actions.size
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
        @api_actions[api["api_id"]] = { action: :update, topic_id: forum["topic_id"] }
      end
    end

    def process_forum_1_to_api_n(entries)
      entries.each do |entry|
        forum = entry["forum"]&.first
        apis = entry["api"] || []
        next unless forum && apis.any?

        apis.each_with_index do |api, idx|
          if idx == 0
            @api_actions[api["api_id"]] = { action: :update, topic_id: forum["topic_id"] }
          else
            @api_actions[api["api_id"]] = { action: :create }
          end
        end
      end
    end

    def process_forum_n_to_api_1(entries)
      entries.each do |entry|
        forums = entry["forum"] || []
        api = entry["api"]&.first
        next unless forums.any? && api

        @api_actions[api["api_id"]] = { action: :update, topic_id: forums.first["topic_id"] }
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
          @api_actions[apis[i]["api_id"]] = { action: :update, topic_id: forums[i]["topic_id"] }
        end

        if forums.size > pair_count
          forums[pair_count..].each { |f| @topics_to_delete << f["topic_id"] }
        end

        if apis.size > pair_count
          apis[pair_count..].each { |a| @api_actions[a["api_id"]] = { action: :create } }
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
        (entry["api"] || []).each { |a| @api_actions[a["api_id"]] = { action: :create } }
      end
    end

    # ──── Phase 1: Parallel delete of orphaned / excess topics ────
    def execute_deletes(skip_offset: 0)
      total = @topics_to_delete.size
      return if total.zero?

      remaining_ids = @topics_to_delete[skip_offset..] || []
      return if remaining_ids.empty?

      publish_progress(2, "开始删除多余话题 (共 #{total} 个，从 ##{skip_offset + 1} 继续)...")

      queue = Queue.new
      remaining_ids.each { |id| queue << id }

      processed_count = Concurrent::AtomicFixnum.new(0)
      base_offset = skip_offset

      threads = DELETE_CONCURRENCY.times.map do
        Thread.new do
          while (topic_id = queue.pop(true) rescue nil)
            check_cancelled!

            begin
              topic = Topic.find_by(id: topic_id)
              if topic&.first_post
                PostDestroyer.new(@system_user, topic.first_post, force_destroy: true).destroy
                increment_stat(:deleted)
              else
                increment_stat(:skipped)
              end
            rescue PausedError
              raise
            rescue StandardError => e
              increment_stat(:errors)
              log_error("delete", topic_id, e)
            end

            current = processed_count.increment
            if current % CHECKPOINT_INTERVAL == 0
              save_checkpoint("deletes", "delete_offset", base_offset + current)
              persist_stats
            end

            if current % 10 == 0 || current == remaining_ids.size
              pct = (2 + (base_offset + current).to_f / total * 3).round(1)
              publish_progress(pct, "删除中... #{base_offset + current}/#{total} (已删除 #{@stats[:deleted]})")
            end
          end
        rescue PausedError
          nil
        end
      end

      threads.each(&:join)
      check_cancelled!

      save_checkpoint("deletes", "delete_offset", total)
      persist_stats
      publish_progress(5, "删除完成：#{@stats[:deleted]} 个话题已永久删除")
    end

    # ──── Phase 2: Concurrent fetch + parallel upsert ────
    def execute_api_sync(skip_offset: 0)
      all_api_ids = @api_actions.keys
      total = all_api_ids.size
      return if total.zero?

      remaining_ids = all_api_ids[skip_offset..] || []
      return if remaining_ids.empty?

      publish_progress(5, "开始同步 API 数据 (共 #{total} 条，从 ##{skip_offset + 1} 继续)...")

      batches = remaining_ids.each_slice(BYIDS_BATCH_SIZE).to_a
      processed = Concurrent::AtomicFixnum.new(0)
      base_offset = skip_offset
      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      connections = API_CONCURRENCY.times.map { create_persistent_connection }

      begin
        batches.each_slice(API_CONCURRENCY).with_index do |concurrent_batches, batch_group_idx|
          check_cancelled!

          rows = fetch_byids_concurrent(connections, concurrent_batches)
          process_rows_parallel(rows, processed, base_offset, total, start_time)

          current = processed.value
          save_checkpoint("api_sync", "api_offset", base_offset + current)
          persist_stats
        end
      ensure
        connections.each do |conn|
          conn.finish
        rescue StandardError
          nil
        end
      end

      publish_progress(
        100,
        "同步完成：#{@stats[:updated]} 更新, #{@stats[:created]} 新建, #{@stats[:deleted]} 删除, #{@stats[:errors]} 错误",
      )
    end

    def process_rows_parallel(rows, processed_counter, base_offset, total, start_time)
      queue = Queue.new
      rows.each { |row| queue << row }

      threads = [UPSERT_CONCURRENCY, rows.size].min.times.map do
        Thread.new do
          while (row = queue.pop(true) rescue nil)
            unified = row["unified"] || {}
            api_id = unified["id"]
            next unless api_id

            action_info = @api_actions[api_id]
            next unless action_info

            begin
              journal_params = ApiDataTransformer.transform(row)
              upserter = JournalUpserter.new(system_user: @system_user)

              case action_info[:action]
              when :update
                upserter.upsert!(journal_params, existing_topic_id: action_info[:topic_id])
                increment_stat(:updated)
              when :create
                upserter.upsert!(journal_params)
                increment_stat(:created)
              end
            rescue StandardError => e
              increment_stat(:errors)
              log_error(action_info[:action].to_s, api_id, e)
            end

            current = processed_counter.increment
            if current % 20 == 0
              elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time
              speed = current > 0 ? (current.to_f / elapsed).round(0) : 0
              remaining = total - (base_offset + current)
              eta = speed > 0 ? (remaining.to_f / speed).round(0) : 0
              eta_str = format_eta(eta)

              pct = (5 + (base_offset + current).to_f / total * 95).round(1)
              publish_progress(
                pct,
                "同步中... #{base_offset + current}/#{total} (#{@stats[:updated]} 更新, #{@stats[:created]} 新建, #{speed} 条/秒#{eta_str})",
              )
            end
          end
        end
      end

      threads.each(&:join)
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
      max_retries = 3

      begin
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

    def log_error(action, id, error)
      Rails.logger.error(
        "[DiscourseJournals::MappingApplier] #{action} failed for #{id}: #{error.class} - #{error.message}",
      )
      @error_details << { action: action, id: id, error: error.message }
    end
  end
end
