# frozen_string_literal: true

module Jobs
  module DiscourseJournals
    class SyncCovers < ::Jobs::Base
      sidekiq_options retry: 0, queue: "low"

      def execute(args)
        cover_sync_id = args[:cover_sync_id]
        now = Time.current

        # Claim the row atomically so a duplicate enqueue cannot start a second
        # syncer on the same run. The fresh heartbeat keeps it from looking stale.
        claimed =
          ::DiscourseJournals::CoverSync.where(id: cover_sync_id, status: :pending).update_all(
            [
              "status = :processing, started_at = COALESCE(started_at, :now), completed_at = NULL, " \
                "error_message = NULL, updated_at = :now, " \
                "checkpoint = checkpoint || jsonb_build_object('heartbeat', :heartbeat)",
              {
                processing: ::DiscourseJournals::CoverSync.statuses[:processing],
                now: now,
                heartbeat: now.to_i,
              },
            ],
          )
        return if claimed.zero?

        @cover_sync = ::DiscourseJournals::CoverSync.find(cover_sync_id)

        if apply_running?
          fail!(I18n.t("discourse_journals.cover_sync.errors.apply_running"))
          return
        end

        @cover_sync.update_columns(total: journal_topic_count) if @cover_sync.total.zero?
        publish("processing")

        syncer =
          ::DiscourseJournals::CoverSyncer.new(
            cover_sync: @cover_sync,
            progress_callback: ->(progress) { publish("processing", progress) },
            cancel_check: -> do
              !::DiscourseJournals::CoverSync.where(id: cover_sync_id, status: :processing).exists?
            end,
          )
        stats = syncer.run!

        @cover_sync.update!(status: :completed, completed_at: Time.current, stats: stats)
        publish("completed")
      rescue ::DiscourseJournals::CoverSyncer::PausedError
        publish("paused")
      rescue StandardError => e
        Rails.logger.error(
          "[DiscourseJournals::SyncCovers] Failed: #{e.class}: #{e.message}\n" \
            "#{e.backtrace&.first(10)&.join("\n")}",
        )
        fail!(e.message) if @cover_sync
      end

      private

      def apply_running?
        analysis = ::DiscourseJournals::MappingAnalysis.current_light
        analysis.present? && analysis.sync_processing? && !analysis.stale_sync_processing?
      end

      def journal_topic_count
        category = Category.find_by(id: SiteSetting.discourse_journals_category_id.to_i)
        return 0 if category.nil?

        Topic
          .where(category_id: category.id, deleted_at: nil)
          .where.not(id: category.topic_id)
          .count
      end

      # The row is gone when delete_all ran mid-sync; there is nothing to record.
      def fail!(message)
        return if !::DiscourseJournals::CoverSync.exists?(id: @cover_sync.id)

        @cover_sync.update!(status: :failed, error_message: message, completed_at: Time.current)
        publish("failed")
      end

      def publish(status, progress = {})
        MessageBus.publish(
          "/journals/cover-sync",
          { cover_sync_id: @cover_sync.id, status: status }.merge(progress).merge(
            error_message: status == "failed" ? @cover_sync.error_message : nil,
          ),
          user_ids: [@cover_sync.user_id],
        )
      end
    end
  end
end
