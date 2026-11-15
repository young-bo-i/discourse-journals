# frozen_string_literal: true

module Jobs
  module DiscourseJournals
    class SyncComments < ::Jobs::Base
      sidekiq_options retry: 0, queue: "low"

      LOCK_KEY = "discourse_journals:comment_sync:lock"
      LOCK_TTL = 10.minutes
      CHANNEL = "/journals/comment-sync"
      STATS = %i[created updated deleted unchanged skipped held].freeze

      def execute(args)
        state = ::DiscourseJournals::CommentSyncState.current
        return if state.nil? || state["id"] != args[:run_id] || state["status"] != "pending"

        @run_id = args[:run_id]
        @user_id = state["user_id"]
        return if !Discourse.redis.set(LOCK_KEY, @run_id, nx: true, ex: LOCK_TTL.to_i)

        begin
          run(state)
        ensure
          Discourse.redis.del(LOCK_KEY) if Discourse.redis.get(LOCK_KEY) == @run_id
        end
      end

      private

      def run(state)
        topic_ids = target_topic_ids(state)
        stats = STATS.index_with(0).merge(journals: 0, errors: 0)
        ::DiscourseJournals::CommentSyncState.update(
          status: "processing",
          total: topic_ids.size,
          heartbeat_at: Time.current.to_i,
        )
        publish("processing", total: topic_ids.size, processed: 0, stats: stats)

        bot = ::DiscourseJournals::CommentBot.user
        client = ::DiscourseJournals::ApiClient.new.start!

        topic_ids.each_with_index do |topic_id, index|
          if apply_running?
            raise ::DiscourseJournals::ApiClient::Error,
                  I18n.t("discourse_journals.comment_sync.errors.apply_running")
          end

          sync_topic(topic_id, client: client, bot: bot, stats: stats)
          Discourse.redis.expire(LOCK_KEY, LOCK_TTL.to_i)
          ::DiscourseJournals::CommentSyncState.update(
            processed: index + 1,
            stats: stats,
            heartbeat_at: Time.current.to_i,
          )
          publish("processing", total: topic_ids.size, processed: index + 1, stats: stats)
        end

        ::DiscourseJournals::CommentSyncState.update(
          status: "completed",
          stats: stats,
          completed_at: Time.current.iso8601,
        )
        publish("completed", stats: stats)
      rescue StandardError => e
        Rails.logger.error(
          "[DiscourseJournals::SyncComments] Failed: #{e.class}: #{e.message}\n" \
            "#{e.backtrace&.first(10)&.join("\n")}",
        )
        ::DiscourseJournals::CommentSyncState.update(
          status: "failed",
          error_message: e.message,
          completed_at: Time.current.iso8601,
        )
        publish("failed")
      ensure
        client&.finish!
      end

      # One journal failing (bad data, a 5xx) is counted and skipped; the
      # credentials failing would fail every journal, so it stops the run.
      def sync_topic(topic_id, client:, bot:, stats:)
        topic = Topic.find_by(id: topic_id)
        return if topic.nil?

        result = ::DiscourseJournals::CommentSyncer.new(topic, client: client, bot: bot).sync!
        stats[:journals] += 1 if result.status == :ok
        STATS.each { |key| stats[key] += result[key] }
      rescue ::DiscourseJournals::ApiClient::AuthError
        raise
      rescue StandardError => e
        stats[:errors] += 1
        Rails.logger.warn(
          "[DiscourseJournals::SyncComments] topic #{topic_id}: #{e.class}: #{e.message}",
        )
      end

      def target_topic_ids(state)
        category_id = SiteSetting.discourse_journals_category_id.to_i
        definition_topic_id = Category.where(id: category_id).pick(:topic_id)
        scope = Topic.where(category_id: category_id, deleted_at: nil)
        scope = scope.where.not(id: definition_topic_id) if definition_topic_id

        topic_ids = Array(state["topic_ids"]).map(&:to_i)
        return scope.where(id: topic_ids).order(:id).pluck(:id) if topic_ids.any?

        # Journals upstream says have comments, not yet synced, lowest id first.
        scope
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
          .limit(state["limit"].to_i.clamp(1, ::DiscourseJournals::CommentSyncState::MAX_JOURNALS))
          .pluck(:id)
      end

      def apply_running?
        analysis = ::DiscourseJournals::MappingAnalysis.current_light
        analysis.present? && analysis.sync_processing? && !analysis.stale_sync_processing?
      end

      def publish(status, payload = {})
        MessageBus.publish(
          CHANNEL,
          payload.merge(status: status, run_id: @run_id),
          user_ids: [@user_id].compact,
        )
      end
    end
  end
end
