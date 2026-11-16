# frozen_string_literal: true

module DiscourseJournals
  class AdminTopicsController < ::Admin::AdminController
    requires_plugin DiscourseJournals::PLUGIN_NAME

    # GET /admin/journals/topics/status
    def status
      render_json_dump({ topics: JournalTopicOpener.summary })
    end

    # POST /admin/journals/topics/open_all
    # Also turns discourse_journals_close_topics off, so the syncs that follow
    # keep the topics open instead of closing them again.
    def open_all
      if SiteSetting.discourse_journals_close_topics
        SiteSetting.set_and_log(:discourse_journals_close_topics, false, current_user)
      end
      Jobs.enqueue(Jobs::DiscourseJournals::OpenJournalTopics)

      render_json_dump({ topics: JournalTopicOpener.summary })
    end
  end
end
