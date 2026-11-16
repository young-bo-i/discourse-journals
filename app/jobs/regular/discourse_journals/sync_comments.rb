# frozen_string_literal: true

module Jobs
  module DiscourseJournals
    # Runs one comment sync (see CommentSyncState for the modes). Journals go in
    # topic id order and the checkpoint is the last one finished, so a paused,
    # failed or restarted run picks up where it stopped.
    class SyncComments < ::Jobs::Base
      sidekiq_options retry: 0, queue: "low"

      LOCK_KEY = "discourse_journals:comment_sync:lock"
      LOCK_TTL = 10.minutes
      CHANNEL = "/journals/comment-sync"
      STATS = %i[journals created updated deleted unchanged skipped held errors].freeze
      RESULT_STATS = %i[created updated deleted unchanged skipped held].freeze
      BATCH_SIZE = 40
      # About one journal in 25 has comments, so a scan of this many topics
      # usually fills a batch.
      SCAN_SIZE = 2_000
      PROGRESS_INTERVAL = 2

      WITH_COMMENTS_SQL = <<~SQL
        SELECT DISTINCT ON (data.topic_id) data.topic_id, api.value AS api_id
        FROM topic_custom_fields data
        LEFT JOIN topic_custom_fields api
          ON api.topic_id = data.topic_id AND api.name = 'discourse_journals_api_id'
        WHERE data.topic_id IN (:topic_ids)
          AND data.name = 'discourse_journals_data'
          AND data.value LIKE '%"reviews":{%'
          AND COALESCE((data.value::jsonb #>> '{reviews,count}')::int, 0) > 0
        ORDER BY data.topic_id
      SQL

      COUNT_SQL = <<~SQL
        SELECT COUNT(DISTINCT topics.id)
        FROM topics
        JOIN topic_custom_fields data
          ON data.topic_id = topics.id AND data.name = 'discourse_journals_data'
        WHERE topics.category_id = :category_id
          AND topics.deleted_at IS NULL
          AND topics.id IS DISTINCT FROM :definition_topic_id
          AND data.value LIKE '%"reviews":{%'
          AND COALESCE((data.value::jsonb #>> '{reviews,count}')::int, 0) > 0
      SQL

      def execute(args)
        state = ::DiscourseJournals::CommentSyncState.current
        return if state.nil? || state["id"] != args[:run_id]
        # "processing" here means Sidekiq put the job back in the queue when it
        # restarted: the run carries on from its checkpoint.
        return if ::DiscourseJournals::CommentSyncState::ACTIVE.exclude?(state["status"])

        @run_id = state["id"]
        @user_id = state["user_id"]

        if !Discourse.redis.set(LOCK_KEY, @run_id, nx: true, ex: LOCK_TTL.to_i)
          # A resumed run whose previous process died holding the lock waits
          # for the lock to expire.
          Jobs.enqueue_in(1.minute, self.class, run_id: @run_id) if state["status"] == "pending"
          return
        end

        begin
          run(state)
        ensure
          Discourse.redis.del(LOCK_KEY) if Discourse.redis.get(LOCK_KEY) == @run_id
        end
      end

      private

      def run(state)
        load_progress(state)
        update(
          status: "processing",
          total: @total,
          topic_ids: @topic_ids || [],
          heartbeat_at: Time.current.to_i,
        )
        publish("processing", force: true)

        return if !sync_journals

        update(status: "completed", stats: @stats, completed_at: Time.current.iso8601)
        publish("completed", force: true)
      rescue StandardError => e
        Rails.logger.error(
          "[DiscourseJournals::SyncComments] Failed: #{e.class}: #{e.message}\n" \
            "#{e.backtrace&.first(10)&.join("\n")}",
        )
        update(status: "failed", error_message: e.message, completed_at: Time.current.iso8601)
        publish("failed", force: true)
      end

      def load_progress(state)
        @mode = state["mode"]
        saved = (state["stats"] || {}).to_h { |key, value| [key.to_sym, value.to_i] }
        @stats = STATS.index_with(0).merge(saved.slice(*STATS))
        @processed = state["processed"].to_i
        @checkpoint = state["checkpoint"].to_i
        @topic_ids = test_topic_ids(state) if @mode != "full"
        @total = state["total"].to_i.positive? ? state["total"].to_i : count_journals
        @session_started = clock
        @session_processed = @processed
        @published_at = 0
      end

      # Fetches the next batch while the current one is written, so the
      # upstream round trips overlap the database work. False when stopped.
      def sync_journals
        bot = ::DiscourseJournals::CommentBot.user
        fetcher = ::DiscourseJournals::CommentFetcher.new
        prefetch = nil

        batch = next_batch(@checkpoint)
        while batch.any?
          fetched = prefetch ? prefetch.value : fetcher.fetch(batch)
          following = next_batch(batch.last.first)
          prefetch = following.any? ? Thread.new { fetcher.fetch(following) } : nil

          batch.each do |topic_id, _api_id|
            return false if stop_requested?

            sync_topic(topic_id, fetched.delete(topic_id), bot)
            @checkpoint = topic_id
            @processed += 1
            save_progress
          end
          batch = following
        end
        true
      ensure
        begin
          prefetch&.join
        rescue StandardError
          nil
        end
        fetcher&.finish!
      end

      # One journal failing (bad data, a 5xx) is counted and skipped; the
      # credentials failing would fail every journal, so it stops the run.
      def sync_topic(topic_id, fetched, bot)
        raise fetched if fetched.is_a?(::DiscourseJournals::ApiClient::AuthError)
        return count_error(topic_id, fetched) if fetched.is_a?(Exception)

        topic = Topic.find_by(id: topic_id)
        return if topic.nil?

        result = ::DiscourseJournals::CommentSyncer.new(topic, bot: bot).sync!(fetched)
        @stats[:journals] += 1 if result.status == :ok
        RESULT_STATS.each { |key| @stats[key] += result[key] }
      rescue ::DiscourseJournals::ApiClient::AuthError
        raise
      rescue StandardError => e
        count_error(topic_id, e)
      end

      def count_error(topic_id, error)
        @stats[:errors] += 1
        Rails.logger.warn(
          "[DiscourseJournals::SyncComments] topic #{topic_id}: #{error.class}: #{error.message}",
        )
      end

      def stop_requested?
        state = ::DiscourseJournals::CommentSyncState.current
        return true if state.nil? || state["id"] != @run_id

        if state["status"] == "paused"
          publish("paused", force: true)
          return true
        end

        if apply_running?
          update(
            status: "paused",
            error_message: I18n.t("discourse_journals.comment_sync.errors.paused_for_apply"),
          )
          publish("paused", force: true)
          return true
        end

        false
      end

      def save_progress
        Discourse.redis.expire(LOCK_KEY, LOCK_TTL.to_i)
        update(
          processed: @processed,
          checkpoint: @checkpoint,
          stats: @stats,
          heartbeat_at: Time.current.to_i,
        )
        publish("processing")
      end

      def next_batch(after)
        return journals_with_comments(after) if @mode == "full"

        topic_ids = @topic_ids.select { |topic_id| topic_id > after }.first(BATCH_SIZE)
        api_ids =
          TopicCustomField
            .where(topic_id: topic_ids, name: "discourse_journals_api_id")
            .pluck(:topic_id, :value)
            .to_h
        topic_ids.map { |topic_id| [topic_id, api_ids[topic_id]] }
      end

      # Scans topic ids in order so each lookup reads a few thousand journal
      # rows through the (topic_id, name) index, never the whole table.
      def journals_with_comments(after)
        found = []
        cursor = after

        while found.size < BATCH_SIZE
          topic_ids =
            journal_scope.where("topics.id > ?", cursor).order(:id).limit(SCAN_SIZE).pluck(:id)
          break if topic_ids.empty?

          cursor = topic_ids.last
          found.concat(
            DB
              .query(WITH_COMMENTS_SQL, topic_ids: topic_ids)
              .map { |row| [row.topic_id, row.api_id] },
          )
        end

        found.first(BATCH_SIZE)
      end

      def count_journals
        return @topic_ids.size if @mode != "full"

        DB
          .query_single(
            COUNT_SQL,
            category_id: SiteSetting.discourse_journals_category_id.to_i,
            definition_topic_id: definition_topic_id,
          )
          .first
          .to_i
      end

      # A test run keeps its journal list in the state, so a resumed one syncs
      # the same journals.
      def test_topic_ids(state)
        listed = Array(state["topic_ids"]).map(&:to_i)
        topic_ids =
          if listed.any?
            journal_scope.where(id: listed).pluck(:id)
          else
            unsynced_journals_with_comments(state["limit"].to_i)
          end
        topic_ids.sort
      end

      def unsynced_journals_with_comments(limit)
        journal_scope
          .joins(
            "JOIN topic_custom_fields dj_data ON dj_data.topic_id = topics.id " \
              "AND dj_data.name = 'discourse_journals_data'",
          )
          .where("dj_data.value LIKE '%\"reviews\":{%'")
          .where("COALESCE((dj_data.value::jsonb #>> '{reviews,count}')::int, 0) > 0")
          .where(
            "NOT EXISTS (SELECT 1 FROM discourse_journals_comment_posts cp WHERE cp.topic_id = topics.id)",
          )
          .order(:id)
          .limit(limit.clamp(1, ::DiscourseJournals::CommentSyncState::MAX_JOURNALS))
          .pluck(:id)
      end

      def journal_scope
        scope =
          Topic.where(category_id: SiteSetting.discourse_journals_category_id.to_i, deleted_at: nil)
        definition_topic_id ? scope.where.not(id: definition_topic_id) : scope
      end

      def definition_topic_id
        return @definition_topic_id if defined?(@definition_topic_id)

        @definition_topic_id =
          Category.where(id: SiteSetting.discourse_journals_category_id.to_i).pick(:topic_id)
      end

      def apply_running?
        analysis = ::DiscourseJournals::MappingAnalysis.current_light
        analysis.present? && analysis.sync_processing? && !analysis.stale_sync_processing?
      end

      def update(**changes)
        ::DiscourseJournals::CommentSyncState.update_run(@run_id, **changes)
      end

      def publish(status, force: false)
        now = clock
        return if !force && now - @published_at < PROGRESS_INTERVAL

        @published_at = now
        MessageBus.publish(
          CHANNEL,
          {
            run_id: @run_id,
            status: status,
            mode: @mode,
            total: @total,
            processed: @processed,
            stats: @stats,
          }.merge(speed),
          user_ids: [@user_id].compact,
        )
      end

      def speed
        elapsed = clock - @session_started
        done = @processed - @session_processed
        return {} if elapsed < 1 || done <= 0

        per_minute = done * 60.0 / elapsed
        remaining = [@total - @processed, 0].max
        { speed: per_minute.round(1), eta_seconds: (remaining * 60 / per_minute).round }
      end

      def clock
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
