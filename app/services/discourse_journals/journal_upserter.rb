# frozen_string_literal: true

module DiscourseJournals
  class JournalUpserter
    def initialize(system_user: Discourse.system_user)
      @system_user = system_user
    end

    def upsert!(journal)
      journal = ensure_hash(journal).deep_symbolize_keys
      
      # 验证必要字段
      issn = journal[:issn] || journal.dig(:unified_index, :issn_l)
      raise ArgumentError, "Missing ISSN" if issn.blank?
      
      # 预先验证数据是否可以正常处理
      validate_journal_data!(journal)
      
      topic = find_topic_by_issn(issn)

      if topic
        update_topic!(topic, journal)
        :updated
      else
        create_topic!(journal)
        :created
      end
    rescue StandardError => e
      # 记录详细错误日志
      log_error(journal, e)
      # 重新抛出异常，让调用者知道失败了
      raise
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
      topic_id = TopicCustomField
        .where(name: CUSTOM_FIELD_ISSN, value: issn)
        .limit(1)
        .pluck(:topic_id)
        .first
      
      return nil unless topic_id
      
      # 查找话题，包括已删除的
      topic = Topic.with_deleted.find_by(id: topic_id)
      
      if topic.nil?
        # 话题已被永久删除，清理孤立的 custom field
        Rails.logger.warn("[DiscourseJournals] Cleaning orphaned custom field for ISSN: #{issn}")
        TopicCustomField.where(name: CUSTOM_FIELD_ISSN, value: issn).delete_all
        return nil
      end
      
      # 如果话题被软删除
      if topic.deleted_at.present?
        if SiteSetting.discourse_journals_auto_recover_deleted
          # 自动恢复（默认行为）
          Rails.logger.info("[DiscourseJournals] Recovering deleted topic for ISSN: #{issn}")
          topic.recover!(system_user)
        else
          # 尊重删除决定，跳过该期刊
          Rails.logger.info("[DiscourseJournals] Skipping deleted topic for ISSN: #{issn}")
          return nil
        end
      end
      
      topic
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

    def validate_journal_data!(journal)
      # 尝试归一化和渲染，如果失败会抛出异常
      normalizer = FieldNormalizer.new(journal)
      normalized_data = normalizer.normalize
      
      renderer = MasterRecordRenderer.new(normalized_data)
      renderer.render
      
      # 验证必要字段
      title = normalized_data.dig(:identity, :title_main)
      issn = normalized_data.dig(:identity, :issn_l)
      
      raise ArgumentError, "Missing title in normalized data" if title.blank?
      raise ArgumentError, "Missing ISSN in normalized data" if issn.blank?
      
      true
    end

    def build_title(journal)
      # 只使用期刊名称作为标题
      normalizer = FieldNormalizer.new(journal)
      normalized = normalizer.normalize
      
      title = normalized.dig(:identity, :title_main)
      
      raise ArgumentError, "Missing title" if title.blank?
      
      title
    end

    def build_raw(journal)
      # 使用归一化器和渲染器生成内容，不捕获异常
      normalizer = FieldNormalizer.new(journal)
      normalized_data = normalizer.normalize

      renderer = MasterRecordRenderer.new(normalized_data)
      content = renderer.render
      
      raise ArgumentError, "Empty content generated" if content.blank?
      
      content
    end
    
    def log_error(journal, error)
      issn = journal[:issn] || journal.dig(:unified_index, :issn_l) || "Unknown"
      name = journal[:name] || journal.dig(:unified_index, :title_main) || "Unknown"
      
      Rails.logger.error("[DiscourseJournals] Failed to upsert journal: #{name} (#{issn})")
      Rails.logger.error("[DiscourseJournals] Error: #{error.class} - #{error.message}")
      Rails.logger.error("[DiscourseJournals] Backtrace:\n#{error.backtrace.first(5).join("\n")}")
      
      # 如果有原始数据，也记录一部分
      if journal.present?
        Rails.logger.error("[DiscourseJournals] Journal data keys: #{journal.keys.inspect}")
      end
    end
  end
end
