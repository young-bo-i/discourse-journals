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

        import_log = ::DiscourseJournals::ImportLog.find_by(id: import_log_id)
        return unless import_log

        import_log.update!(status: :processing, started_at: Time.current)
        publish_progress(user_id, import_log, "开始同步...")

        # 创建导入器
        importer = ::DiscourseJournals::ApiSync::Importer.new(
          api_url: api_url,
          filters: filters,
          progress_callback: ->(current, total, message) {
            update_progress(import_log, user_id, current, total, message)
          }
        )

        # 根据模式执行
        if mode == "first_page"
          importer.import_first_page!(page_size: 100)
        else
          importer.import_all_pages!(page_size: 100)
        end

        # 完成
        import_log.update!(
          status: :completed,
          total_records: importer.processed_count,
          processed_records: importer.processed_count,
          created_count: importer.created_count,
          updated_count: importer.updated_count,
          skipped_count: importer.skipped_count,
          error_count: importer.errors.size,
          completed_at: Time.current,
          result_message: "同步完成：#{importer.created_count} 新建，#{importer.updated_count} 更新"
        )

        # 记录错误
        importer.errors.each do |error|
          import_log.add_error(error[:message], error[:details])
        end

        publish_progress(user_id, import_log, "同步完成！")

        Rails.logger.info(
          "[DiscourseJournals::Sync] Completed: #{importer.processed_count} processed, " \
          "#{importer.created_count} created, #{importer.updated_count} updated, " \
          "#{importer.skipped_count} skipped, #{importer.errors.size} errors"
        )
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
        publish_progress(user_id, import_log, "同步失败")
      end
    end
  end
end
