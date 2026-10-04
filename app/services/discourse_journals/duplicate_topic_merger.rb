# frozen_string_literal: true

module DiscourseJournals
  # Retires a topic that tracks the same upstream record as an older topic.
  # The copy is trashed instead of flagged outdated because its journal is
  # still live, and a permalink sends its URL to the kept topic with a 301.
  class DuplicateTopicMerger
    def self.merge!(duplicate_id, keep_id)
      return false if duplicate_id == keep_id

      duplicate = Topic.find_by(id: duplicate_id)
      keep = Topic.find_by(id: keep_id)
      return false if duplicate.nil? || keep.nil?

      Topic.transaction do
        # Slugs are stored percent-encoded and Permalink encodes on save, so
        # pass the decoded path to end up matching the lookup of the old URL.
        url = UrlHelper.unencode(Permalink.normalize_url(duplicate.relative_url))
        if Permalink.find_by_url(duplicate.relative_url).nil?
          Permalink.create!(url: url, topic_id: keep.id)
        end
        duplicate.trash!(Discourse.system_user)
      end
      true
    rescue StandardError => e
      Rails.logger.warn(
        "[DiscourseJournals::DuplicateTopicMerger] Failed to merge topic #{duplicate_id} into #{keep_id}: #{e.message}",
      )
      false
    end
  end
end
