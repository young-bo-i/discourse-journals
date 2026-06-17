# frozen_string_literal: true

module DiscourseJournals
  class JournalUpserter
    CUSTOM_FIELD_NAMES = %w[
      discourse_journals_issn_l
      discourse_journals_publisher
      discourse_journals_data
      discourse_journals_cover_url
      discourse_journals_country
      discourse_journals_normalized_title_key
      discourse_journals_api_id
    ].freeze

    attr_reader :last_topic_id

    def initialize(system_user: Discourse.system_user, defer_images: false, category: nil)
      @system_user = system_user
      @category_cache = category
      @defer_images = defer_images
      @last_topic_id = nil
    end

    def normalize_and_render(journal_data)
      normalize_and_render!(journal_data)
    end

    def upsert!(journal_data, existing_topic_id: nil)
      prepared = normalize_and_render!(journal_data)
      upsert_prepared!(prepared, existing_topic_id: existing_topic_id)
    end

    def upsert_prepared!(prepared, existing_topic_id: nil)
      if existing_topic_id
        topic = Topic.find_by(id: existing_topic_id)
        if topic
          update_topic!(topic, prepared)
          @last_topic_id = topic.id
          return :updated
        end
      end

      existing = find_existing_topic(prepared)
      if existing
        update_topic!(existing, prepared)
        @last_topic_id = existing.id
        return :updated
      end

      topic = create_topic!(prepared)
      @last_topic_id = topic.id
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

      unless @defer_images
        process_topic_cover!(topic, prepared)
      end

      topic
    end

    def update_topic!(topic, prepared)
      # Only treat this as a real update when the journal data (or title) actually
      # changed. cooked/raw are still rewritten unconditionally so renderer/template
      # changes propagate on re-sync, but updated_at (and therefore the sitemap
      # <lastmod>) and the search reindex only fire on genuine changes — avoiding
      # SEO churn from no-op syncs. Bump is never touched (no forum bump).
      content_changed = journal_content_changed?(topic, prepared)

      first_post = topic.first_post
      if first_post
        post_attrs = {
          raw: prepared[:raw_text],
          cooked: prepared[:html],
          baked_version: Post::BAKED_VERSION,
        }
        post_attrs[:updated_at] = Time.current if content_changed
        first_post.update_columns(post_attrs)
      end

      attrs = {}
      attrs[:updated_at] = Time.current if content_changed
      if topic.title != prepared[:title]
        attrs[:title] = prepared[:title]
        attrs[:fancy_title] = nil
      end
      topic.update_columns(attrs) if attrs.present?

      if content_changed
        PerformanceLogger.measure("sync.search_reindex", topic_id: topic.id) do
          SearchIndexer.queue_post_reindex(topic.id)
        end
      end

      store_custom_fields!(topic, prepared)
      JournalTagManager.apply_tags!(topic, prepared[:normalized])
      ensure_closed!(topic)

      unless @defer_images
        process_topic_cover!(topic, prepared)
      end

      topic
    end

    def journal_content_changed?(topic, prepared)
      return true if topic.title != prepared[:title]

      new_json = prepared[:normalized_json].to_s
      return true if new_json.blank?

      stored = TopicCustomField.where(topic_id: topic.id, name: "discourse_journals_data").pick(:value)
      return true if stored.blank?

      Digest::MD5.hexdigest(new_json) != Digest::MD5.hexdigest(stored)
    end

    def store_custom_fields!(topic, prepared)
      PerformanceLogger.measure("sync.custom_fields", topic_id: topic.id) do
        desired = {}
        desired["discourse_journals_issn_l"] = prepared[:issn_l].to_s if prepared[:issn_l].present?
        desired["discourse_journals_publisher"] = prepared[:publisher].to_s if prepared[:publisher].present?
        normalized_cover_url = TopicCoverManager.normalize_cover_url(prepared[:cover_url])
        desired["discourse_journals_cover_url"] = normalized_cover_url if normalized_cover_url.present?
        desired["discourse_journals_country"] = prepared[:country].to_s if prepared[:country].present?
        desired["discourse_journals_data"] = prepared[:normalized_json] if prepared[:normalized_json].present?
        desired["discourse_journals_normalized_title_key"] = prepared[:normalized_title_key] if prepared[:normalized_title_key].present?
        desired["discourse_journals_api_id"] = prepared[:api_id].to_s if prepared[:api_id].present?

        existing = TopicCustomField
          .where(topic_id: topic.id, name: CUSTOM_FIELD_NAMES)
          .pluck(:name, :value)
          .to_h

        changed_names =
          CUSTOM_FIELD_NAMES.select do |name|
            old = existing[name]
            value = desired[name]

            if value.nil?
              old.present?
            elsif name == "discourse_journals_data" && old.present?
              Digest::MD5.hexdigest(value) != Digest::MD5.hexdigest(old)
            else
              old != value
            end
          end

        next if changed_names.empty?

        TopicCustomField.where(topic_id: topic.id, name: changed_names).delete_all
        rows = changed_names.filter_map do |name|
          value = desired[name]
          next if value.nil?

          {
            topic_id: topic.id,
            name: name,
            value: value,
            created_at: Time.current,
            updated_at: Time.current,
          }
        end
        TopicCustomField.insert_all(rows) if rows.present?
      end
    end

    def ensure_closed!(topic)
      return unless SiteSetting.discourse_journals_close_topics
      return if topic.closed?
      topic.update_column(:closed, true)
    end

    def find_existing_topic(prepared)
      category = journal_category

      PerformanceLogger.measure("sync.lookup_existing_topic", source_type: "journal_upserter") do
        find_existing_topic_by_issn(prepared[:issn_l], category) ||
          find_existing_topic_by_title(prepared[:title], prepared[:normalized_title_key], category)
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

    def find_existing_topic_by_issn(issn_l, category)
      return if issn_l.blank?

      topic_id =
        PerformanceLogger.measure("sync.lookup_by_issn", source_type: "issn") do
          TopicCustomField
            .joins("INNER JOIN topics ON topics.id = topic_custom_fields.topic_id")
            .where(name: "discourse_journals_issn_l", value: issn_l.to_s)
            .where(topics: { category_id: category.id, deleted_at: nil })
            .pick(:topic_id)
        end

      Topic.find_by(id: topic_id) if topic_id
    end

    def find_existing_topic_by_title(title, normalized_title_key, category)
      raw_title = title.to_s.strip
      return if raw_title.blank?

      scope = Topic.where(category_id: category.id, deleted_at: nil)

      if normalized_title_key.present?
        normalized_match_ids =
          PerformanceLogger.measure("sync.lookup_by_title_key", source_type: "normalized_title_key") do
            TopicCustomField
              .joins("INNER JOIN topics ON topics.id = topic_custom_fields.topic_id")
              .where(name: "discourse_journals_normalized_title_key", value: normalized_title_key)
              .where(topics: { category_id: category.id, deleted_at: nil })
              .order("topics.id ASC")
              .limit(2)
              .pluck(:topic_id)
          end

        if normalized_match_ids.one?
          return Topic.find_by(id: normalized_match_ids.first)
        end

        if normalized_match_ids.many?
          Rails.logger.warn(
            "[DiscourseJournals] Ambiguous normalized title key match for #{raw_title.inspect} " \
              "in category #{category.id}",
          )
          return nil
        end
      end

      exact_match =
        PerformanceLogger.measure("sync.lookup_by_exact_title", source_type: "exact_title") do
          scope.find_by("LOWER(title) = ?", raw_title.downcase)
        end
      return exact_match if exact_match

      return if normalized_title_key.blank?

      compatibility_match_ids =
        PerformanceLogger.measure("sync.lookup_by_title_compat", source_type: "compatibility_title") do
          scope
            .where("regexp_replace(lower(title), '[^[:alnum:]]+', '', 'g') = ?", normalized_title_key)
            .order(:id)
            .limit(2)
            .pluck(:id)
        end

      if compatibility_match_ids.one?
        return Topic.find_by(id: compatibility_match_ids.first)
      end

      if compatibility_match_ids.many?
        Rails.logger.warn(
          "[DiscourseJournals] Ambiguous compatibility title match for #{raw_title.inspect} " \
            "in category #{category.id}",
        )
      end
    end

    def normalize_and_render!(journal_data)
      normalizer = FieldNormalizer.new(journal_data)
      normalized = normalizer.normalize

      title = normalized.dig(:identity, :title)
      raise ArgumentError, "Missing title in normalized data" if title.blank?
      normalized_title_key = TitleMatcher.normalized_title_key(title)
      normalized_json = normalized.to_json

      html = nil
      raw_text = nil
      I18n.with_locale(SiteSetting.default_locale) do
        renderer = MasterRecordRenderer.new(normalized)
        html = renderer.render
        raw_text = renderer.render_plain_text
      end
      raise ArgumentError, "Empty content generated" if html.blank?

      {
        api_id: normalized.dig(:unified, :id),
        title: title,
        html: html,
        raw_text: raw_text,
        normalized: normalized,
        normalized_json: normalized_json,
        normalized_title_key: normalized_title_key,
        issn_l: normalized.dig(:identity, :issn_l),
        publisher: normalized.dig(:publication, :publisher_name),
        cover_url: normalized.dig(:identity, :cover_url),
        country: normalized.dig(:publication, :country_name) || normalized.dig(:publication, :country_code),
      }
    end

    def process_topic_cover!(topic, prepared)
      PerformanceLogger.measure("sync.topic_cover", topic_id: topic.id) do
        TopicCoverManager.process!(
          topic: topic,
          cover_url: prepared[:cover_url],
          issn: prepared[:issn_l],
          country: prepared[:country],
          publisher: prepared[:publisher],
        )
      end
    end

  end
end
