# frozen_string_literal: true

module DiscourseJournals
  class JournalUpserter
    def initialize(system_user: Discourse.system_user)
      @system_user = system_user
      @category_cache = nil
    end

    def upsert!(journal, existing_topic_id: nil)
      journal = ensure_hash(journal).deep_symbolize_keys
      prepared = normalize_and_validate!(journal)

      if existing_topic_id
        topic = Topic.find_by(id: existing_topic_id)
        if topic
          update_topic!(topic, journal, prepared)
          return :updated
        end
      end

      create_topic!(journal, prepared)
      :created
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

    def create_topic!(journal, prepared)
      category = journal_category
      tags = build_tags(journal)

      creator =
        PostCreator.new(
          system_user,
          title: prepared[:title],
          raw: prepared[:raw],
          category: category.id,
          tags: tags,
          skip_validations: true,
          skip_jobs: true,
        )

      post = creator.create!
      topic = post.topic

      ensure_closed!(topic)
      topic
    end

    def update_topic!(topic, journal, prepared)
      first_post = topic.first_post
      if first_post
        if first_post.raw != prepared[:raw]
          first_post.update_columns(
            raw: prepared[:raw],
            cooked: PrettyText.cook(prepared[:raw]),
            baked_version: Post::BAKED_VERSION,
            updated_at: Time.current,
          )
          SearchIndexer.index(first_post) if first_post.topic_id
        end
      end

      topic.update_columns(title: prepared[:title], fancy_title: nil) if topic.title != prepared[:title]

      update_tags!(topic, journal)
      ensure_closed!(topic)
      topic
    end

    def ensure_closed!(topic)
      return unless SiteSetting.discourse_journals_close_topics
      return if topic.closed?
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

    def journal_category
      @category_cache ||= begin
        cid = SiteSetting.discourse_journals_category_id.to_i
        cat = Category.find_by(id: cid)
        raise Discourse::InvalidParameters.new(:discourse_journals_category_id) if cat.blank?
        cat
      end
    end

    def normalize_and_validate!(journal)
      normalizer = FieldNormalizer.new(journal)
      normalized_data = normalizer.normalize

      title = normalized_data.dig(:identity, :title_main)
      raise ArgumentError, "Missing title in normalized data" if title.blank?

      raw = MasterRecordRenderer.new(normalized_data).render
      raise ArgumentError, "Empty content generated" if raw.blank?

      { normalized: normalized_data, title: title, raw: raw }
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
  end
end
