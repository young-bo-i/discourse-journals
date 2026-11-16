# frozen_string_literal: true

module Jobs
  module DiscourseJournals
    class OpenJournalTopics < ::Jobs::Base
      sidekiq_options retry: 0, queue: "low"

      def execute(_args)
        opened = ::DiscourseJournals::JournalTopicOpener.open_all!
        Rails.logger.info("[DiscourseJournals::OpenJournalTopics] Opened #{opened} journal topics")
      end
    end
  end
end
