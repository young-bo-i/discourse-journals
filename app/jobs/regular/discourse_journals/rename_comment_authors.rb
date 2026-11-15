# frozen_string_literal: true

module Jobs
  module DiscourseJournals
    # Re-derives every collected reply's anonymous name after the word lists change.
    class RenameCommentAuthors < ::Jobs::Base
      sidekiq_options retry: 0, queue: "low"

      def execute(_args)
        ::DiscourseJournals::CommentPost
          .distinct
          .pluck(:topic_id)
          .each { |topic_id| ::DiscourseJournals::CommentAuthor.assign!(topic_id) }
      end
    end
  end
end
