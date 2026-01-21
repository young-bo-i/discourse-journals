# frozen_string_literal: true

module DiscourseJournals
  class ImportLog < ActiveRecord::Base
    self.table_name = "discourse_journals_import_logs"

    validates :upload_id, presence: true
    validates :user_id, presence: true
    validates :status, presence: true

    # 状态: pending(等待), processing(进行中), completed(完成), failed(失败), paused(已暂停), cancelled(已取消)
    enum :status, { pending: 0, processing: 1, completed: 2, failed: 3, paused: 4, cancelled: 5 }

    # 查找可恢复的导入任务
    scope :resumable, -> { where(status: [:paused, :failed]) }
    scope :active, -> { where(status: [:pending, :processing]) }
    scope :incomplete, -> { where(status: [:pending, :processing, :paused]) }

    # ============ 单例模式方法 ============

    # 获取当前导入记录（单例）
    def self.current
      order(created_at: :desc).first
    end

    # 获取或创建导入记录（单例）
    def self.find_or_initialize_current(user_id:)
      current || new(upload_id: 0, user_id: user_id, status: :pending)
    end

    # 开始新的导入任务（重置现有记录或创建新记录）
    def self.start_new!(user_id:, api_url:, filters: {}, import_mode: "all_pages")
      # 删除所有旧记录，保持单例
      delete_all

      create!(
        upload_id: 0,
        user_id: user_id,
        status: :pending,
        started_at: Time.current,
        api_url: api_url.to_s,
        filters: filters.is_a?(Hash) ? filters : {},
        import_mode: import_mode.to_s
      )
    end

    # 删除导入记录（取消时调用）
    def self.clear!
      delete_all
    end

    # 是否有活动的导入任务
    def self.has_active?
      active.exists?
    end

    # 是否有可恢复的任务
    def self.has_resumable?
      resumable.exists?
    end

    # 是否有未完成的任务
    def self.has_incomplete?
      incomplete.exists?
    end

    # ============ 实例方法 ============

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

    # 取消导入（删除记录）
    def cancel!
      return if completed?
      # 先标记为取消（让正在运行的 Job 知道要停止）
      update!(status: :cancelled, completed_at: Time.current, result_message: "任务已取消")
    end

    # 取消后删除记录
    def cancel_and_delete!
      cancel!
      destroy!
    end

    # 检查是否应该暂停（被外部请求暂停）
    def should_pause?
      safe_reload
      paused?
    end

    # 检查是否应该取消
    def should_cancel?
      safe_reload
      cancelled? || destroyed?
    end

    # 检查是否应该停止（暂停或取消）
    def should_stop?
      safe_reload
      paused? || cancelled? || destroyed?
    end

    # 安全地重新加载记录（处理记录被删除的情况）
    def safe_reload
      reload
    rescue ActiveRecord::RecordNotFound
      # 记录已被删除，标记为已销毁
      @destroyed = true
    end

    # 检查记录是否已被销毁
    def destroyed?
      @destroyed || !self.class.exists?(id)
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

