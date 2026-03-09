# frozen_string_literal: true

module DiscourseJournals
  class TopicTitleKeyBackfill
    FIELD_NAME = "discourse_journals_normalized_title_key"

    class << self
      def backfill_current_category!
        new.backfill!
      end
    end

    def backfill!
      category_id = SiteSetting.discourse_journals_category_id.to_i
      raise Discourse::InvalidParameters.new(:discourse_journals_category_id) if category_id.zero?

      updated = 0

      Topic.where(category_id: category_id, deleted_at: nil).select(:id, :title).find_each do |topic|
        key = TitleMatcher.normalized_title_key(topic.title)
        next if key.blank?

        current =
          TopicCustomField.where(topic_id: topic.id, name: FIELD_NAME).pick(:value)
        next if current == key

        TopicCustomField.where(topic_id: topic.id, name: FIELD_NAME).delete_all
        TopicCustomField.create!(topic_id: topic.id, name: FIELD_NAME, value: key)
        updated += 1
      end

      updated
    end
  end
end
