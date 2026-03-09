# frozen_string_literal: true

module DiscourseJournals
  class TopicCoverBackfill
    DEFAULT_BATCH_SIZE = 100
    DEFAULT_DELAY_SECONDS = 90

    class << self
      def enqueue_current_category!(only_missing: false, force: false)
        new(only_missing: only_missing, force: force).enqueue!
      end
    end

    def initialize(only_missing: false, force: false)
      @only_missing = only_missing
      @force = force
    end

    def enqueue!
      PerformanceLogger.measure("cover.backfill.enqueue", source_type: "backfill", deferred: false) do
        total_batches = 0

        scope.find_in_batches(batch_size: DEFAULT_BATCH_SIZE).with_index do |topics, batch_index|
          topic_ids = topics.map(&:id)
          next if topic_ids.empty?

          Jobs.enqueue_in(
            batch_index * DEFAULT_DELAY_SECONDS,
            Jobs::DiscourseJournals::ProcessJournalCovers,
            topic_ids: topic_ids,
            force: @force,
          )
          total_batches += 1
        end

        total_batches
      end
    end

    private

    def scope
      @scope ||= begin
        cid = SiteSetting.discourse_journals_category_id.to_i
        raise Discourse::InvalidParameters.new(:discourse_journals_category_id) if cid.zero?

        relation = Topic.where(category_id: cid, deleted_at: nil).select(:id)
        relation = relation.where(image_upload_id: nil) if @only_missing
        relation.order(:id)
      end
    end
  end
end
