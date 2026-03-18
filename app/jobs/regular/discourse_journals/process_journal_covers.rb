# frozen_string_literal: true

module Jobs
  module DiscourseJournals
    class ProcessJournalCovers < ::Jobs::Base
      sidekiq_options retry: 1, queue: "low"

      BATCH_SIZE = 50
      PROGRESS_PUBLISH_INTERVAL = 10

      def execute(args)
        topic_ids = args[:topic_ids]
        force = args[:force] == true
        @analysis_id = args[:analysis_id]
        @user_id = args[:user_id]
        @cover_total = args[:cover_total].to_i

        return if topic_ids.blank?
        return unless SiteSetting.discourse_journals_download_covers

        thumbnail_sizes =
          ThemeModifierHelper.new(theme_ids: Theme.user_selectable.pluck(:id)).topic_thumbnail_sizes

        DiscourseJournals::PerformanceLogger.log(
          "cover.job.start",
          source_type: "process_journal_covers",
          elapsed_ms: 0,
          batch_size: topic_ids.size,
          force: force,
        )

        batch_processed = 0

        topic_ids.each_slice(BATCH_SIZE) do |batch_ids|
          deferred_topic_ids = []
          batch_custom_fields = TopicCustomField
            .where(
              topic_id: batch_ids,
              name: %w[
                discourse_journals_cover_url
                discourse_journals_issn_l
                discourse_journals_country
                discourse_journals_publisher
              ],
            )
            .pluck(:topic_id, :name, :value)
            .group_by(&:first)
            .transform_values { |rows| rows.map { |_, n, v| [n, v] }.to_h }

          Topic.where(id: batch_ids).find_each do |topic|
            cf = batch_custom_fields[topic.id] || {}
            result = DiscourseJournals::TopicCoverManager.process!(
              topic: topic,
              cover_url: cf["discourse_journals_cover_url"],
              issn: cf["discourse_journals_issn_l"],
              country: cf["discourse_journals_country"],
              publisher: cf["discourse_journals_publisher"],
              force: force,
              thumbnail_sizes: thumbnail_sizes,
            )

            if result == :deferred
              deferred_topic_ids << topic.id
            else
              batch_processed += 1
              increment_progress
              publish_progress_throttled(batch_processed)
            end
          end

          if deferred_topic_ids.any?
            DiscourseJournals::PerformanceLogger.log(
              "cover.job.defer_reenqueue",
              source_type: "process_journal_covers",
              deferred: true,
              elapsed_ms: 0,
              batch_size: deferred_topic_ids.size,
              force: force,
            )
            Jobs.enqueue_in(
              1.minute,
              self.class,
              topic_ids: deferred_topic_ids,
              force: force,
              analysis_id: @analysis_id,
              user_id: @user_id,
              cover_total: @cover_total,
            )
          end
        end

        publish_progress_now
        check_completion
      end

      private

      def tracking_enabled?
        @analysis_id.present? && @user_id.present? && @cover_total > 0
      end

      def redis_key
        "discourse_journals:cover_progress:#{@analysis_id}"
      end

      def increment_progress
        return unless tracking_enabled?
        Discourse.redis.incr(redis_key)
      end

      def current_processed
        return 0 unless tracking_enabled?
        Discourse.redis.get(redis_key).to_i
      end

      def publish_progress_throttled(batch_processed)
        return unless tracking_enabled?
        return unless batch_processed % PROGRESS_PUBLISH_INTERVAL == 0
        publish_progress_now
      end

      def publish_progress_now
        return unless tracking_enabled?

        processed = current_processed
        percent = @cover_total > 0 ? [(processed * 100.0 / @cover_total).round, 100].min : 0

        MessageBus.publish(
          "/journals/cover-processing",
          {
            analysis_id: @analysis_id,
            status: "processing",
            progress: percent,
            total: @cover_total,
            processed: processed,
            message: "封面处理中... #{processed}/#{@cover_total}",
          },
          user_ids: [@user_id],
        )

        update_analysis_stats(processed)
      end

      def check_completion
        return unless tracking_enabled?

        processed = current_processed
        return unless processed >= @cover_total

        Discourse.redis.del(redis_key)

        analysis = ::DiscourseJournals::MappingAnalysis.find_by(id: @analysis_id)
        return unless analysis

        analysis.update_columns(
          cover_status: ::DiscourseJournals::MappingAnalysis.cover_statuses[:cover_completed],
          cover_stats: { "total" => @cover_total, "processed" => processed },
        )

        MessageBus.publish(
          "/journals/cover-processing",
          {
            analysis_id: @analysis_id,
            status: "completed",
            progress: 100,
            total: @cover_total,
            processed: processed,
            message: "封面处理完成！#{processed}/#{@cover_total}",
          },
          user_ids: [@user_id],
        )
      end

      def update_analysis_stats(processed)
        ::DiscourseJournals::MappingAnalysis
          .where(id: @analysis_id)
          .update_all(cover_stats: { "total" => @cover_total, "processed" => processed })
      rescue StandardError => e
        Rails.logger.warn("[DiscourseJournals::ProcessJournalCovers] Failed to update analysis stats: #{e.message}")
      end
    end
  end
end
