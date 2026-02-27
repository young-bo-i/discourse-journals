# frozen_string_literal: true

module Jobs
  module DiscourseJournals
    class ProcessJournalCovers < ::Jobs::Base
      sidekiq_options retry: 1

      BATCH_SIZE = 50

      def execute(args)
        topic_ids = args[:topic_ids]
        return if topic_ids.blank?

        topic_ids.each_slice(BATCH_SIZE) do |batch_ids|
          Topic.where(id: batch_ids).find_each do |topic|
            process_cover(topic)
          end
        end
      end

      private

      def process_cover(topic)
        return unless SiteSetting.discourse_journals_download_covers

        cover_url = TopicCustomField.where(
          topic_id: topic.id,
          name: "discourse_journals_cover_url",
        ).pick(:value)

        existing_hash = TopicCustomField.where(
          topic_id: topic.id,
          name: "discourse_journals_cover_url_hash",
        ).pick(:value)

        tempfile = nil
        url_hash = nil

        if cover_url.present?
          full_url =
            if cover_url.start_with?("http")
              cover_url
            else
              "https://journal.scholay.com#{cover_url}"
            end
          url_hash = Digest::SHA1.hexdigest(full_url)
          return if existing_hash == url_hash

          tempfile =
            begin
              FileHelper.download(
                full_url,
                max_file_size: 5.megabytes,
                tmp_file_name: "journal_cover",
                follow_redirect: true,
              )
            rescue StandardError => e
              Rails.logger.warn(
                "[DiscourseJournals::ProcessCovers] Download failed for topic #{topic.id}: #{e.message}",
              )
              nil
            end
        end

        if tempfile.nil?
          generated_hash = Digest::SHA1.hexdigest("generated:#{topic.title}")
          return if existing_hash == generated_hash
          url_hash = generated_hash

          issn = TopicCustomField.where(
            topic_id: topic.id,
            name: "discourse_journals_issn_l",
          ).pick(:value)
          country = TopicCustomField.where(
            topic_id: topic.id,
            name: "discourse_journals_country",
          ).pick(:value)
          tempfile = ::DiscourseJournals::CoverImageGenerator.generate(
            title: topic.title,
            issn: issn,
            country: country,
          )
        end

        return if tempfile.nil?

        ext = tempfile.respond_to?(:path) && tempfile.path.end_with?(".png") ? "png" : "jpg"
        upload =
          UploadCreator.new(tempfile, "journal_cover_#{topic.id}.#{ext}").create_for(
            Discourse.system_user.id,
          )

        if upload.persisted? && !upload.errors.any?
          topic.update_column(:image_upload_id, upload.id)
          topic.generate_thumbnails! if topic.respond_to?(:generate_thumbnails!)
          TopicCustomField.where(
            topic_id: topic.id,
            name: "discourse_journals_cover_url_hash",
          ).delete_all
          TopicCustomField.create!(
            topic_id: topic.id,
            name: "discourse_journals_cover_url_hash",
            value: url_hash,
          )
        end
      rescue StandardError => e
        Rails.logger.warn(
          "[DiscourseJournals::ProcessCovers] Failed for topic #{topic.id}: #{e.message}",
        )
      ensure
        tempfile&.close! if tempfile.respond_to?(:close!)
      end
    end
  end
end
