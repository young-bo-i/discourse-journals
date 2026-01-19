# frozen_string_literal: true

module DiscourseJournals
  class JournalUpserter
    def initialize(system_user: Discourse.system_user)
      @system_user = system_user
    end

    def upsert!(journal)
      journal = journal.deep_symbolize_keys
      topic = find_topic_by_issn(journal.fetch(:issn))

      if topic
        update_topic!(topic, journal)
        :updated
      else
        create_topic!(journal)
        :created
      end
    end

      private

      attr_reader :system_user

      def ensure_hash(data)
        return data if data.is_a?(Hash)
        
        if data.is_a?(String)
          begin
            return JSON.parse(data)
          rescue JSON::ParserError
            return {}
          end
        end
        
        {}
      end

    def find_topic_by_issn(issn)
      TopicCustomField
        .where(name: CUSTOM_FIELD_ISSN, value: issn)
        .limit(1)
        .pluck(:topic_id)
        .then { |ids| ids.first && Topic.find_by(id: ids.first) }
    end

    def create_topic!(journal)
      category_id = SiteSetting.discourse_journals_category_id.to_i
      category = Category.find_by(id: category_id)
      raise Discourse::InvalidParameters.new(:discourse_journals_category_id) if category.blank?

      creator =
        PostCreator.new(
          system_user,
          title: build_title(journal),
          raw: build_raw(journal),
          category: category.id,
          skip_validations: true,
        )

      post = creator.create!
      topic = post.topic

      update_custom_fields!(topic, journal)
      close_topic!(topic)
      topic
    end

    def update_topic!(topic, journal)
      first_post = topic.first_post
      revisor = PostRevisor.new(first_post, topic)
      revisor.revise!(
        system_user,
        { raw: build_raw(journal) },
        bypass_bump: SiteSetting.discourse_journals_bypass_bump,
        skip_validations: true,
      )

      topic.update!(title: build_title(journal)) if topic.title != build_title(journal)

      update_custom_fields!(topic, journal)
      close_topic!(topic)
      topic
    end

    def close_topic!(topic)
      return unless SiteSetting.discourse_journals_close_topics
      topic.update_status("closed", true, system_user)
    end

    def update_custom_fields!(topic, journal)
      topic.custom_fields[CUSTOM_FIELD_ISSN] = journal[:issn]
      topic.custom_fields[CUSTOM_FIELD_NAME] = journal[:name]
      topic.custom_fields[CUSTOM_FIELD_UNIFIED_INDEX] = journal[:unified_index].to_json
      topic.custom_fields[CUSTOM_FIELD_ALIASES] = journal[:aliases].to_json
      topic.custom_fields[CUSTOM_FIELD_CROSSREF] = journal.dig(:sources, :crossref).to_json
      topic.custom_fields[CUSTOM_FIELD_DOAJ] = journal.dig(:sources, :doaj).to_json
      topic.custom_fields[CUSTOM_FIELD_NLM] = journal.dig(:sources, :nlm).to_json
      topic.custom_fields[CUSTOM_FIELD_OPENALEX] = journal.dig(:sources, :openalex).to_json
      topic.custom_fields[CUSTOM_FIELD_WIKIDATA] = journal.dig(:sources, :wikidata).to_json
      topic.save_custom_fields(true)
    end

    def build_title(journal)
      # 使用归一化后的标题
      normalizer = FieldNormalizer.new(journal)
      normalized = normalizer.normalize
      
      title = normalized.dig(:identity, :title_main) || journal[:name] || journal["name"]
      issn = normalized.dig(:identity, :issn_l) || journal[:issn] || journal["issn"]
      
      "#{title} (#{issn})"
    rescue StandardError => e
      # 如果归一化失败，使用原始数据
      Rails.logger.warn("[DiscourseJournals] Failed to build title: #{e.message}")
      title = journal[:name] || journal["name"] || "Unknown"
      issn = journal[:issn] || journal["issn"] || "Unknown"
      "#{title} (#{issn})"
    end

    def build_raw(journal)
      # 使用归一化器和渲染器生成内容
      normalizer = FieldNormalizer.new(journal)
      normalized_data = normalizer.normalize

      renderer = MasterRecordRenderer.new(normalized_data)
      renderer.render
    rescue StandardError => e
      # 如果归一化失败，返回简单内容
      Rails.logger.warn("[DiscourseJournals] Failed to build content: #{e.message}\n#{e.backtrace.first(3).join("\n")}")
      title = journal[:name] || journal["name"] || "Unknown"
      issn = journal[:issn] || journal["issn"] || "Unknown"
      
      "# #{title}\n\n**ISSN**: #{issn}\n\n*数据归一化失败，已记录错误日志*"
    end
  end
end
