# frozen_string_literal: true

module DiscourseJournals
  class AdminImportsController < ::Admin::AdminController
    requires_plugin DiscourseJournals::PLUGIN_NAME

    def create
      raise Discourse::InvalidParameters.new if params[:file].blank?

      if SiteSetting.discourse_journals_category_id.blank?
        return render_json_error(I18n.t("discourse_journals.errors.missing_category"))
      end

      upload = create_upload!(params[:file])
      
      Jobs.enqueue(Jobs::DiscourseJournals::ImportJson, upload_id: upload.id)

      render_json_dump(
        {
          status: "started",
          upload_id: upload.id,
          message: I18n.t("discourse_journals.admin.imports.started")
        }
      )
    end

    private

    def create_upload!(file_param)
      tempfile = file_param.tempfile
      filename = file_param.original_filename.presence || "journals.json"

      UploadCreator.new(tempfile, filename, type: "json", for_private_message: false).create_for(
        Discourse.system_user.id,
      )
    end
  end
end
