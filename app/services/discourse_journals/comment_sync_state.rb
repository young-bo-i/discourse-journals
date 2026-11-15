# frozen_string_literal: true

module DiscourseJournals
  # The latest comment-sync run. Runs are admin-started and one at a time, so a
  # single PluginStore row holds everything the admin page shows.
  module CommentSyncState
    KEY = "comment_sync"
    ACTIVE = %w[pending processing].freeze
    MAX_JOURNALS = 200

    # The job writes a heartbeat after every topic; silence means it died
    # without reaching its rescue (e.g. SIGKILL).
    STALE_AFTER = 15.minutes

    def self.current
      PluginStore.get(PLUGIN_NAME, KEY)
    end

    def self.write(state)
      PluginStore.set(PLUGIN_NAME, KEY, state)
      state
    end

    def self.update(**changes)
      state = current
      return nil if state.nil?

      write(state.merge(changes.stringify_keys))
    end

    def self.running?
      state = current
      state.present? && ACTIVE.include?(state["status"]) && !stale?(state)
    end

    def self.stale?(state)
      ACTIVE.include?(state["status"]) && state["heartbeat_at"].to_i < STALE_AFTER.ago.to_i
    end

    def self.start!(user_id:, topic_ids:, limit:)
      write(
        "id" => SecureRandom.hex(8),
        "status" => "pending",
        "user_id" => user_id,
        "topic_ids" => topic_ids,
        "limit" => limit,
        "total" => 0,
        "processed" => 0,
        "stats" => {
        },
        "error_message" => nil,
        "started_at" => Time.current.iso8601,
        "completed_at" => nil,
        "heartbeat_at" => Time.current.to_i,
      )
    end

    def self.summary
      state = current
      return nil if state.nil?

      stale = stale?(state)
      {
        status: stale ? "failed" : state["status"],
        total: state["total"].to_i,
        processed: state["processed"].to_i,
        stats: state["stats"] || {},
        topic_ids: state["topic_ids"] || [],
        error_message:
          (
            if stale
              I18n.t("discourse_journals.comment_sync.errors.interrupted")
            else
              state["error_message"]
            end
          ),
        started_at: state["started_at"],
        completed_at: state["completed_at"],
      }
    end
  end
end
