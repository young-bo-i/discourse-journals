# frozen_string_literal: true

namespace :discourse_journals do
  desc "Enqueue journal cover backfill jobs"
  task enqueue_cover_backfill: :environment do
    only_missing = ENV.fetch("ONLY_MISSING", "1") == "1"
    force = ENV.fetch("FORCE", "0") == "1"

    batches =
      DiscourseJournals::TopicCoverBackfill.enqueue_current_category!(
        only_missing: only_missing,
        force: force,
      )

    puts "Enqueued #{batches} journal cover backfill batch(es)."
  end
end
