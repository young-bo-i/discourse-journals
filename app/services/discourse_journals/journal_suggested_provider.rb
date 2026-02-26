# frozen_string_literal: true

module DiscourseJournals
  class JournalSuggestedProvider
    TAG_WEIGHT = 3
    PUBLISHER_WEIGHT = 2
    COUNTRY_WEIGHT = 1

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

      topic_ids = find_related_topic_ids(topic, category_id, criteria, limit)
      return nil if topic_ids.empty?

      { result: Topic.where(id: topic_ids).order(DB.sql_fragment("array_position(ARRAY[?], topics.id)", topic_ids)) }
    end

    def self.find_related_topic_ids(topic, category_id, criteria, limit)
      score_parts = []
      joins = []
      bind_values = { topic_id: topic.id, category_id: category_id, limit: limit }

      if criteria.include?("tags")
        joins << <<~SQL
          LEFT JOIN (
            SELECT tt_other.topic_id, COUNT(*) AS shared_tag_count
            FROM topic_tags tt_current
            JOIN topic_tags tt_other ON tt_other.tag_id = tt_current.tag_id
              AND tt_other.topic_id != :topic_id
            WHERE tt_current.topic_id = :topic_id
            GROUP BY tt_other.topic_id
          ) shared_tags ON shared_tags.topic_id = t.id
        SQL
        score_parts << "COALESCE(shared_tags.shared_tag_count, 0) * #{TAG_WEIGHT}"
      end

      if criteria.include?("publisher")
        publisher = TopicCustomField.where(
          topic_id: topic.id,
          name: "discourse_journals_publisher",
        ).pick(:value)

        if publisher.present?
          bind_values[:publisher] = publisher
          joins << <<~SQL
            LEFT JOIN topic_custom_fields tcf_pub
              ON tcf_pub.topic_id = t.id
              AND tcf_pub.name = 'discourse_journals_publisher'
              AND tcf_pub.value = :publisher
          SQL
          score_parts << "CASE WHEN tcf_pub.id IS NOT NULL THEN #{PUBLISHER_WEIGHT} ELSE 0 END"
        end
      end

      if criteria.include?("country")
        country = TopicCustomField.where(
          topic_id: topic.id,
          name: "discourse_journals_country",
        ).pick(:value)

        if country.present?
          bind_values[:country] = country
          joins << <<~SQL
            LEFT JOIN topic_custom_fields tcf_country
              ON tcf_country.topic_id = t.id
              AND tcf_country.name = 'discourse_journals_country'
              AND tcf_country.value = :country
          SQL
          score_parts << "CASE WHEN tcf_country.id IS NOT NULL THEN #{COUNTRY_WEIGHT} ELSE 0 END"
        end
      end

      return [] if score_parts.empty?

      score_expr = score_parts.join(" + ")

      sql = <<~SQL
        SELECT t.id
        FROM topics t
        #{joins.join("\n")}
        WHERE t.category_id = :category_id
          AND t.id != :topic_id
          AND t.deleted_at IS NULL
          AND t.visible = true
          AND t.archetype = 'regular'
          AND (#{score_expr}) > 0
        ORDER BY (#{score_expr}) DESC, t.bumped_at DESC
        LIMIT :limit
      SQL

      DB.query_single(sql, bind_values)
    end
  end
end
