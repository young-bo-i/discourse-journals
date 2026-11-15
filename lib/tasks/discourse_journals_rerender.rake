# frozen_string_literal: true

namespace :discourse_journals do
  desc <<~DESC
    Rewrite journal first posts from their stored JSON (no upstream requests).
    Optional env: AFTER_ID (resume after this topic id), LIMIT (stop after N topics),
    TOPIC_IDS (comma-separated ids to render only those topics).
  DESC
  task rerender_cooked: :environment do
    after_id = ENV["AFTER_ID"].to_i
    limit = ENV["LIMIT"].presence&.to_i
    topic_ids = ENV["TOPIC_IDS"].presence&.split(",")&.map(&:to_i)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    result =
      DiscourseJournals::CookedRerenderer
        .new
        .rerender_all!(after_id: after_id, limit: limit, topic_ids: topic_ids) do |progress|
          elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round
          puts "rendered=#{progress.rendered} skipped=#{progress.skipped} failed=#{progress.failed} " \
                 "last_topic_id=#{progress.last_topic_id} elapsed=#{elapsed}s"
        end

    puts "Done: rendered=#{result.rendered} skipped=#{result.skipped} failed=#{result.failed} " \
           "last_topic_id=#{result.last_topic_id}"
  end
end
