# frozen_string_literal: true

module DiscourseJournals
  class MappingApplier
    class PausedError < StandardError; end

    # Detail fetches go through `GET /journals?ids=…&full=1` — /journals/byIds
    # was retired (410 endpoint_gone) in upstream contract v4.
    DETAIL_BATCH_SIZE = ApiClient::IDS_BATCH_SIZE
    API_CONCURRENCY = 4
    UPSERT_CONCURRENCY = 4
    DELETE_BATCH_SIZE = BulkTopicDeleter::BATCH_SIZE

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
      # Always start from a full set of counters and layer any resumed stats on
      # top. A resumed hash may be empty (paused before the first checkpoint) or
      # missing keys, so a bare `resume_stats ||` default would leave nil counters
      # that blow up on the first `increment_stat` (nil + 1).
      @stats = { deleted: 0, updated: 0, created: 0, skipped: 0, errors: 0 }
        .merge((resume_stats || {}).transform_keys(&:to_sym))
      @system_user = Discourse.system_user
      @mutex = Mutex.new
      @last_cancel_check_at = 0.0
      # api_id -> topic_id aliases learned from the upstream `redirects` map when
      # a journal we track was merged into another id, plus the topics whose
      # journal upstream deleted outright.
      @redirect_aliases = {}
      @gone_topic_ids = []
    end

    def run!
      ApiClient.ensure_configured!
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

      mark_upstream_deleted!

      # Recompute tag/category-tag counts once, since apply_tag_delta! and
      # BulkTopicDeleter both skip TopicTag's per-row counter callbacks.
      JournalTagManager.reconcile_counts!
      JournalTagManager.reset_cache!

      @stats
    end

    private

    def check_cancelled!
      return unless @cancel_check
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      return if (now - @last_cancel_check_at) < 5.0
      @last_cancel_check_at = now
      raise PausedError, "应用已被用户暂停" if @cancel_check.call
    end

    def publish_progress(percent, message)
      @progress_callback&.call(percent, message, @stats)
    end

    def save_checkpoint(phase, offset_key, offset_value)
      # "heartbeat" lets MappingAnalysis#stale_sync_processing? tell a live apply
      # from a crashed one, so resuming a healthy job never spawns a duplicate.
      cp = (@analysis.apply_checkpoint || {})
        .merge("phase" => phase, offset_key => offset_value, "heartbeat" => Time.current.to_i)
      @analysis.update_columns(apply_checkpoint: cp, apply_stats: @stats.transform_keys(&:to_s))
    end

    def increment_stat(key, amount = 1)
      @mutex.synchronize { @stats[key] += amount }
    end

    def build_action_plan
      PerformanceLogger.measure("sync.build_action_plan", source_type: "mapping_applier") do
        publish_progress(0, "正在构建执行计划...")

        details = MappingAnalysis
          .where(id: @analysis.id)
          .pick(:details_data) || {}

        plan = details["_action_plan"]

        if plan
          # transform_keys.transform_values held THREE 301,835-entry hashes at
          # once alongside the still-live parse tree. Build once, then drop
          # `plan` so the `details = nil` below can actually collect.
          @update_map = {}
          (plan["updates"] || {}).each { |k, v| @update_map[k.to_i] = v.to_i }
          @create_ids = (plan["creates"] || []).map(&:to_i)
          @topics_to_delete = (plan["deletes"] || []).map(&:to_i)
          plan = nil
        else
          process_exact_matches(details["exact_1to1"] || [])
          process_forum_1_to_api_n(details["forum_1_to_api_n"] || [])
          process_forum_n_to_api_1(details["forum_n_to_api_1"] || [])
          process_forum_n_to_api_m(details["forum_n_to_api_m"] || [])
          process_forum_only(details["forum_only"] || [])
          process_api_only(details["api_only"] || [])
        end

        details = nil

        total_actions = @update_map.size + @create_ids.size
        total_deletes = @topics_to_delete.size
        publish_progress(
          1,
          "执行计划已构建：#{total_actions} 个 API 操作（更新+新建），#{total_deletes} 个话题待删除",
        )
      end
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
        apis.each { |api| @create_ids << api["api_id"] }
      end
    end

    def all_api_ids
      @update_map.keys + @create_ids
    end

    def lookup_action(api_id)
      topic_id = @update_map[api_id] || @redirect_aliases[api_id]
      if topic_id
        [:update, topic_id]
      else
        [:create, nil]
      end
    end

    # `resolveIds=follow` folds a merged id into its new target row, so the row we
    # get back is keyed by the NEW api_id while our plan is keyed by the old one.
    # The response's `redirects` map ({old_id => new_id | nil}) closes that gap:
    # a merge becomes an alias onto the same topic (so it is updated, not
    # duplicated), and a deletion queues the topic for the outdated banner.
    def absorb_redirects!(redirects)
      return if redirects.blank?

      redirects.each do |old_id, new_id|
        topic_id = @update_map[old_id.to_i]
        next unless topic_id

        if new_id.nil?
          @mutex.synchronize { @gone_topic_ids << topic_id }
        else
          @mutex.synchronize { @redirect_aliases[new_id.to_i] = topic_id }
        end
      end
    end

    # Journals upstream removed while we were mid-sync. Soft-delete them the same
    # way execute_deletes does, so the URL keeps resolving instead of 404ing.
    def mark_upstream_deleted!
      ids = @gone_topic_ids.uniq
      return if ids.empty?

      Rails.logger.info(
        "[DiscourseJournals::MappingApplier] #{ids.size} tracked journals were deleted upstream, marking outdated",
      )

      ids.each_slice(DELETE_BATCH_SIZE) do |batch_ids|
        increment_stat(:deleted, OutdatedMarker.mark_batch(batch_ids))
      end
    end

    # ──── Phase 1: Bulk SQL delete of orphaned / excess topics ────
    def execute_deletes(skip_offset: 0)
      total = @topics_to_delete.size
      return if total.zero?

      remaining_ids = @topics_to_delete[skip_offset..] || []
      return if remaining_ids.empty?

      publish_progress(2, "开始标记过时话题 (共 #{total} 个，从 ##{skip_offset + 1} 继续)...")

      base_offset = skip_offset

      remaining_ids.each_slice(DELETE_BATCH_SIZE).with_index do |batch_ids, batch_idx|
        check_cancelled!

        # Soft-delete: forum-only journals are marked outdated (banner + closed),
        # NOT hard-deleted, to preserve their SEO. Already-outdated topics are
        # skipped (idempotent).
        marked_count = OutdatedMarker.mark_batch(batch_ids)
        increment_stat(:deleted, marked_count)
        skipped = batch_ids.size - marked_count
        increment_stat(:skipped, skipped) if skipped > 0

        processed = base_offset + [((batch_idx + 1) * DELETE_BATCH_SIZE), remaining_ids.size].min
        processed = [processed, total].min

        save_checkpoint("deletes", "delete_offset", processed)

        pct = (2 + processed.to_f / total * 3).round(1)
        publish_progress(pct, "标记过时中... #{processed}/#{total} (已标记 #{@stats[:deleted]})")
      end

      save_checkpoint("deletes", "delete_offset", total)
      publish_progress(5, "过时标记完成：#{@stats[:deleted]} 个话题已标记为过时")
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

      cid = SiteSetting.discourse_journals_category_id.to_i
      @journal_category = Category.find_by(id: cid) if cid > 0

      processed = 0
      base_offset = skip_offset
      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      clients = API_CONCURRENCY.times.map { new_client }
      prefetch_clients = API_CONCURRENCY.times.map { new_client }

      begin
        batch_groups = remaining_ids.each_slice(DETAIL_BATCH_SIZE).each_slice(API_CONCURRENCY).to_a
        prefetch_rows = nil
        prefetch_thread = nil

        batch_groups.each_with_index do |concurrent_batches, batch_group_idx|
          check_cancelled!

          # #tap hands the array over without binding it to a block-local. The
          # old `r = prefetch_rows` was never cleared, so the `rows = nil` below
          # freed nothing from the second group onward and all 200 raw rows
          # (~35 MiB parsed) stayed pinned through the whole upsert phase.
          row_batches =
            if prefetch_thread
              prefetch_thread.join
              prefetch_thread = nil
              prefetch_rows.tap { prefetch_rows = nil }
            else
              safe_fetch(clients, concurrent_batches)
            end

          next_group = batch_groups[batch_group_idx + 1]
          if next_group
            prefetch_thread = Thread.new do
              prefetch_rows = safe_fetch(prefetch_clients, next_group)
            end
          end

          # Transform + upsert one DETAIL_BATCH_SIZE batch at a time instead of
          # the whole API_CONCURRENCY-wide group. Fetch stays 4-wide and the
          # prefetch is unchanged, but raw rows and prepared items are released
          # 4x sooner — and the checkpoint advances 4x more often, so a resume
          # redoes at most one batch instead of one group.
          row_batches.each_index do |i|
            batch_rows = row_batches[i]
            row_batches[i] = nil

            prepared_items = parallel_transform(batch_rows)
            batch_rows = nil

            updates, creates = prepared_items.partition { |item| item[:action] == :update }
            prepared_items = nil

            parallel_upsert(updates)
            serial_upsert(creates.shift) until creates.empty?

            # Advance by ids REQUESTED, not rows returned: upstream drops ids it
            # has deleted, so counting rows would leave the checkpoint
            # permanently behind the real position and re-fetch finished ids on
            # every resume.
            processed += concurrent_batches[i].size
            report_progress(processed, base_offset, total, start_time)

            save_checkpoint("api_sync", "api_offset", base_offset + processed)
          end
        end

        if prefetch_thread
          prefetch_thread.join
          prefetch_thread = nil
        end
      ensure
        prefetch_thread&.join rescue nil
        (clients + prefetch_clients).each { |client| client&.finish! }
      end

      publish_progress(
        100,
        "同步完成：#{@stats[:updated]} 更新, #{@stats[:created]} 新建, #{@stats[:deleted]} 删除, #{@stats[:errors]} 错误",
      )
    end

    def safe_fetch(clients, concurrent_batches)
      fetch_details_concurrent(clients, concurrent_batches)
    rescue StandardError => e
      batch_ids = concurrent_batches.flatten
      Rails.logger.error(
        "[DiscourseJournals::MappingApplier] Batch fetch failed (#{batch_ids.size} ids), aborting current sync pass: #{e.class}: #{e.message}",
      )
      clients.each { |client| client&.reconnect! rescue nil }
      raise
    end

    def parallel_transform(rows)
      return [] if rows.empty?

      PerformanceLogger.measure("sync.parallel_transform", source_type: "mapping_applier", batch_size: rows.size) do
        queue = Queue.new
        # Drain rather than copy: each row becomes collectable the moment its
        # worker is done with it, instead of being pinned by the caller's array
        # for the whole phase.
        queue << rows.shift until rows.empty?
        UPSERT_CONCURRENCY.times { queue << :done }

        result = []
        result_mutex = Mutex.new

        threads = UPSERT_CONCURRENCY.times.map do
          Thread.new do
            upserter =
              JournalUpserter.new(
                system_user: @system_user,
                category: @journal_category,
              )

            while (row = queue.pop) != :done
              api_id = row.dig("unified", "id")
              next unless api_id

              action, topic_id = lookup_action(api_id)
              next unless action

              begin
                journal_params = ApiDataTransformer.transform(row)
                prepared = upserter.normalize_and_render(journal_params)

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
    end

    def parallel_upsert(items)
      return if items.empty?

      PerformanceLogger.measure("sync.parallel_upsert", source_type: "mapping_applier", batch_size: items.size) do
        queue = Queue.new
        queue << items.shift until items.empty?
        UPSERT_CONCURRENCY.times { queue << :done }

        threads = UPSERT_CONCURRENCY.times.map do
          Thread.new do
            # Check the pooled connection back in as soon as this thread's DB work
            # finishes, instead of leaving it pinned to the (dead) thread until the
            # reaper runs — otherwise the upsert threads starve the other Sidekiq
            # workers sharing the pool. (parallel_transform is pure CPU and never
            # checks out a connection, so it is intentionally left unwrapped.)
            ActiveRecord::Base.connection_pool.with_connection do
              upserter =
                JournalUpserter.new(
                  system_user: @system_user,
                  category: @journal_category,
                )

              while (item = queue.pop) != :done
                begin
                  # These are planned updates, but the target topic may have been
                  # deleted since analysis, in which case upsert_prepared! creates
                  # instead — count what actually happened.
                  result = upserter.upsert_prepared!(item[:prepared], existing_topic_id: item[:topic_id])
                  increment_stat(result == :created ? :created : :updated)
                rescue StandardError => e
                  Rails.logger.error(
                    "[DiscourseJournals::MappingApplier] Upsert failed for api_id=#{item[:api_id]}: #{e.class}: #{e.message}",
                  )
                  increment_stat(:errors)
                end
              end
            end
          end
        end

        threads.each(&:join)
      end
    end

    def serial_upsert(item)
      upserter =
        JournalUpserter.new(
          system_user: @system_user,
          category: @journal_category,
        )
      # Planned as a create, but upsert_prepared! still de-dupes via
      # find_existing_topic (ISSN-L / title), so it may resolve to an update —
      # count what actually happened, consistent with parallel_upsert.
      result = upserter.upsert_prepared!(item[:prepared])
      increment_stat(result == :created ? :created : :updated)
    rescue StandardError => e
      Rails.logger.error(
        "[DiscourseJournals::MappingApplier] Create failed for api_id=#{item[:api_id]}: #{e.class}: #{e.message}",
      )
      increment_stat(:errors)
    end

    def report_progress(processed, base_offset, total, start_time)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time
      speed = elapsed > 0 ? (processed.to_f / elapsed).round(0) : 0
      remaining = total - (base_offset + processed)
      eta = speed > 0 ? (remaining.to_f / speed).round(0) : 0
      eta_str = format_eta(eta)

      pct = (5 + (base_offset + processed).to_f / total * 95).round(1)
      publish_progress(
        pct,
        "同步中... #{base_offset + processed}/#{total} (#{@stats[:updated]} 更新, #{@stats[:created]} 新建, #{speed} 条/秒#{eta_str})",
      )
    end

    def new_client
      # A detail page is ~3.5 MB for a 50-id batch, so it needs a longer read
      # timeout than the slim analysis pages.
      ApiClient.new(rate_limiter: @rate_limiter, read_timeout: 120).start!
    end

    def fetch_details_concurrent(clients, id_batches)
      threads = id_batches.each_with_index.map do |ids, idx|
        client = clients[idx % clients.size]
        Thread.new { client.fetch_journals_by_ids(ids) }
      end

      # Wait for every thread before surfacing a failure: an abandoned thread keeps
      # its connection and its parsed multi-MB payload alive for the rest of the
      # job. #value then re-raises the first failure.
      threads.each { |thread| thread.join rescue nil }
      results = threads.map(&:value)

      results.each { |result| absorb_redirects!(result[:redirects]) }
      # One array per requested batch (not flattened): execute_api_sync releases
      # each batch's rows as soon as that batch has been upserted.
      results.map { |result| result[:rows] }
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
