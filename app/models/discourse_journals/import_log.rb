# frozen_string_literal: true

module DiscourseJournals
  class ImportLog < ActiveRecord::Base
    self.table_name = "discourse_journals_import_logs"

    validates :upload_id, presence: true
    validates :status, presence: true

    enum status: { pending: 0, processing: 1, completed: 2, failed: 3 }

    def add_error(message, details = nil)
      self.errors_data ||= []
      self.errors_data << {
        message: message,
        details: details,
        timestamp: Time.current.iso8601
      }
      self.error_count += 1
      save
    end

    def progress_percent
      return 0 if total_records.to_i.zero?
      ((processed_records.to_f / total_records) * 100).round(2)
    end
  end
end
