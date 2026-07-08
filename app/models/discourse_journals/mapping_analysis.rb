# frozen_string_literal: true

module DiscourseJournals
  class MappingAnalysis < ActiveRecord::Base
    self.table_name = "discourse_journals_mapping_analyses"
    STALE_APPLY_THRESHOLD = 15.minutes

    validates :user_id, presence: true
    validates :status, presence: true

    enum :status, { pending: 0, processing: 1, completed: 2, failed: 3, paused: 4 }
    enum :apply_status, {
      not_applied: 0,
      sync_processing: 1,
      sync_completed: 2,
      sync_failed: 3,
      sync_paused: 4,
    }

    CATEGORIES = %w[exact_1to1 forum_1_to_api_n forum_n_to_api_1 forum_n_to_api_m forum_only api_only].freeze

    scope :latest, -> { order(created_at: :desc) }
    scope :lightweight, -> { select(column_names - ["details_data"]) }

    def self.current
      latest.first
    end

    # For read paths that never touch the (potentially huge) details_data column —
    # e.g. the polled status endpoints. details_for fetches its bucket via SQL by
    # id, so it works on a lightweight record too.
    def self.current_light
      lightweight.latest.first
    end

    def self.has_active?
      where(status: %i[pending processing]).exists?
    end

    def progress_percent
      return 100 if completed?
      return 0 if pending?
      50
    end

    def can_apply?
      completed? && not_applied?
    end

    def can_resume_apply?
      completed? && (sync_paused? || sync_failed? || stale_sync_processing?)
    end

    def stale_sync_processing?
      return false unless sync_processing?
      last = apply_heartbeat_at
      last.present? && last < STALE_APPLY_THRESHOLD.ago
    end

    # The applier refreshes a heartbeat epoch inside apply_checkpoint on every
    # batch, so a healthy long-running apply is never mistaken for a crashed one.
    # Falls back to apply_started_at before the first checkpoint (and for legacy
    # rows written before heartbeating existed).
    def apply_heartbeat_at
      hb = apply_checkpoint.is_a?(Hash) ? apply_checkpoint["heartbeat"] : nil
      hb ? Time.zone.at(hb.to_i) : apply_started_at
    end

    def summary
      {
        total_forum_topics: total_forum_topics,
        total_api_records: total_api_records,
        exact_1to1: exact_1to1_count,
        forum_1_to_api_n: forum_1_to_api_n_count,
        forum_n_to_api_1: forum_n_to_api_1_count,
        forum_n_to_api_m: forum_n_to_api_m_count,
        forum_only: forum_only_count,
        api_only: api_only_count,
      }
    end

    def apply_summary
      stats = apply_stats || {}
      {
        status: apply_status,
        deleted: stats["deleted"] || 0,
        updated: stats["updated"] || 0,
        created: stats["created"] || 0,
        skipped: stats["skipped"] || 0,
        errors: stats["errors"] || 0,
        error_message: apply_error_message,
        started_at: apply_started_at,
        completed_at: apply_completed_at,
      }
    end

    def details_for(category, page: 1, per_page: 50)
      unless CATEGORIES.include?(category.to_s)
        return { items: [], total: 0, page: page, per_page: per_page, total_pages: 0 }
      end

      # Fetch only the requested bucket from Postgres instead of loading the whole
      # details_data column (which also carries _action_plan with up to hundreds of
      # thousands of entries) into Ruby just to slice ≤500 rows. category is
      # whitelisted above, so the jsonb key is safe to bind. Cast to ::text so the
      # value comes back as a JSON string (mini_sql auto-decodes bare jsonb to a
      # Ruby object, which would then break JSON.parse); NULL (missing key) -> nil.
      raw =
        DB.query_single(
          "SELECT (details_data -> :cat)::text FROM discourse_journals_mapping_analyses WHERE id = :id",
          cat: category.to_s,
          id: id,
        ).first
      all_items = raw.present? ? JSON.parse(raw) : []
      offset = (page - 1) * per_page
      {
        items: all_items[offset, per_page] || [],
        total: all_items.size,
        page: page,
        per_page: per_page,
        total_pages: (all_items.size.to_f / per_page).ceil,
      }
    end
  end
end
