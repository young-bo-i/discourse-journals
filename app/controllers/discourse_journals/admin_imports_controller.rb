# frozen_string_literal: true

module DiscourseJournals
  class AdminImportsController < ::Admin::AdminController
    requires_plugin DiscourseJournals::PLUGIN_NAME

    def create
      raise Discourse::InvalidParameters.new if params[:file].blank?

      if SiteSetting.discourse_journals_category_id.blank?
        return render_json_error(I18n.t("discourse_journals.errors.missing_category"))
      end

      Rails.logger.info("[DiscourseJournals] Starting import: #{params[:file].original_filename}")

      upload = create_upload!(params[:file])
      
      if upload.blank?
        Rails.logger.error("[DiscourseJournals] Failed to create upload")
        return render_json_error("Failed to upload file")
      end

      # 创建导入日志记录
      import_log = ImportLog.create!(
        upload_id: upload.id,
        user_id: current_user.id,
        status: :pending,
        started_at: Time.current
      )

      Rails.logger.info("[DiscourseJournals] Upload created: ID=#{upload.id}, Log=#{import_log.id}")
      
      Jobs.enqueue(
        Jobs::DiscourseJournals::ImportJson, 
        upload_id: upload.id,
        import_log_id: import_log.id,
        user_id: current_user.id
      )

      render_json_dump(
        {
          status: "started",
          upload_id: upload.id,
          import_log_id: import_log.id,
          message: I18n.t("discourse_journals.admin.imports.started")
        }
      )
    rescue StandardError => e
      Rails.logger.error("[DiscourseJournals] Import controller error: #{e.message}\n#{e.backtrace.join("\n")}")
      render_json_error("Import failed: #{e.message}")
    end

    def status
      import_log = ImportLog.find_by(id: params[:id])
      
      if import_log.blank?
        return render_json_error("Import log not found", status: 404)
      end

      render_json_dump(
        {
          id: import_log.id,
          status: import_log.status,
          progress: import_log.progress_percent,
          total_records: import_log.total_records,
          processed_records: import_log.processed_records,
          created_count: import_log.created_count,
          updated_count: import_log.updated_count,
          skipped_count: import_log.skipped_count,
          error_count: import_log.error_count,
          errors: import_log.errors_data || [],
          started_at: import_log.started_at,
          completed_at: import_log.completed_at,
          result_message: import_log.result_message
        }
      )
    end

    def logs
      logs = ImportLog
        .order(created_at: :desc)
        .limit(params[:limit]&.to_i || 50)
        .select(:id, :upload_id, :status, :total_records, :processed_records, 
                :created_count, :updated_count, :error_count, :started_at, :completed_at)

      render_json_dump(logs: logs)
    end

    private

    def create_upload!(file_param)
      tempfile = file_param.tempfile
      filename = file_param.original_filename.presence || "journals.json"

      Rails.logger.info("[DiscourseJournals] Creating upload: #{filename}, size: #{tempfile.size} bytes")

      upload = UploadCreator.new(
        tempfile, 
        filename, 
        type: "json", 
        for_private_message: false
      ).create_for(Discourse.system_user.id)

      if upload.blank?
        Rails.logger.error("[DiscourseJournals] UploadCreator returned nil")
      elsif upload.errors.any?
        Rails.logger.error("[DiscourseJournals] Upload errors: #{upload.errors.full_messages.join(", ")}")
      end

      upload
    end
  end
end
