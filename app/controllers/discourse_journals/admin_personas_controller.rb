# frozen_string_literal: true

module DiscourseJournals
  class AdminPersonasController < ::Admin::AdminController
    requires_plugin DiscourseJournals::PLUGIN_NAME

    MAX_FILE_SIZE = 20.megabytes

    # POST /admin/journals/personas/import  (multipart: file)
    def import
      if PersonaImport.active?
        return render_json_error("已有账号池导入任务正在进行中")
      end

      file = params[:file]
      return render_json_error("请选择要上传的文件（CSV 或 JSON）") if file.blank?
      return render_json_error("文件过大（上限 20MB）") if file.size > MAX_FILE_SIZE

      content = file.read.to_s
      content = content.force_encoding("UTF-8") if content.encoding != Encoding::UTF_8

      begin
        rows = PersonaFileParser.parse(content, file.original_filename)
      rescue PersonaFileParser::ParseError => e
        return render_json_error(e.message)
      end

      # Keep the table tidy: drop old finished imports.
      PersonaImport.where(status: %i[completed failed]).where("created_at < ?", 1.day.ago).delete_all

      import =
        PersonaImport.create!(
          user_id: current_user.id,
          status: :pending,
          total: rows.size,
          rows_data: rows,
          stats: {},
        )

      Jobs.enqueue(
        Jobs::DiscourseJournals::ImportPersonas,
        import_id: import.id,
        user_id: current_user.id,
      )

      render json: {
        status: "started",
        import_id: import.id,
        total: rows.size,
        message: "账号池导入已启动（共 #{rows.size} 条）...",
      }
    rescue StandardError => e
      Rails.logger.error("[DiscourseJournals::Personas] import failed: #{e.message}")
      render_json_error("启动导入失败: #{e.message}")
    end

    # GET /admin/journals/personas/status
    def status
      import = PersonaImport.current_light

      if import.nil?
        return render_json_dump({ has_import: false, persona_count: persona_count })
      end

      render_json_dump({ has_import: true, persona_count: persona_count, import: import.summary })
    end

    private

    def persona_count
      group = ::Group.find_by(name: PersonaPool::GROUP_NAME)
      group ? GroupUser.where(group_id: group.id).count : 0
    end
  end
end
