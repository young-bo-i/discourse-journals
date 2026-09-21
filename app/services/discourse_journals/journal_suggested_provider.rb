# frozen_string_literal: true

module DiscourseJournals
  class JournalSuggestedProvider
    TAG_WEIGHT = 3
    PUBLISHER_WEIGHT = 2
    COUNTRY_WEIGHT = 1
    CACHE_TTL = 30.minutes
    MAX_TAG_TOPIC_COUNT = 10_000
    MAX_CUSTOM_FIELD_TOPIC_COUNT = 20_000
    MAX_SCORING_TAGS = 3
    INDEXED_CUSTOM_FIELD_VALUE_LENGTH = 400

    CUSTOM_FIELD_NAMES = {
      publisher: "discourse_journals_publisher",
      country: "discourse_journals_country",
    }.freeze

    def self.call(topic, _pm_params, _topic_query)
      return nil unless SiteSetting.discourse_journals_enabled

      mode = SiteSetting.discourse_journals_suggested_mode
      return nil if mode == "default"

      category_id = SiteSetting.discourse_journals_category_id.to_i
      return nil if category_id.zero?
      return nil unless topic.category_id == category_id

      criteria = SiteSetting.discourse_journals_suggested_criteria.to_s.split("|").map(&:strip)
      return nil if criteria.empty?

      limit = SiteSetting.discourse_journals_suggested_count

      cache_key = "dj_suggested_v2_#{topic.id}_#{limit}_#{criteria.sort.join("-")}"
      topic_ids =
        Discourse
          .cache
          .fetch(cache_key, expires_in: CACHE_TTL) do
            find_related_topic_ids(topic, category_id, criteria, limit)
          end

      return nil if topic_ids.blank?

      {
        result:
          Topic.where(id: topic_ids).order(
            DB.sql_fragment("array_position(ARRAY[?], topics.id)", topic_ids),
          ),
      }
    end

    def self.find_related_topic_ids(topic, category_id, criteria, limit)
      score_sources = []
      bind_values = { topic_id: topic.id, category_id: category_id, limit: limit }

      if criteria.include?("tags")
        tag_ids = scoring_tag_ids(topic.id, category_id)
        if tag_ids.present?
          bind_values[:tag_ids] = tag_ids
          score_sources << <<~SQL
            SELECT topic_id, COUNT(*) * #{TAG_WEIGHT} AS score
            FROM topic_tags
            WHERE tag_id IN (:tag_ids)
              AND topic_id != :topic_id
            GROUP BY topic_id
          SQL
        end
      end

      if criteria.include?("publisher")
        add_custom_field_score_source(
          score_sources,
          bind_values,
          topic.id,
          :publisher,
          PUBLISHER_WEIGHT,
        )
      end

      if criteria.include?("country")
        add_custom_field_score_source(
          score_sources,
          bind_values,
          topic.id,
          :country,
          COUNTRY_WEIGHT,
        )
      end

      return [] if score_sources.empty?

      sql = <<~SQL
        WITH score_entries AS (
          #{score_sources.join("\nUNION ALL\n")}
        ),
        candidate_scores AS (
          SELECT topic_id, SUM(score) AS score
          FROM score_entries
          GROUP BY topic_id
        )
        SELECT t.id
        FROM candidate_scores candidates
        JOIN topics t ON t.id = candidates.topic_id
        WHERE t.category_id = :category_id
          AND t.id != :topic_id
          AND t.deleted_at IS NULL
          AND t.visible = true
          AND t.archetype = 'regular'
        ORDER BY candidates.score DESC, t.bumped_at DESC
        LIMIT :limit
      SQL

      DB.query_single(sql, bind_values)
    end

    def self.scoring_tag_ids(topic_id, category_id)
      stats = CategoryTagStat.arel_table

      CategoryTagStat
        .joins("INNER JOIN topic_tags ON topic_tags.tag_id = category_tag_stats.tag_id")
        .where(category_id: category_id, topic_tags: { topic_id: topic_id })
        .where(topic_count: 2..MAX_TAG_TOPIC_COUNT)
        .order(stats[:topic_count].asc, stats[:tag_id].asc)
        .limit(MAX_SCORING_TAGS)
        .pluck(:tag_id)
    end

    def self.add_custom_field_score_source(score_sources, bind_values, topic_id, criterion, weight)
      field_name = CUSTOM_FIELD_NAMES.fetch(criterion)
      value = TopicCustomField.where(topic_id: topic_id, name: field_name).pick(:value)
      return if value.blank? || value.length >= INDEXED_CUSTOM_FIELD_VALUE_LENGTH

      matching_fields =
        TopicCustomField.where(name: field_name, value: value).where(
          "char_length(value) < ?",
          INDEXED_CUSTOM_FIELD_VALUE_LENGTH,
        )
      return if matching_fields.offset(MAX_CUSTOM_FIELD_TOPIC_COUNT).exists?

      field_name_key = :"#{criterion}_field_name"
      bind_values[field_name_key] = field_name
      bind_values[criterion] = value
      score_sources << <<~SQL
        SELECT topic_id, #{weight}::bigint AS score
        FROM topic_custom_fields
        WHERE name = :#{field_name_key}
          AND value = :#{criterion}
          AND char_length(value) < #{INDEXED_CUSTOM_FIELD_VALUE_LENGTH}
          AND topic_id != :topic_id
        GROUP BY topic_id
      SQL
    end

    private_class_method :find_related_topic_ids, :scoring_tag_ids, :add_custom_field_score_source
  end
end
