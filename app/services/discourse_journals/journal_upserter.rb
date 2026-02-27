# frozen_string_literal: true

module DiscourseJournals
  class JournalUpserter
    CUSTOM_FIELD_NAMES = %w[
      discourse_journals_issn_l
      discourse_journals_publisher
      discourse_journals_data
      discourse_journals_cover_url
      discourse_journals_country
    ].freeze

    def initialize(system_user: Discourse.system_user)
      @system_user = system_user
      @category_cache = nil
    end

    def upsert!(journal_data, existing_topic_id: nil)
      prepared = normalize_and_render!(journal_data)

      if existing_topic_id
        topic = Topic.find_by(id: existing_topic_id)
        if topic
          update_topic!(topic, prepared)
          return :updated
        end
      end

      existing = find_existing_topic(prepared)
      if existing
        update_topic!(existing, prepared)
        return :updated
      end

      create_topic!(prepared)
      :created
    end

    private

    attr_reader :system_user

    def create_topic!(prepared)
      category = journal_category

      creator =
        PostCreator.new(
          system_user,
          title: prepared[:title],
          raw: prepared[:raw_text],
          category: category.id,
          skip_validations: true,
          skip_jobs: true,
        )

      post = creator.create!
      topic = post.topic

      post.update_columns(
        cooked: prepared[:html],
        baked_version: Post::BAKED_VERSION,
      )

      store_custom_fields!(topic, prepared)
      JournalTagManager.apply_tags!(topic, prepared[:normalized])
      ensure_closed!(topic)
      update_topic_image!(topic, prepared[:cover_url])
      topic
    end

    def update_topic!(topic, prepared)
      first_post = topic.first_post
      if first_post
        first_post.update_columns(
          raw: prepared[:raw_text],
          cooked: prepared[:html],
          baked_version: Post::BAKED_VERSION,
          updated_at: Time.current,
        )
        SearchIndexer.index(first_post) if first_post.topic_id
      end

      topic.update_columns(title: prepared[:title], fancy_title: nil) if topic.title != prepared[:title]

      store_custom_fields!(topic, prepared)
      JournalTagManager.apply_tags!(topic, prepared[:normalized])
      ensure_closed!(topic)
      update_topic_image!(topic, prepared[:cover_url])
      topic
    end

    def store_custom_fields!(topic, prepared)
      fields = {}
      fields["discourse_journals_issn_l"] = prepared[:issn_l].to_s if prepared[:issn_l].present?
      fields["discourse_journals_publisher"] = prepared[:publisher].to_s if prepared[:publisher].present?
      fields["discourse_journals_cover_url"] = prepared[:cover_url].to_s if prepared[:cover_url].present?
      fields["discourse_journals_country"] = prepared[:country].to_s if prepared[:country].present?

      if prepared[:normalized].present?
        fields["discourse_journals_data"] = prepared[:normalized].to_json
      end

      return if fields.empty?

      TopicCustomField.where(topic_id: topic.id, name: CUSTOM_FIELD_NAMES).delete_all
      rows = fields.map do |name, value|
        { topic_id: topic.id, name: name, value: value, created_at: Time.current, updated_at: Time.current }
      end
      TopicCustomField.insert_all(rows)
    end

    def ensure_closed!(topic)
      return unless SiteSetting.discourse_journals_close_topics
      return if topic.closed?
      topic.update_status("closed", true, system_user)
    end

    def find_existing_topic(prepared)
      category = journal_category

      if prepared[:issn_l].present?
        topic_id = TopicCustomField
          .joins("INNER JOIN topics ON topics.id = topic_custom_fields.topic_id")
          .where(name: "discourse_journals_issn_l", value: prepared[:issn_l].to_s)
          .where(topics: { category_id: category.id, deleted_at: nil })
          .pick(:topic_id)
        return Topic.find_by(id: topic_id) if topic_id
      end

      if prepared[:title].present?
        normalized = TitleMatcher.normalize(prepared[:title])
        return nil if normalized.blank?
        Topic
          .where(category_id: category.id, deleted_at: nil)
          .find_by("LOWER(title) = ?", normalized)
      end
    end

    def journal_category
      @category_cache ||= begin
        cid = SiteSetting.discourse_journals_category_id.to_i
        cat = Category.find_by(id: cid)
        raise Discourse::InvalidParameters.new(:discourse_journals_category_id) if cat.blank?
        cat
      end
    end

    def normalize_and_render!(journal_data)
      normalizer = FieldNormalizer.new(journal_data)
      normalized = normalizer.normalize

      title = normalized.dig(:identity, :title)
      raise ArgumentError, "Missing title in normalized data" if title.blank?

      renderer = MasterRecordRenderer.new(normalized)
      html = renderer.render
      raw_text = renderer.render_plain_text
      raise ArgumentError, "Empty content generated" if html.blank?

      {
        title: title,
        html: html,
        raw_text: raw_text,
        normalized: normalized,
        issn_l: normalized.dig(:identity, :issn_l),
        publisher: normalized.dig(:publication, :publisher_name),
        cover_url: normalized.dig(:identity, :cover_url),
        country: normalized.dig(:publication, :country_name) || normalized.dig(:publication, :country_code),
      }
    end

    def update_topic_image!(topic, cover_url)
      return unless SiteSetting.discourse_journals_download_covers

      existing_hash =
        TopicCustomField.where(
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
              "[DiscourseJournals] Cover download failed for topic #{topic.id}: #{e.message}",
            )
            nil
          end
      end

      if tempfile.nil?
        generated_hash = Digest::SHA1.hexdigest("generated:#{topic.title}")
        return if existing_hash == generated_hash
        url_hash = generated_hash

        issn =
          TopicCustomField.where(
            topic_id: topic.id,
            name: "discourse_journals_issn_l",
          ).pick(:value)
        country =
          TopicCustomField.where(
            topic_id: topic.id,
            name: "discourse_journals_country",
          ).pick(:value)
        tempfile = CoverImageGenerator.generate(title: topic.title, issn: issn, country: country)
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
        "[DiscourseJournals] Failed to set cover for topic #{topic.id}: #{e.message}",
      )
    ensure
      tempfile&.close! if tempfile.respond_to?(:close!)
    end

  end
end
