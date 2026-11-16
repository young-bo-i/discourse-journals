# frozen_string_literal: true

module DiscourseJournals
  # Opens closed journal topics so readers can reply. Columns only, in id
  # batches: a notice post, bump or notification for each of ~340K topics
  # would flood the site, and touching updated_at would make search engines
  # recrawl every journal page.
  module JournalTopicOpener
    BATCH_SIZE = 5_000

    def self.journal_topics
      Topic.where(category_id: SiteSetting.discourse_journals_category_id.to_i, deleted_at: nil)
    end

    def self.summary
      topics = journal_topics
      {
        total: topics.count,
        closed: topics.where(closed: true).count,
        close_setting: SiteSetting.discourse_journals_close_topics,
      }
    end

    def self.open_all!
      opened = 0
      journal_topics
        .where(closed: true)
        .in_batches(of: BATCH_SIZE) { |batch| opened += batch.update_all(closed: false) }
      opened
    end
  end
end
