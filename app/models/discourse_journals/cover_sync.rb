# frozen_string_literal: true

module DiscourseJournals
  # One cover-sync run. Lives in its own table on purpose: analyze/restart wipe
  # discourse_journals_mapping_analyses, so state kept there does not survive.
  class CoverSync < ActiveRecord::Base
    self.table_name = "discourse_journals_cover_syncs"

    STALE_THRESHOLD = 15.minutes

    enum :status, { pending: 0, processing: 1, completed: 2, failed: 3, paused: 4 }

    validates :user_id, presence: true

    scope :latest, -> { order(id: :desc) }

    def self.current
      latest.first
    end

    def self.running?
      current&.running? || false
    end

    def active?
      pending? || processing?
    end

    # A SIGKILLed job never reaches its rescue and leaves the row active forever.
    # The syncer refreshes the heartbeat every batch, so silence means it died.
    def stale?
      active? && heartbeat_at < STALE_THRESHOLD.ago
    end

    def running?
      active? && !stale?
    end

    def can_resume?
      paused? || failed? || stale?
    end

    def heartbeat_at
      heartbeat = checkpoint.is_a?(Hash) ? checkpoint["heartbeat"] : nil
      heartbeat ? Time.zone.at(heartbeat.to_i) : started_at || created_at
    end

    def summary
      {
        id: id,
        status: stale? ? "failed" : status,
        total: total,
        processed: checkpoint.is_a?(Hash) ? checkpoint["processed"].to_i : 0,
        stats: stats || {},
        error_message:
          stale? ? I18n.t("discourse_journals.cover_sync.errors.interrupted") : error_message,
        started_at: started_at,
        completed_at: completed_at,
      }
    end
  end
end
