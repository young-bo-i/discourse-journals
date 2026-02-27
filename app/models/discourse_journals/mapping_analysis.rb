# frozen_string_literal: true

module DiscourseJournals
  class MappingAnalysis < ActiveRecord::Base
    self.table_name = "discourse_journals_mapping_analyses"

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

    def self.has_active?
      where(status: %i[pending processing]).exists?
    end

    def self.has_running?
      where(status: %i[pending processing paused]).exists?
    end

    def progress_percent
      return 100 if completed?
      return 0 if pending?
      50
    end

    def can_apply?
      completed? && (not_applied? || sync_processing?)
    end

    def can_resume_apply?
      completed? && (sync_paused? || sync_failed? || sync_processing?)
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

      all_items = details_data&.dig(category.to_s) || []
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
