# frozen_string_literal: true

module DiscourseJournals
  class ImportLog < ActiveRecord::Base
    self.table_name = "discourse_journals_import_logs"

    validates :upload_id, presence: true
    validates :status, presence: true

    # 状态: pending(等待), processing(进行中), completed(完成), failed(失败), paused(已暂停)
    enum :status, { pending: 0, processing: 1, completed: 2, failed: 3, paused: 4 }

    # 查找可恢复的导入任务
    scope :resumable, -> { where(status: [:paused, :failed]) }
    scope :active, -> { where(status: [:pending, :processing]) }

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

    # 暂停导入
    def pause!
      return unless processing?
      update!(status: :paused, paused_at: Time.current)
    end

    # 检查是否应该暂停（被外部请求暂停）
    def should_pause?
      # 重新加载以获取最新状态
      reload
      paused?
    end

    # 是否可以恢复
    def resumable?
      paused? || failed?
    end

    # 恢复导入
    def resume!
      return unless resumable?
      update!(status: :processing, paused_at: nil)
    end

    # 更新进度（包含页码信息）
    def update_progress!(page:, processed:, total:, last_issn: nil)
      update!(
        current_page: page,
        processed_records: processed,
        total_records: total,
        last_processed_issn: last_issn
      )
    end

    # 获取恢复起始页（从上次暂停的页码开始）
    def resume_from_page
      current_page || 1
    end
  end
end

