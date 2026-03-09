# frozen_string_literal: true

module Jobs
  module DiscourseJournals
    class ProcessJournalCovers < ::Jobs::Base
      sidekiq_options retry: 1, queue: "low"

      BATCH_SIZE = 50

      def execute(args)
        topic_ids = args[:topic_ids]
        force = args[:force] == true
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
            result = TopicCoverManager.process!(
              topic: topic,
              cover_url: cf["discourse_journals_cover_url"],
              issn: cf["discourse_journals_issn_l"],
              country: cf["discourse_journals_country"],
              publisher: cf["discourse_journals_publisher"],
              force: force,
              thumbnail_sizes: thumbnail_sizes,
            )
            deferred_topic_ids << topic.id if result == :deferred
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
            )
          end
        end
      end
    end
  end
end
