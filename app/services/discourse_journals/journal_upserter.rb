# frozen_string_literal: true

module DiscourseJournals
  class JournalUpserter
    def initialize(system_user: Discourse.system_user)
      @system_user = system_user
    end

    def upsert!(journal)
      journal = ensure_hash(journal).deep_symbolize_keys
      
      # 验证必要字段 - 使用 primary_id 作为主标识符
      primary_id = journal[:primary_id] || journal[:issn] || journal.dig(:unified_index, :issn_l)
      raise ArgumentError, "Missing primary_id" if primary_id.blank?
      
      # 预先验证数据是否可以正常处理
      validate_journal_data!(journal)
      
      topic = find_topic_by_primary_id(primary_id)

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

    # 通过主标识符查找话题（兼容新旧字段名）
    def find_topic_by_primary_id(primary_id)
      # 优先查找新字段名
      topic_id = TopicCustomField
        .where(name: CUSTOM_FIELD_PRIMARY_ID, value: primary_id)
        .limit(1)
        .pluck(:topic_id)
        .first

      # 如果没找到，查找旧字段名（向后兼容）
      topic_id ||= TopicCustomField
        .where(name: CUSTOM_FIELD_ISSN, value: primary_id)
        .limit(1)
        .pluck(:topic_id)
        .first
      
      return nil unless topic_id
      
      # 查找话题，包括已删除的
      topic = Topic.with_deleted.find_by(id: topic_id)
      
      if topic.nil?
        # 话题已被永久删除，清理孤立的 custom field
        Rails.logger.warn("[DiscourseJournals] Cleaning orphaned custom field for ID: #{primary_id}")
        TopicCustomField.where(name: CUSTOM_FIELD_PRIMARY_ID, value: primary_id).delete_all
        TopicCustomField.where(name: CUSTOM_FIELD_ISSN, value: primary_id).delete_all
        return nil
      end
      
      # 如果话题被软删除
      if topic.deleted_at.present?
        if SiteSetting.discourse_journals_auto_recover_deleted
          # 自动恢复（默认行为）
          Rails.logger.info("[DiscourseJournals] Recovering deleted topic for ID: #{primary_id}")
          topic.recover!(system_user)
        else
          # 尊重删除决定，跳过该期刊
          Rails.logger.info("[DiscourseJournals] Skipping deleted topic for ID: #{primary_id}")
          return nil
        end
      end
      
      topic
    end

    def create_topic!(journal)
      category_id = SiteSetting.discourse_journals_category_id.to_i
      category = Category.find_by(id: category_id)
      raise Discourse::InvalidParameters.new(:discourse_journals_category_id) if category.blank?

      tags = build_tags(journal)

      creator =
        PostCreator.new(
          system_user,
          title: build_title(journal),
          raw: build_raw(journal),
          category: category.id,
          tags: tags,
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

      # 更新标签
      update_tags!(topic, journal)

      update_custom_fields!(topic, journal)
      close_topic!(topic)
      topic
    end

    def close_topic!(topic)
      return unless SiteSetting.discourse_journals_close_topics
      topic.update_status("closed", true, system_user)
    end

    def update_tags!(topic, journal)
      return unless SiteSetting.tagging_enabled
      
      tags = build_tags(journal)
      return if tags.empty?
      
      # 使用 DiscourseTagging 更新标签
      # add_or_create_tags_by_name 会自动创建不存在的标签
      DiscourseTagging.add_or_create_tags_by_name(topic, tags)
    end

    def update_custom_fields!(topic, journal)
      primary_id = journal[:primary_id] || journal[:issn]
      
      # 只保存唯一关联字段
      topic.custom_fields[CUSTOM_FIELD_PRIMARY_ID] = primary_id
      
      # 保留旧字段名用于向后兼容
      topic.custom_fields[CUSTOM_FIELD_ISSN] = primary_id
      
      topic.save_custom_fields(true)
    end

    def validate_journal_data!(journal)
      # 尝试归一化和渲染，如果失败会抛出异常
      normalizer = FieldNormalizer.new(journal)
      normalized_data = normalizer.normalize
      
      renderer = MasterRecordRenderer.new(normalized_data)
      renderer.render
      
      # 验证必要字段（只验证标题，不再强制要求 ISSN）
      title = normalized_data.dig(:identity, :title_main)
      raise ArgumentError, "Missing title in normalized data" if title.blank?
      
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

    def build_tags(journal)
      tags = []
      
      # JCR 标签（使用 jcr: 前缀区分）
      if jcr_data = journal.dig(:jcr, :data)
        jcr_data = jcr_data.map { |d| d.is_a?(Hash) ? d.deep_symbolize_keys : d }
        latest_jcr = jcr_data.first
        if latest_jcr
          # 从 category 提取索引类型和学科
          # 例如: "ONCOLOGY(SCIE)" -> 索引类型 "SCIE", 学科 "Oncology"
          if category = latest_jcr[:category]
            category = category.to_s
            # 提取括号内的索引类型: SCIE -> jcr:SCIE（保持大写）
            if match = category.match(/\(([^)]+)\)\s*$/)
              index_type = match[1].strip
              tags << "jcr:#{index_type}" if index_type.present?
            end
            # 提取学科名称（去掉括号部分）: ONCOLOGY -> jcr:Oncology（首字母大写）
            subject = category.gsub(/\([^)]*\)\s*$/, '').strip
            tags << "jcr:#{titleize_subject(subject)}" if subject.present?
          end
          # 分区: Q1 -> jcr:Q1（保持大写）
          if quartile = latest_jcr[:quartile]
            tags << "jcr:#{quartile}"
          end
        end
      end
      
      # 中科院标签（使用 cas: 前缀区分）
      if cas_data = journal.dig(:cas_partition, :data)
        cas_data = cas_data.map { |d| d.is_a?(Hash) ? d.deep_symbolize_keys : d }
        latest_cas = cas_data.first
        if latest_cas
          # WOS收录: SCIE -> cas:SCIE（保持大写）
          if wos = latest_cas[:web_of_science]
            tags << "cas:#{wos}"
          end
          # 分区: 提取数字 -> cas:1区
          if partition = latest_cas[:major_partition]
            partition_str = partition.to_s
            if partition_match = partition_str.match(/(\d+)/)
              tags << "cas:#{partition_match[1]}区"
            end
          end
          # 大类学科: 医学 -> cas:医学（中文保持原样）
          if major_category = latest_cas[:major_category]
            tags << "cas:#{major_category}"
          end
        end
      end
      
      # 去重并过滤空值
      tags.compact.reject(&:blank?).uniq
    end

    # 将学科名称转换为首字母大写格式
    # 例如: "ONCOLOGY" -> "Oncology", "CELL BIOLOGY" -> "Cell Biology"
    def titleize_subject(subject)
      return subject if subject.blank?
      
      # 如果包含中文，保持原样
      return subject if subject.match?(/[\u4e00-\u9fa5]/)
      
      # 英文学科名称：每个单词首字母大写
      subject.split(/\s+/).map(&:capitalize).join(' ')
    end
    
    def log_error(journal, error)
      primary_id = journal[:primary_id] || journal[:issn] || journal.dig(:unified_index, :issn_l) || "Unknown"
      name = journal[:name] || journal.dig(:unified_index, :title_main) || "Unknown"
      
      Rails.logger.error("[DiscourseJournals] Failed to upsert journal: #{name} (#{primary_id})")
      Rails.logger.error("[DiscourseJournals] Error: #{error.class} - #{error.message}")
      Rails.logger.error("[DiscourseJournals] Backtrace:\n#{error.backtrace.first(5).join("\n")}")
      
      # 如果有原始数据，也记录一部分
      if journal.present?
        Rails.logger.error("[DiscourseJournals] Journal data keys: #{journal.keys.inspect}")
      end
    end
  end
end
