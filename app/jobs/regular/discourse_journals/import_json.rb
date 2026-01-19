# frozen_string_literal: true

module Jobs
  module DiscourseJournals
    class ImportJson < ::Jobs::Base
      def execute(args)
        upload_id = args[:upload_id]
        import_log_id = args[:import_log_id]
        user_id = args[:user_id]

        upload = Upload.find_by(id: upload_id)
        import_log = ::DiscourseJournals::ImportLog.find_by(id: import_log_id)

        return if upload.blank?

        # 初始化日志
        if import_log
          import_log.update!(status: :processing, started_at: Time.current)
          publish_progress(user_id, import_log, "开始处理...")
        end

        file_path = Discourse.store.path_for(upload)
        if file_path.blank? || !File.exist?(file_path)
          fail_import(import_log, user_id, "文件不存在: #{file_path}")
          return
        end

        # 创建带进度回调的导入器
        importer = ::DiscourseJournals::JsonImport::Importer.new(
          file_path: file_path,
          progress_callback: ->(current, total, message) {
            update_progress(import_log, user_id, current, total, message)
          }
        )

        importer.import!

        # 完成导入
        if import_log
          import_log.update!(
            status: :completed,
            total_records: importer.processed_rows,
            processed_records: importer.processed_rows,
            created_count: importer.created_topics,
            updated_count: importer.updated_topics,
            skipped_count: importer.skipped_rows,
            error_count: importer.errors.size,
            completed_at: Time.current,
            result_message: "导入完成：#{importer.created_topics} 个新建，#{importer.updated_topics} 个更新"
          )

          # 记录错误
          importer.errors.each do |error|
            import_log.add_error(error[:message], error[:details])
          end

          publish_progress(user_id, import_log, "导入完成！")
        end

        Rails.logger.info(
          "[DiscourseJournals] Import completed: #{importer.processed_rows} processed, " \
          "#{importer.created_topics} created, #{importer.updated_topics} updated, " \
          "#{importer.skipped_rows} skipped, #{importer.errors.size} errors"
        )

      rescue StandardError => e
        Rails.logger.error("[DiscourseJournals] Import job failed: #{e.message}\n#{e.backtrace.join("\n")}")
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
          result_message: "导入失败: #{message}"
        )

        import_log.add_error(message, backtrace&.join("\n"))
        publish_progress(user_id, import_log, "导入失败")
      end
    end
  end
end
