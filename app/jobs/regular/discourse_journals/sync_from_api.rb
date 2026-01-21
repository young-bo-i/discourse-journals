# frozen_string_literal: true

module Jobs
  module DiscourseJournals
    class SyncFromApi < ::Jobs::Base
      def execute(args)
        import_log_id = args[:import_log_id]
        user_id = args[:user_id]
        api_url = args[:api_url]
        mode = args[:mode] # "first_page" 或 "all_pages"
        filters = args[:filters] || {}
        resume = args[:resume] || false

        import_log = ::DiscourseJournals::ImportLog.find_by(id: import_log_id)
        return unless import_log

        # 如果是恢复模式，从保存的配置中读取
        if resume && import_log.resumable?
          api_url ||= import_log.api_url
          filters = import_log.filters&.deep_symbolize_keys || filters
          mode ||= import_log.import_mode
        end

        import_log.update!(
          status: :processing, 
          started_at: import_log.started_at || Time.current,
          api_url: api_url,
          filters: filters,
          import_mode: mode
        )
        
        start_message = resume ? "恢复导入..." : "开始同步..."
        publish_progress(user_id, import_log, start_message)

        # 创建导入器（传入 import_log 以支持暂停检查）
        importer = ::DiscourseJournals::ApiSync::Importer.new(
          api_url: api_url,
          filters: filters,
          import_log: import_log,
          progress_callback: ->(current, total, message) {
            update_progress(import_log, user_id, current, total, message)
          }
        )

        # 根据模式执行
        page_size = import_log.page_size || 100
        if mode == "first_page"
          importer.import_first_page!(page_size: page_size)
        else
          # 支持断点续传
          start_page = resume ? import_log.resume_from_page : 1
          skip_count = resume ? (import_log.processed_records || 0) : 0
          importer.import_all_pages!(page_size: page_size, start_page: start_page, skip_count: skip_count)
        end

        # 根据是否暂停决定最终状态
        if importer.paused
          # 暂停状态，保持 paused 状态（已在 model 中设置）
          import_log.update!(
            created_count: import_log.created_count.to_i + importer.created_count,
            updated_count: import_log.updated_count.to_i + importer.updated_count,
            skipped_count: import_log.skipped_count.to_i + importer.skipped_count,
            error_count: import_log.error_count.to_i + importer.errors.size,
            result_message: "已暂停：#{import_log.processed_records}/#{import_log.total_records} (可恢复)"
          )
          
          publish_progress(user_id, import_log, "导入已暂停，可随时点击恢复继续")
          
          Rails.logger.info(
            "[DiscourseJournals::Sync] Paused at page #{importer.current_page}: " \
            "#{import_log.processed_records} processed"
          )
        else
          # 完成状态
          import_log.update!(
            status: :completed,
            created_count: import_log.created_count.to_i + importer.created_count,
            updated_count: import_log.updated_count.to_i + importer.updated_count,
            skipped_count: import_log.skipped_count.to_i + importer.skipped_count,
            error_count: import_log.error_count.to_i + importer.errors.size,
            completed_at: Time.current,
            result_message: "同步完成：#{import_log.created_count} 新建，#{import_log.updated_count} 更新"
          )

          # 记录错误（只记录前100个，避免日志过大）
          record_errors(import_log, importer.errors)

          publish_progress(user_id, import_log, "同步完成！")

          Rails.logger.info(
            "[DiscourseJournals::Sync] Completed: #{import_log.processed_records} processed, " \
            "#{import_log.created_count} created, #{import_log.updated_count} updated, " \
            "#{import_log.skipped_count} skipped, #{import_log.error_count} errors"
          )
        end
      rescue StandardError => e
        Rails.logger.error("[DiscourseJournals::Sync] Failed: #{e.message}\n#{e.backtrace.join("\n")}")
        fail_import(import_log, user_id, e.message, e.backtrace.first(5))
        raise e
      end

      private

      def update_progress(import_log, user_id, current, total, message)
        return unless import_log

        import_log.update!(
          total_records: total,
          processed_records: current
        )

        publish_progress(user_id, import_log, message)
      end

      def publish_progress(user_id, import_log, message)
        return unless user_id && import_log

        MessageBus.publish(
          "/journals/import/#{import_log.id}",
          {
            import_log_id: import_log.id,
            status: import_log.status,
            progress: import_log.progress_percent,
            processed: import_log.processed_records,
            total: import_log.total_records,
            created: import_log.created_count,
            updated: import_log.updated_count,
            skipped: import_log.skipped_count,
            errors: import_log.error_count,
            message: message
          },
          user_ids: [user_id]
        )
      end

      def fail_import(import_log, user_id, message, backtrace = nil)
        return unless import_log

        import_log.update!(
          status: :failed,
          completed_at: Time.current,
          result_message: "同步失败: #{message}"
        )

        import_log.add_error(message, backtrace&.join("\n"))
        publish_progress(user_id, import_log, "同步失败（可尝试恢复）")
      end

      def record_errors(import_log, errors)
        return if errors.blank?
        
        errors.take(100).each do |error|
          error_message = "#{error[:title]} (#{error[:issn]}): #{error[:reason]}"
          error_details = if error[:backtrace]
            "Error: #{error[:error_class]}\nBacktrace:\n#{error[:backtrace].join("\n")}"
          else
            nil
          end
          import_log.add_error(error_message, error_details)
        end
        
        # 如果错误太多，添加一条总结
        if errors.size > 100
          import_log.add_error(
            "...还有 #{errors.size - 100} 个错误未显示",
            "查看服务器日志获取完整错误列表"
          )
        end
      end
    end
  end
end
