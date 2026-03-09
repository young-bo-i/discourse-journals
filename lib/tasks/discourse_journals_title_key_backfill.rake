# frozen_string_literal: true

namespace :discourse_journals do
  desc "Backfill normalized title keys for journal topics"
  task backfill_normalized_title_keys: :environment do
    updated = DiscourseJournals::TopicTitleKeyBackfill.backfill_current_category!
    puts "Backfilled normalized title keys for #{updated} journal topic(s)."
  end
end
