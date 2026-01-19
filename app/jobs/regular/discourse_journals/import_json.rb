# frozen_string_literal: true

module Jobs
  module DiscourseJournals
    class ImportJson < ::Jobs::Base
      def execute(args)
        upload_id = args[:upload_id]
        upload = Upload.find_by(id: upload_id)

        return if upload.blank?

        file_path = Discourse.store.path_for(upload)
        return if file_path.blank? || !File.exist?(file_path)

        importer = ::DiscourseJournals::JsonImport::Importer.new(file_path: file_path)
        importer.import!

        Rails.logger.info(
          "[DiscourseJournals] Import completed: #{importer.processed_rows} processed, " \
          "#{importer.created_topics} created, #{importer.updated_topics} updated, " \
          "#{importer.skipped_rows} skipped, #{importer.errors.size} errors"
        )

        if importer.errors.any?
          Rails.logger.warn("[DiscourseJournals] Import errors: #{importer.errors.join("; ")}")
        end
      rescue StandardError => e
        Rails.logger.error("[DiscourseJournals] Import job failed: #{e.message}\n#{e.backtrace.join("\n")}")
        raise e
      end
    end
  end
end
