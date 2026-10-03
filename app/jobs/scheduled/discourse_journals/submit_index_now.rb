# frozen_string_literal: true

module Jobs
  module DiscourseJournals
    class SubmitIndexNow < ::Jobs::Scheduled
      every 30.minutes

      def execute(_args)
        ::DiscourseJournals::IndexNow.submit_pending!
      end
    end
  end
end
