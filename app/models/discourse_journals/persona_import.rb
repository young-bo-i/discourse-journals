# frozen_string_literal: true

module DiscourseJournals
  class PersonaImport < ActiveRecord::Base
    self.table_name = "discourse_journals_persona_imports"

    validates :user_id, presence: true
    validates :status, presence: true

    enum :status, { pending: 0, processing: 1, completed: 2, failed: 3 }

    scope :latest, -> { order(created_at: :desc) }
    # rows_data can hold the full uploaded list (up to tens of thousands of rows);
    # exclude it from the read paths that only need progress/status.
    scope :lightweight, -> { select(column_names - ["rows_data"]) }

    def self.current
      latest.first
    end

    def self.current_light
      lightweight.latest.first
    end

    def self.active?
      where(status: %i[pending processing]).exists?
    end

    def summary
      s = stats || {}
      {
        status: status,
        total: total,
        created: s["created"] || 0,
        skipped: s["skipped"] || 0,
        errors: s["errors"] || 0,
        errors_sample: s["errors_sample"] || [],
        error_message: error_message,
        started_at: started_at,
        completed_at: completed_at,
      }
    end
  end
end
