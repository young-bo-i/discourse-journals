# frozen_string_literal: true

module Jobs
  module DiscourseJournals
    class ProcessJournalCovers < ::Jobs::Base
      sidekiq_options retry: 1, queue: "low"

      BATCH_SIZE = 20
      THROTTLE_SECONDS = 2
      REDIS_CONCURRENCY_KEY = "dj_cover_processing_count"
      MAX_GLOBAL_CONCURRENT = 2
      SLOT_WAIT_SECONDS = 5
      MAX_SLOT_WAIT_ATTEMPTS = 60

      def execute(args)
        topic_ids = args[:topic_ids]
        return if topic_ids.blank?
        return unless SiteSetting.discourse_journals_download_covers

        topic_ids.each_slice(BATCH_SIZE) do |batch_ids|
          batch_custom_fields = TopicCustomField
            .where(topic_id: batch_ids, name: %w[discourse_journals_cover_url discourse_journals_cover_url_hash discourse_journals_issn_l discourse_journals_country])
            .pluck(:topic_id, :name, :value)
            .group_by(&:first)
            .transform_values { |rows| rows.map { |_, n, v| [n, v] }.to_h }

          Topic.where(id: batch_ids).find_each do |topic|
            cf = batch_custom_fields[topic.id] || {}
            process_cover(topic, cf)
            sleep THROTTLE_SECONDS
          end
        end
      end

      private

      def acquire_global_slot
        attempts = 0
        loop do
          current = Discourse.redis.get(REDIS_CONCURRENCY_KEY).to_i
          if current < MAX_GLOBAL_CONCURRENT
            Discourse.redis.incr(REDIS_CONCURRENCY_KEY)
            Discourse.redis.expire(REDIS_CONCURRENCY_KEY, 600)
            return true
          end
          attempts += 1
          return false if attempts >= MAX_SLOT_WAIT_ATTEMPTS
          sleep SLOT_WAIT_SECONDS
        end
      end

      def release_global_slot
        val = Discourse.redis.decr(REDIS_CONCURRENCY_KEY)
        Discourse.redis.del(REDIS_CONCURRENCY_KEY) if val.to_i <= 0
      end

      def process_cover(topic, cf)
        cover_url = cf["discourse_journals_cover_url"]
        existing_hash = cf["discourse_journals_cover_url_hash"]

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

          return unless acquire_global_slot
          begin
            tempfile = ::DiscourseJournals::CoverImageGenerator.generate(
              title: topic.title,
              issn: cf["discourse_journals_issn_l"],
              country: cf["discourse_journals_country"],
            )
          ensure
            release_global_slot
          end
        end

        return if tempfile.nil?

        ext = tempfile.respond_to?(:path) && tempfile.path.end_with?(".png") ? "png" : "jpg"

        return unless acquire_global_slot
        begin
          upload =
            UploadCreator.new(tempfile, "journal_cover_#{topic.id}.#{ext}").create_for(
              Discourse.system_user.id,
            )
        ensure
          release_global_slot
        end

        if upload.persisted? && !upload.errors.any?
          topic.update_column(:image_upload_id, upload.id)
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
