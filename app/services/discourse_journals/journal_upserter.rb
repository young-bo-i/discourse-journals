# frozen_string_literal: true

module DiscourseJournals
  class JournalUpserter
    CUSTOM_FIELD_NAMES = %w[
      discourse_journals_issn_l
      discourse_journals_publisher
      discourse_journals_data
      discourse_journals_cover_url
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
          update_topic!(topic, journal_data, prepared)
          return :updated
        end
      end

      create_topic!(journal_data, prepared)
      :created
    end

    private

    attr_reader :system_user

    def create_topic!(journal_data, prepared)
      category = journal_category
      tags = build_tags(journal_data)

      creator =
        PostCreator.new(
          system_user,
          title: prepared[:title],
          raw: prepared[:raw_text],
          category: category.id,
          tags: tags,
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
      ensure_closed!(topic)
      topic
    end

    def update_topic!(topic, journal_data, prepared)
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
      update_tags!(topic, journal_data)
      ensure_closed!(topic)
      topic
    end

    def store_custom_fields!(topic, prepared)
      fields = {}
      fields["discourse_journals_issn_l"] = prepared[:issn_l].to_s if prepared[:issn_l].present?
      fields["discourse_journals_publisher"] = prepared[:publisher].to_s if prepared[:publisher].present?
      fields["discourse_journals_cover_url"] = prepared[:cover_url].to_s if prepared[:cover_url].present?

      if prepared[:normalized_json].present?
        fields["discourse_journals_data"] = prepared[:normalized_json]
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

    def update_tags!(topic, journal_data)
      return unless SiteSetting.tagging_enabled
      tags = build_tags(journal_data)
      return if tags.empty?
      DiscourseTagging.add_or_create_tags_by_name(topic, tags)
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
        normalized_json: normalized.to_json,
        issn_l: normalized.dig(:identity, :issn_l),
        publisher: normalized.dig(:publication, :publisher_name),
        cover_url: normalized.dig(:identity, :cover_url),
      }
    end

    def build_tags(journal_data)
      journal_data = journal_data.deep_symbolize_keys if journal_data.is_a?(Hash)
      tags = []

      jcr_data = journal_data.dig(:sources, :jcr, :all_years) || []
      jcr_data = [journal_data.dig(:sources, :jcr, :main)].compact if jcr_data.empty?
      latest_jcr = jcr_data.first
      if latest_jcr
        if (category = latest_jcr[:category]&.to_s)
          if (match = category.match(/\(([^)]+)\)\s*$/))
            tags << "jcr:#{match[1].strip}"
          end
          subject = category.gsub(/\([^)]*\)\s*$/, "").strip
          tags << "jcr:#{titleize_subject(subject)}" if subject.present?
        end
        tags << "jcr:#{latest_jcr[:if_quartile]}" if latest_jcr[:if_quartile]
      end

      fqb_data = journal_data.dig(:sources, :fqb, :all_years) || []
      fqb_data = [journal_data.dig(:sources, :fqb, :main)].compact if fqb_data.empty?
      latest_fqb = fqb_data.first
      if latest_fqb
        tags << "cas:#{latest_fqb[:web_of_science]}" if latest_fqb[:web_of_science].present?
        if (partition = latest_fqb[:major_quartile]&.to_s)
          if (pm = partition.match(/(\d+)/))
            tags << "cas:#{I18n.t("discourse_journals.render.cas_tag_suffix", num: pm[1])}"
          end
        end
        tags << "cas:#{latest_fqb[:major_category]}" if latest_fqb[:major_category].present?
      end

      tags.compact.reject(&:blank?).uniq
    end

    def titleize_subject(subject)
      return subject if subject.blank?
      return subject if subject.match?(/[\u4e00-\u9fa5]/)
      subject.split(/\s+/).map(&:capitalize).join(" ")
    end
  end
end
