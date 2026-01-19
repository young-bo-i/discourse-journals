# frozen_string_literal: true

module DiscourseJournals
  # 统一档案渲染服务：将归一化字段渲染为Markdown格式
  # 采用学术期刊风格，使用折叠分区组织内容
  class MasterRecordRenderer
    def initialize(normalized_data, tracker: nil)
      @data = normalized_data
      @tracker = tracker || FieldUsageTracker.new(normalized_data)
    end

    def render
      I18n.with_locale(SiteSetting.default_locale) do
        sections = []

        # 顶部摘要卡片（始终可见）
        sections << render_summary_card

        # 折叠分区
        sections << render_details_section(t("sections.identity"), render_identity_content, open: true)
        sections << render_details_section(t("sections.open_access"), render_open_access_content)
        sections << render_details_section(t("sections.metrics"), render_metrics_content)
        sections << render_details_section(t("sections.review_compliance"), render_review_content)
        sections << render_details_section(t("sections.preservation"), render_preservation_content)
        sections << render_details_section(t("sections.subjects_topics"), render_subjects_content)
        sections << render_details_section(t("sections.crossref_quality"), render_crossref_content)
        sections << render_details_section(t("sections.nlm_cataloging"), render_nlm_content)
        sections << render_details_section(t("sections.external_links"), render_external_links_content)

        # 记录未使用的字段
        @tracker.log_unused_fields

        sections.compact.join("\n\n")
      end
    end

    private

    attr_reader :data, :tracker

    def t(key)
      I18n.t("discourse_journals.master_record.#{key}")
    end

    def mark_used(*paths)
      paths.each { |path| @tracker.mark_used(path) }
    end

    def format_number(num)
      return "—" if num.nil?
      num.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse
    end

    def format_value(value, type = :default)
      return "—" if value.nil? || (value.respond_to?(:empty?) && value.empty?)

      case type
      when :boolean
        value ? "是" : "否"
      when :array
        value.is_a?(Array) ? value.join(", ") : value.to_s
      when :url
        value
      else
        value.to_s
      end
    end

    def render_details_section(title, content, open: false)
      return nil if content.blank?

      if open
        <<~MD
          [details="#{title}" open]
          #{content}
          [/details]
        MD
      else
        <<~MD
          [details="#{title}"]
          #{content}
          [/details]
        MD
      end
    end

    # ==================== 顶部摘要卡片 ====================
    def render_summary_card
      identity = @data[:identity] || {}
      publication = @data[:publication] || {}
      metrics = @data[:metrics] || {}
      oa = @data[:open_access] || {}
      review = @data[:review_compliance] || {}
      nlm = @data[:nlm_cataloging] || {}

      title = identity[:title_main] || "未知期刊"
      issn = identity[:issn_l] || "—"
      publisher = publication[:publisher_name] || "—"
      country = publication[:publisher_country]&.dig(:name) || publication[:publisher_country]&.dig(:code) || "—"

      mark_used("identity.title_main", "identity.issn_l", "publication.publisher_name", "publication.publisher_country")

      # 构建徽章
      badges = []
      if oa[:is_oa]
        badges << "🟢 **OA**"
        mark_used("open_access.is_oa")
      end
      if oa[:is_in_doaj]
        badges << "📘 **DOAJ**"
        mark_used("open_access.is_in_doaj")
      end
      if nlm[:current_indexing_status] == "Y"
        badges << "🏥 **NLM**"
        mark_used("nlm_cataloging.current_indexing_status")
      end
      if oa[:license_list]&.any?
        license_type = oa[:license_list].first
        license_name = license_type.is_a?(Hash) ? license_type[:type] : license_type.to_s
        badges << "🏷️ **#{license_name}**" if license_name.present?
        mark_used("open_access.license_list")
      end

      # 构建关键指标
      stats = []
      if metrics[:h_index]
        stats << "**h-index** #{metrics[:h_index]}"
        mark_used("metrics.h_index")
      end
      if metrics[:works_count]
        stats << "**论文** #{format_number(metrics[:works_count])}"
        mark_used("metrics.works_count")
      end
      if metrics[:cited_by_count]
        stats << "**被引** #{format_number(metrics[:cited_by_count])}"
        mark_used("metrics.cited_by_count")
      end
      if review[:publication_time_weeks]
        stats << "**审稿周期** #{review[:publication_time_weeks]}周"
        mark_used("review_compliance.publication_time_weeks")
      end

      badges_line = badges.any? ? badges.join(" · ") : ""
      stats_line = stats.any? ? stats.join(" · ") : ""

      out = +""
      out << "## #{title}\n\n"
      out << "**ISSN**: `#{issn}` · **出版商**: #{publisher} · **国家/地区**: #{country}\n\n"
      out << "#{badges_line}\n\n" if badges_line.present?
      out << "---\n\n"
      out << "#{stats_line}\n\n" if stats_line.present?
      out << "---\n\n" if stats_line.present?

      out
    end

    # ==================== 基本信息 ====================
    def render_identity_content
      identity = @data[:identity] || {}
      return nil unless identity.values.any?(&:present?)

      out = +""

      # 别名
      if identity[:title_alternate]&.any?
        out << "**别名**: #{identity[:title_alternate].join(", ")}\n\n"
        mark_used("identity.title_alternate")
      end

      # ISSN 列表
      if identity[:issn_list]&.any?
        out << "**ISSN 列表**: #{identity[:issn_list].join(", ")}\n\n"
        mark_used("identity.issn_list")
      end

      # ISSN 类型明细
      if identity[:issn_type_detail]&.any?
        out << "**ISSN 类型明细**:\n\n"
        out << "| ISSN | 类型 | 来源 |\n"
        out << "|------|------|------|\n"
        identity[:issn_type_detail].each do |detail|
          out << "| #{detail[:issn]} | #{detail[:type]} | #{detail[:source]} |\n"
        end
        out << "\n"
        mark_used("identity.issn_type_detail")
      end

      # 主页
      if identity[:homepage_url].present?
        out << "**期刊主页**: #{identity[:homepage_url]}\n\n"
        mark_used("identity.homepage_url")
      end

      # 官方网站集合
      if identity[:official_website_list]&.any?
        out << "**官方网站**:\n"
        identity[:official_website_list].each { |url| out << "- #{url}\n" }
        out << "\n"
        mark_used("identity.official_website_list")
      end

      # 外部 ID
      if identity[:external_ids]
        ids = identity[:external_ids]
        if ids.values.any?(&:present?)
          out << "**外部标识符**:\n"
          out << "- OpenAlex: `#{ids[:openalex_id]}`\n" if ids[:openalex_id]
          out << "- Wikidata: `#{ids[:wikidata_id]}`\n" if ids[:wikidata_id]
          out << "- NLM: `#{ids[:nlm_unique_id]}`\n" if ids[:nlm_unique_id]
          out << "- Crossref Status: `#{ids[:crossref_status]}`\n" if ids[:crossref_status]
          out << "\n"
          mark_used("identity.external_ids.openalex_id", "identity.external_ids.wikidata_id",
                    "identity.external_ids.nlm_unique_id", "identity.external_ids.crossref_status")
        end
      end

      out.presence
    end

    # ==================== 开放获取与费用 ====================
    def render_open_access_content
      oa = @data[:open_access] || {}
      return nil unless oa.values.any?(&:present?)

      out = +""

      # 基本 OA 状态
      fields = [
        [:doaj_since_year, "DOAJ 收录年份"],
        [:oa_start_year, "OA 起始年份"],
        [:author_retains_copyright, "作者保留版权", :boolean],
        [:copyright_url, "版权说明"],
      ]

      fields.each do |key, label, type|
        if oa[key].present?
          value = type == :boolean ? format_value(oa[key], :boolean) : oa[key]
          out << "- **#{label}**: #{value}\n"
          mark_used("open_access.#{key}")
        end
      end
      out << "\n" if out.present?

      # 许可证详情
      if oa[:license_list]&.any?
        out << "**许可证**:\n"
        oa[:license_list].each do |license|
          if license.is_a?(Hash)
            license_str = license[:type] || "Unknown"
            attrs = []
            attrs << "BY" if license[:BY]
            attrs << "NC" if license[:NC]
            attrs << "ND" if license[:ND]
            attrs << "SA" if license[:SA]
            license_str += " (#{attrs.join('-')})" if attrs.any?
            license_str += " - [链接](#{license[:url]})" if license[:url]
            out << "- #{license_str}\n"
          else
            out << "- #{license}\n"
          end
        end
        out << "\n"
      end

      if oa[:license_terms_url].present?
        out << "- **许可证条款**: #{oa[:license_terms_url]}\n"
        mark_used("open_access.license_terms_url")
      end

      # APC 信息
      out << "\n**文章处理费 (APC)**:\n\n" if oa[:has_apc].present? || oa[:apc_price].present?

      if oa[:has_apc].present?
        out << "- **收取 APC**: #{format_value(oa[:has_apc], :boolean)}\n"
        mark_used("open_access.has_apc")
      end

      if oa[:apc_price]
        apc = oa[:apc_price]
        if apc[:primary]
          primary = apc[:primary]
          out << "- **APC 价格**: #{primary[:price]} #{primary[:currency]} (来源: #{primary[:source]})\n"
        end
        if apc[:alternatives]&.any?
          apc[:alternatives].each do |alt|
            out << "- **参考价格**: #{alt[:price]} #{alt[:currency]} (来源: #{alt[:source]})\n"
          end
        end
        if apc[:usd_estimate]
          out << "- **美元估算**: $#{apc[:usd_estimate]} USD\n"
        end
        mark_used("open_access.apc_price")
      end

      if oa[:apc_url].present?
        out << "- **APC 说明页**: #{oa[:apc_url]}\n"
        mark_used("open_access.apc_url")
      end

      # 减免政策
      if oa[:has_waiver].present?
        out << "\n**减免政策**:\n"
        out << "- **有减免**: #{format_value(oa[:has_waiver], :boolean)}\n"
        mark_used("open_access.has_waiver")
        if oa[:waiver_url].present?
          out << "- **减免说明**: #{oa[:waiver_url]}\n"
          mark_used("open_access.waiver_url")
        end
      end

      # 其他费用
      if oa[:other_charges].present?
        charges = oa[:other_charges]
        if charges.is_a?(Hash)
          out << "\n**其他费用**:\n"
          out << "- **有其他费用**: #{format_value(charges[:has_other_charges], :boolean)}\n" if charges[:has_other_charges].present?
          out << "- **说明**: #{charges[:url]}\n" if charges[:url].present?
        end
        mark_used("open_access.other_charges")
      end

      out.presence
    end

    # ==================== 学术指标与产出 ====================
    def render_metrics_content
      metrics = @data[:metrics] || {}
      return nil unless metrics.values.any?(&:present?)

      out = +""

      # 基本指标（卡片式展示）
      basic_metrics = []
      if metrics[:works_count]
        basic_metrics << "| 论文总数 | #{format_number(metrics[:works_count])} |"
      end
      if metrics[:oa_works_count]
        basic_metrics << "| OA 论文数 | #{format_number(metrics[:oa_works_count])} |"
        mark_used("metrics.oa_works_count")
      end
      if metrics[:cited_by_count]
        basic_metrics << "| 被引总数 | #{format_number(metrics[:cited_by_count])} |"
      end
      if metrics[:two_year_mean_citedness]
        basic_metrics << "| 近2年平均被引 | #{metrics[:two_year_mean_citedness].round(3)} |"
        mark_used("metrics.two_year_mean_citedness")
      end
      if metrics[:h_index]
        basic_metrics << "| h-index | #{metrics[:h_index]} |"
      end
      if metrics[:i10_index]
        basic_metrics << "| i10-index | #{metrics[:i10_index]} |"
        mark_used("metrics.i10_index")
      end

      if basic_metrics.any?
        out << "| 指标 | 数值 |\n"
        out << "|------|------|\n"
        out << basic_metrics.join("\n") + "\n\n"
      end

      # 年度统计
      if metrics[:counts_by_year]&.any?
        out << "**年度产出与引用**:\n\n"
        out << "| 年份 | 论文数 | OA论文 | 被引数 |\n"
        out << "|------|--------|--------|--------|\n"
        metrics[:counts_by_year].first(8).each do |item|
          out << "| #{item[:year]} | #{format_number(item[:works_count])} | #{format_number(item[:oa_works_count])} | #{format_number(item[:cited_by_count])} |\n"
        end
        out << "\n"
        mark_used("metrics.counts_by_year")
      end

      # API 链接
      if metrics[:works_api_url].present?
        out << "**OpenAlex 作品 API**: #{metrics[:works_api_url]}\n"
        mark_used("metrics.works_api_url")
      end

      out.presence
    end

    # ==================== 审稿与编辑政策 ====================
    def render_review_content
      review = @data[:review_compliance] || {}
      return nil unless review.values.any?(&:present?)

      out = +""

      if review[:review_process]
        processes = review[:review_process]
        processes = [processes] unless processes.is_a?(Array)
        out << "**审稿方式**: #{processes.join(", ")}\n\n"
        mark_used("review_compliance.review_process")
      end

      links = [
        [:review_url, "审稿流程说明"],
        [:editorial_board_url, "编委会"],
        [:author_instructions_url, "投稿指南"],
        [:oa_statement_url, "OA 声明"],
        [:aims_scope_url, "期刊宗旨与范围"],
      ]

      links.each do |key, label|
        if review[key].present?
          out << "- **#{label}**: #{review[key]}\n"
          mark_used("review_compliance.#{key}")
        end
      end

      if review[:plagiarism_detection].present?
        out << "\n**反抄袭检测**: #{format_value(review[:plagiarism_detection], :boolean)}\n"
        mark_used("review_compliance.plagiarism_detection")
        if review[:plagiarism_url].present?
          out << "- **说明页**: #{review[:plagiarism_url]}\n"
          mark_used("review_compliance.plagiarism_url")
        end
      end

      out.presence
    end

    # ==================== 保存与索引 ====================
    def render_preservation_content
      pres = @data[:preservation] || {}
      return nil unless pres.values.any?(&:present?)

      out = +""

      if pres[:preservation_service]&.any?
        out << "**长期保存服务**: #{pres[:preservation_service].join(", ")}\n\n"
        mark_used("preservation.preservation_service")
      end

      if pres[:preservation_national_library]&.any?
        out << "**国家图书馆保存**: #{pres[:preservation_national_library].join(", ")}\n\n"
        mark_used("preservation.preservation_national_library")
      end

      if pres[:preservation_url].present?
        out << "- **保存说明**: #{pres[:preservation_url]}\n"
        mark_used("preservation.preservation_url")
      end

      if pres[:has_deposit_policy].present?
        out << "\n**存储政策**:\n"
        out << "- **有存储政策**: #{format_value(pres[:has_deposit_policy], :boolean)}\n"
        mark_used("preservation.has_deposit_policy")
      end

      if pres[:deposit_policy_service]&.any?
        out << "- **服务**: #{pres[:deposit_policy_service].join(", ")}\n"
        mark_used("preservation.deposit_policy_service")
      end

      if pres[:deposit_policy_url].present?
        out << "- **政策链接**: #{pres[:deposit_policy_url]}\n"
        mark_used("preservation.deposit_policy_url")
      end

      out.presence
    end

    # ==================== 学科与主题 ====================
    def render_subjects_content
      subjects = @data[:subjects_topics] || {}
      return nil unless subjects.values.any?(&:present?)

      out = +""

      # 学科分类
      if subjects[:subject_list]&.any?
        out << "**学科分类**:\n"
        subjects[:subject_list].each do |subj|
          if subj.is_a?(Hash)
            code = subj[:code] || subj["code"]
            term = subj[:term] || subj["term"]
            scheme = subj[:scheme] || subj["scheme"]
            out << "- #{term} (#{scheme}: #{code})\n"
          else
            out << "- #{subj}\n"
          end
        end
        out << "\n"
        mark_used("subjects_topics.subject_list")
      end

      # 关键词
      if subjects[:keywords]&.any?
        out << "**关键词**: #{subjects[:keywords].join(", ")}\n\n"
        mark_used("subjects_topics.keywords")
      end

      # OpenAlex 主题
      if subjects[:topics_top]&.any?
        out << "**OpenAlex 主题 (Top 5)**:\n\n"
        out << "| 主题 | 领域 | 子领域 |\n"
        out << "|------|------|--------|\n"
        subjects[:topics_top].first(5).each do |topic|
          name = topic[:display_name] || "—"
          field = topic.dig(:field, :display_name) || "—"
          subfield = topic.dig(:subfield, :display_name) || "—"
          out << "| #{name} | #{field} | #{subfield} |\n"
        end
        out << "\n"
        mark_used("subjects_topics.topics_top")
      end

      # 主题占比
      if subjects[:topic_share]&.any?
        out << "**主题占比**:\n"
        subjects[:topic_share].first(5).each do |share|
          if share.is_a?(Hash)
            name = share[:display_name] || share[:topic]&.dig(:display_name) || "Unknown"
            value = share[:value] || share[:share]
            out << "- #{name}: #{(value.to_f * 100).round(1)}%\n" if value
          end
        end
        out << "\n"
        mark_used("subjects_topics.topic_share")
      end

      out.presence
    end

    # ==================== Crossref 元数据质量 ====================
    def render_crossref_content
      quality = @data[:crossref_quality] || {}
      return nil unless quality.values.any?(&:present?)

      out = +""

      # DOI 统计
      if quality[:doi_counts]
        counts = quality[:doi_counts]
        out << "**DOI 统计**:\n"
        total = counts[:total_dois] || counts[:"total-dois"]
        current = counts[:current_dois] || counts[:"current-dois"]
        backfile = counts[:backfile_dois] || counts[:"backfile-dois"]
        out << "- 总 DOI 数: #{format_number(total)}\n" if total
        out << "- 当前 DOI: #{format_number(current)}\n" if current
        out << "- 存量 DOI: #{format_number(backfile)}\n" if backfile
        out << "\n"
        mark_used("crossref_quality.doi_counts")
      end

      # DOI 年份分布
      if quality[:dois_by_year]&.any?
        out << "**DOI 年份分布 (近10年)**:\n\n"
        out << "| 年份 | DOI 数量 |\n"
        out << "|------|----------|\n"
        quality[:dois_by_year].first(10).each do |item|
          if item.is_a?(Array)
            out << "| #{item[0]} | #{format_number(item[1])} |\n"
          elsif item.is_a?(Hash)
            out << "| #{item[:year]} | #{format_number(item[:count])} |\n"
          end
        end
        out << "\n"
        mark_used("crossref_quality.dois_by_year")
      end

      # 元数据覆盖率
      if quality[:metadata_coverage].present?
        coverage = quality[:metadata_coverage]
        if coverage.is_a?(Hash)
          out << "**元数据覆盖率**:\n"
          coverage.each do |field, rate|
            next if rate.nil?
            percentage = rate.is_a?(Numeric) ? (rate * 100).round(1) : rate
            out << "- #{field}: #{percentage}%\n"
          end
          out << "\n"
        end
        mark_used("crossref_quality.metadata_coverage")
      end

      # 覆盖类型
      if quality[:coverage_type].present?
        mark_used("crossref_quality.coverage_type")
        # 这个字段通常是复杂结构，简单提示存在
        out << "**覆盖类型详情**: 已收录（详细数据见 Crossref API）\n\n"
      end

      # 存在性标记
      if quality[:deposit_flags].present?
        flags = quality[:deposit_flags]
        if flags.is_a?(Hash)
          out << "**元数据提交标记**:\n"
          flags.each do |flag, value|
            status = value ? "✓" : "✗"
            out << "- #{flag}: #{status}\n"
          end
          out << "\n"
        end
        mark_used("crossref_quality.deposit_flags")
      end

      # Crossref 学科
      if quality[:crossref_subjects]&.any?
        out << "**Crossref 学科**: #{quality[:crossref_subjects].join(", ")}\n"
        mark_used("crossref_quality.crossref_subjects")
      end

      out.presence
    end

    # ==================== NLM 编目信息 ====================
    def render_nlm_content
      nlm = @data[:nlm_cataloging] || {}
      return nil unless nlm.values.any?(&:present?)

      out = +""

      fields = [
        [:title_sort, "标题排序键"],
        [:medline_ta, "MEDLINE 缩写"],
        [:nlm_date_revised, "NLM 修订日期"],
        [:continuation_notes, "连续说明"],
      ]

      fields.each do |key, label|
        if nlm[key].present?
          out << "- **#{label}**: #{nlm[key]}\n"
          mark_used("nlm_cataloging.#{key}")
        end
      end

      if nlm[:current_indexing_status].present?
        status = nlm[:current_indexing_status] == "Y" ? "是" : "否"
        out << "- **当前索引状态**: #{status}\n"
      end

      if nlm[:resource_type]&.any?
        types = nlm[:resource_type].map { |r| r.is_a?(Hash) ? r[:resourceunit] : r }.compact
        out << "- **资源类型**: #{types.join(", ")}\n" if types.any?
        mark_used("nlm_cataloging.resource_type")
      end

      if nlm[:broad_heading]&.any?
        out << "- **广泛主题词**: #{nlm[:broad_heading].join(", ")}\n"
        mark_used("nlm_cataloging.broad_heading")
      end

      out.presence
    end

    # ==================== 外部链接 ====================
    def render_external_links_content
      identity = @data[:identity] || {}
      publication = @data[:publication] || {}

      out = +""

      # 收集所有外部链接
      links = []

      if identity[:homepage_url].present?
        links << ["期刊主页", identity[:homepage_url]]
      end

      if identity[:external_ids]
        ids = identity[:external_ids]
        links << ["OpenAlex", ids[:openalex_id]] if ids[:openalex_id]&.start_with?("http")
        links << ["Wikidata", "https://www.wikidata.org/wiki/#{ids[:wikidata_id].split('/').last}"] if ids[:wikidata_id]
      end

      if identity[:official_website_list]&.any?
        identity[:official_website_list].each_with_index do |url, idx|
          links << ["官方网站 #{idx + 1}", url]
        end
      end

      return nil if links.empty?

      out << "| 名称 | 链接 |\n"
      out << "|------|------|\n"
      links.each do |name, url|
        out << "| #{name} | #{url} |\n"
      end

      out.presence
    end

    # ==================== 出版信息（合并到摘要卡片中，这里用于补充） ====================
    def render_publication_extra
      pub = @data[:publication] || {}

      out = +""

      if pub[:publication_place].present?
        out << "- **出版地**: #{pub[:publication_place]}\n"
        mark_used("publication.publication_place")
      end

      # 起始年份
      if pub[:start_year_cataloging] || pub[:start_year_statistical]
        out << "\n**出版起始年份**:\n"
        if pub[:start_year_cataloging]
          out << "- 编目记录: #{pub[:start_year_cataloging]}\n"
          mark_used("publication.start_year_cataloging")
        end
        if pub[:start_year_statistical] && pub[:start_year_statistical] != pub[:start_year_cataloging]
          out << "- 统计推断: #{pub[:start_year_statistical]}\n"
          mark_used("publication.start_year_statistical")
        end
      end

      if pub[:oa_start_year].present?
        out << "- **OA 起始年份**: #{pub[:oa_start_year]}\n"
        mark_used("publication.oa_start_year")
      end

      if pub[:end_year].present? && pub[:end_year] != "9999"
        out << "- **终止年份**: #{pub[:end_year]}\n"
        mark_used("publication.end_year")
      end

      if pub[:serial_publication_note].present?
        out << "- **连载说明**: #{pub[:serial_publication_note]}\n"
        mark_used("publication.serial_publication_note")
      end

      if pub[:language]&.any?
        out << "- **语言**: #{pub[:language].join(", ")}\n"
        mark_used("publication.language")
      end

      out.presence
    end
  end
end
