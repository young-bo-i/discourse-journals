# frozen_string_literal: true

module DiscourseJournals
  class JournalSeoContext
    attr_reader :topic, :topic_view

    def initialize(topic:, topic_view: nil, custom_fields: nil)
      @topic = topic
      @topic_view = topic_view
      @custom_fields = custom_fields
      @parsed_data_loaded = false
    end

    def custom_fields
      @custom_fields ||=
        TopicCustomField
          .where(topic_id: topic.id, name: DiscourseJournals::JOURNAL_SEO_FIELD_NAMES)
          .pluck(:name, :value)
          .to_h
    end

    def parsed_data
      return @parsed_data if @parsed_data_loaded

      @parsed_data_loaded = true
      @parsed_data =
        begin
          json_str = custom_fields["discourse_journals_data"]
          json_str.present? ? JSON.parse(json_str).deep_symbolize_keys : nil
        rescue StandardError => e
          Rails.logger.warn("[DiscourseJournals] Failed to parse SEO data for topic #{topic.id}: #{e.message}")
          nil
        end
    end

    def tag_names
      @tag_names ||= topic.tags.loaded? ? topic.tags.map(&:name) : topic.tags.pluck(:name)
    end

    def image_url
      @image_url ||= topic_view&.image_url
    end

    def replacements
      @replacements ||=
        {
          "title" => topic.title || "",
          "issn" => custom_fields["discourse_journals_issn_l"] || "",
          "publisher" => custom_fields["discourse_journals_publisher"] || "",
          "category" => topic.category&.name || "",
          "tags" => tag_names.join(", "),
          "site_name" => SiteSetting.title || "",
        }
    end

    def resolve_template(template)
      return "" if template.blank?

      result = template.gsub(/\{\{(\w+)\}\}/) { |_| replacements[$1] || "" }
      result.gsub(/,\s*,/, ",").gsub(/\s*-\s*-/, " -").strip.gsub(/^[,\s-]+|[,\s-]+$/, "").strip
    end
  end
end
