# frozen_string_literal: true

module DiscourseJournals
  # 统一档案渲染服务：将归一化字段渲染为Markdown格式
  # 采用学术期刊风格，简洁清晰的布局
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
        sections << render_details_section(t("sections.jcr"), render_jcr_content)
        sections << render_details_section(t("sections.cas_partition"), render_cas_content)
        sections << render_details_section(t("sections.metrics"), render_metrics_content)
        sections << render_details_section(t("sections.review_compliance"), render_review_content)
        sections << render_details_section(t("sections.subjects_topics"), render_subjects_content)
        sections << render_details_section(t("sections.open_access"), render_open_access_content)
        sections << render_details_section(t("sections.preservation"), render_preservation_content)
        sections << render_details_section(t("sections.crossref_quality"), render_crossref_content)
        sections << render_details_section(t("sections.nlm_cataloging"), render_nlm_content)

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

    # 生成超链接
    def link(text, url)
      return text if url.blank?
      "[#{text}](#{url})"
    end

    def render_details_section(title, content, open: false)
      return nil if content.blank?

      # 使用 Markdown 标题，支持右侧时间线索引跳转
      # 标题下方使用 details 保持折叠功能
      if open
        <<~MD
          ## #{title}

          [details="查看详情" open]
          #{content}
          [/details]
        MD
      else
        <<~MD
          ## #{title}

          [details="查看详情"]
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
      jcr = @data[:jcr] || {}
      cas = @data[:cas_partition] || {}

      title = identity[:title_main] || "未知期刊"
      issn = identity[:issn_l] || "—"
      publisher = publication[:publisher_name] || "—"
      country = publication[:publisher_country]&.dig(:name) || publication[:publisher_country]&.dig(:code) || "—"
      homepage = identity[:homepage_url]

      mark_used("identity.title_main", "identity.issn_l", "identity.homepage_url",
                "publication.publisher_name", "publication.publisher_country")

      # 标题（带官网链接）
      title_line = homepage.present? ? "[#{title}](#{homepage})" : title

      # 别名
      aliases_line = ""
      if identity[:title_alternate]&.any?
        aliases_line = "*#{identity[:title_alternate].join(" / ")}*\n\n"
        mark_used("identity.title_alternate")
      end

      jcr_latest = jcr[:data]&.first
      cas_latest = cas[:data]&.first

      # 提取中科院分区数字
      cas_partition_num = nil
      if cas_latest && cas_latest[:major_partition]
        partition_str = cas_latest[:major_partition].to_s
        if match = partition_str.match(/(\d+)/)
          cas_partition_num = match[1]
        end
      end

      out = +""
      out << "## #{title_line}\n\n"
      out << aliases_line

      # 基本信息表格
      out << "| | |\n"
      out << "|:--|:--|\n"
      out << "| **ISSN** | `#{issn}` |\n"
      out << "| **出版商** | #{publisher} |\n"
      out << "| **国家** | #{country} |\n"
      
      # JCR 信息
      if jcr_latest
        if jcr_latest[:impact_factor]
          out << "| **影响因子** | #{jcr_latest[:impact_factor]} (#{jcr_latest[:year] || '—'}) |\n"
        end
        if jcr_latest[:quartile]
          out << "| **JCR 分区** | #{jcr_latest[:quartile]} |\n"
        end
      end
      
      # 中科院分区信息
      if cas_latest
        cas_info = []
        cas_info << "#{cas_partition_num}区" if cas_partition_num
        cas_info << "Top" if cas_latest[:is_top_journal]
        cas_info << cas_latest[:major_category] if cas_latest[:major_category]
        if cas_info.any?
          out << "| **中科院分区** | #{cas_info.join(" · ")} |\n"
        end
      end
      
      out << "\n"

      # 构建标签式徽章
      badges = []
      badges << "`OA`" if oa[:is_oa]
      badges << "`NLM`" if nlm[:current_indexing_status] == "Y"
      badges << "`DOAJ`" if oa[:is_in_doaj]
      
      mark_used("open_access.is_oa", "open_access.is_in_doaj", "nlm_cataloging.current_indexing_status")
      
      if badges.any?
        out << badges.join(" ") + "\n\n"
      end

      out << "---\n\n"

      # 学术指标（单行展示）
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

      if stats.any?
        out << stats.join(" · ") + "\n\n"
      end

      out
    end

    # ==================== JCR 影响因子 ====================
    def render_jcr_content
      jcr = @data[:jcr]
      return nil if jcr.nil? || jcr[:data].nil? || jcr[:data].empty?

      out = +""
      data = jcr[:data]

      # 最新年份摘要（一行展示）
      latest = data.first
      if latest
        summary = []
        summary << "**IF #{latest[:impact_factor]}**" if latest[:impact_factor]
        summary << "#{latest[:quartile]}" if latest[:quartile]
        summary << "#{latest[:rank]}" if latest[:rank]
        summary << "#{latest[:category]}" if latest[:category]
        out << "#{latest[:year]}年: #{summary.join(" · ")}\n\n" if summary.any?
      end

      # 历年影响因子柱状图（所有年份，年份大的在上）
      out << render_jcr_chart(data)

      mark_used("jcr.total_years", "jcr.data")
      out.presence
    end

    def render_jcr_chart(data)
      return "" if data.empty?

      # 保持年份降序（大的在上面）
      chart_data = data
      max_if = chart_data.map { |d| d[:impact_factor].to_f }.max
      max_if = 1 if max_if.zero?

      out = +"**历年影响因子**\n\n"
      out << "```\n"
      
      chart_data.each do |item|
        year = item[:year].to_s
        impact = item[:impact_factor].to_f
        quartile = item[:quartile] || ""
        bar_length = (impact / max_if * 20).round
        bar = "█" * bar_length
        out << "#{year} │#{bar} #{impact} #{quartile}\n"
      end
      
      out << "```\n"
      out
    end

    # ==================== 中科院分区 ====================
    def render_cas_content
      cas = @data[:cas_partition]
      return nil if cas.nil? || cas[:data].nil? || cas[:data].empty?

      out = +""
      data = cas[:data]

      # 最新年份摘要（一行展示）
      latest = data.first
      if latest
        summary = []
        summary << "**#{latest[:major_category]}#{latest[:major_partition]}区**" if latest[:major_partition]
        summary << "Top期刊" if latest[:is_top_journal]
        summary << latest[:web_of_science] if latest[:web_of_science]
        out << "#{latest[:year]}年: #{summary.join(" · ")}\n\n" if summary.any?

        # 小类分区
        if latest[:minor_categories]&.any?
          out << "**小类分区**: "
          minor_items = latest[:minor_categories].map do |cat|
            cat.is_a?(Hash) ? "#{cat[:category]} #{cat[:partition]}" : nil
          end.compact
          out << minor_items.join(" · ") + "\n\n"
        end
      end

      # 历年分区柱状图（所有年份，年份大的在上）
      out << render_cas_chart(data)

      mark_used("cas_partition.total_years", "cas_partition.data")
      out.presence
    end

    def render_cas_chart(data)
      return "" if data.empty?

      out = +"**历年分区**\n\n"
      out << "```\n"
      
      data.each do |item|
        year = item[:year].to_s
        partition = item[:major_partition] || "—"
        top_mark = item[:is_top_journal] ? " ★" : ""
        # 用分区数值画柱状图（1区最长，4区最短）
        bar_length = case partition.to_s
                     when "1" then 20
                     when "2" then 15
                     when "3" then 10
                     when "4" then 5
                     else 0
                     end
        bar = "█" * bar_length
        out << "#{year} │#{bar} #{partition}区#{top_mark}\n"
      end
      
      out << "```\n"
      out << "*★ 表示 Top 期刊*\n" if data.any? { |d| d[:is_top_journal] }
      out
    end

    # ==================== 开放获取与费用 ====================
    def render_open_access_content
      oa = @data[:open_access] || {}
      return nil unless oa.values.any?(&:present?)

      out = +""

      # 基本状态表格
      status_rows = []
      
      if oa[:is_oa].present?
        status_rows << "| 开放获取 | #{oa[:is_oa] ? '是' : '否'} |"
      end
      
      if oa[:oa_start_year].present?
        status_rows << "| OA 起始年份 | #{oa[:oa_start_year]} |"
        mark_used("open_access.oa_start_year")
      end
      
      if oa[:author_retains_copyright].present?
        status_rows << "| 作者保留版权 | #{oa[:author_retains_copyright] ? '是' : '否'} |"
        mark_used("open_access.author_retains_copyright")
      end

      if status_rows.any?
        out << "| 项目 | 状态 |\n"
        out << "|------|------|\n"
        out << status_rows.join("\n") + "\n\n"
      end

      # 许可证
      if oa[:license_list]&.any?
        out << "**许可证**\n\n"
        oa[:license_list].each do |license|
          if license.is_a?(Hash)
            license_name = license[:type] || "Unknown"
            if license[:url].present?
              out << "- #{link(license_name, license[:url])}\n"
            else
              out << "- #{license_name}\n"
            end
          else
            out << "- #{license}\n"
          end
        end
        out << "\n"
        mark_used("open_access.license_list")
      end

      # APC 信息
      if oa[:has_apc].present? || oa[:apc_price].present?
        out << "**文章处理费 (APC)**\n\n"
        
        apc_rows = []
        if oa[:has_apc].present?
          apc_rows << "| 收取 APC | #{oa[:has_apc] ? '是' : '否'} |"
          mark_used("open_access.has_apc")
        end

        if oa[:apc_price]
          apc = oa[:apc_price]
          if apc[:primary]
            primary = apc[:primary]
            apc_rows << "| APC 价格 | #{primary[:price]} #{primary[:currency]} |"
          end
          if apc[:usd_estimate]
            apc_rows << "| 美元估算 | $#{apc[:usd_estimate]} |"
          end
          mark_used("open_access.apc_price")
        end

        if apc_rows.any?
          out << "| 项目 | 金额 |\n"
          out << "|------|------|\n"
          out << apc_rows.join("\n") + "\n\n"
        end

        if oa[:apc_url].present?
          out << "#{link('查看 APC 政策', oa[:apc_url])}\n\n"
          mark_used("open_access.apc_url")
        end
      end

      # 减免政策
      if oa[:has_waiver].present? && oa[:has_waiver]
        out << "**减免政策**: "
        if oa[:waiver_url].present?
          out << "#{link('查看减免说明', oa[:waiver_url])}\n\n"
          mark_used("open_access.waiver_url")
        else
          out << "有\n\n"
        end
        mark_used("open_access.has_waiver")
      end

      # 相关链接
      links = []
      links << link("版权说明", oa[:copyright_url]) if oa[:copyright_url].present?
      links << link("许可证条款", oa[:license_terms_url]) if oa[:license_terms_url].present?
      
      if links.any?
        out << "**相关链接**: #{links.join(" · ")}\n"
        mark_used("open_access.copyright_url", "open_access.license_terms_url")
      end

      out.presence
    end

    # ==================== 学术指标与产出 ====================
    def render_metrics_content
      metrics = @data[:metrics] || {}
      return nil unless metrics.values.any?(&:present?)

      out = +""

      # 标记字段为已使用
      mark_used("metrics.oa_works_count") if metrics[:oa_works_count]
      mark_used("metrics.two_year_mean_citedness") if metrics[:two_year_mean_citedness]
      mark_used("metrics.i10_index") if metrics[:i10_index]
      mark_used("metrics.works_api_url") if metrics[:works_api_url].present?

      # 年度统计柱状图
      if metrics[:counts_by_year]&.any?
        out << render_metrics_chart(metrics[:counts_by_year], metrics)
        mark_used("metrics.counts_by_year")
      end

      out.presence
    end

    def render_metrics_chart(counts_by_year, metrics)
      # 取最近 8 年数据，保持年份降序（大的在上面）
      chart_data = counts_by_year.first(8)
      return "" if chart_data.empty?

      out = +""

      # 发文量柱状图
      max_works = chart_data.map { |d| d[:works_count].to_i }.max
      max_works = 1 if max_works.zero?

      total_works = metrics[:works_count]
      out << "**年度发文量**"
      out << "（累计 #{format_number(total_works)} 篇）" if total_works
      out << "\n\n"
      out << "```\n"
      
      chart_data.each do |item|
        year = item[:year].to_s
        works = item[:works_count].to_i
        bar_length = (works.to_f / max_works * 25).round
        bar = "█" * bar_length
        out << "#{year} │#{bar} #{format_number(works)}\n"
      end
      
      out << "```\n\n"

      # 被引量柱状图
      max_cited = chart_data.map { |d| d[:cited_by_count].to_i }.max
      if max_cited && max_cited > 0
        total_cited = metrics[:cited_by_count]
        out << "**年度被引量**"
        out << "（累计 #{format_number(total_cited)} 次）" if total_cited
        out << "\n\n"
        out << "```\n"
        
        chart_data.each do |item|
          year = item[:year].to_s
          cited = item[:cited_by_count].to_i
          bar_length = (cited.to_f / max_cited * 25).round
          bar = "█" * bar_length
          out << "#{year} │#{bar} #{format_number(cited)}\n"
        end
        
        out << "```\n"
      end

      out
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

      # 相关链接表格
      link_items = []
      
      if review[:review_url].present?
        link_items << ["审稿流程", review[:review_url]]
        mark_used("review_compliance.review_url")
      end
      if review[:editorial_board_url].present?
        link_items << ["编委会", review[:editorial_board_url]]
        mark_used("review_compliance.editorial_board_url")
      end
      if review[:author_instructions_url].present?
        link_items << ["投稿指南", review[:author_instructions_url]]
        mark_used("review_compliance.author_instructions_url")
      end
      if review[:oa_statement_url].present?
        link_items << ["OA 声明", review[:oa_statement_url]]
        mark_used("review_compliance.oa_statement_url")
      end
      if review[:aims_scope_url].present?
        link_items << ["期刊宗旨", review[:aims_scope_url]]
        mark_used("review_compliance.aims_scope_url")
      end

      if link_items.any?
        out << "**相关链接**\n\n"
        link_items.each do |name, url|
          out << "- #{link(name, url)}\n"
        end
        out << "\n"
      end

      if review[:plagiarism_detection].present?
        status = review[:plagiarism_detection] ? "是" : "否"
        out << "**反抄袭检测**: #{status}"
        if review[:plagiarism_url].present?
          out << " (#{link('查看详情', review[:plagiarism_url])})"
          mark_used("review_compliance.plagiarism_url")
        end
        out << "\n"
        mark_used("review_compliance.plagiarism_detection")
      end

      out.presence
    end

    # ==================== 保存与索引 ====================
    def render_preservation_content
      pres = @data[:preservation] || {}
      return nil unless pres.values.any?(&:present?)

      out = +""
      items = []

      if pres[:preservation_service]&.any?
        items << "**保存服务**: #{pres[:preservation_service].join(" · ")}"
        mark_used("preservation.preservation_service")
      end

      if pres[:preservation_national_library]&.any?
        items << "**国家图书馆**: #{pres[:preservation_national_library].join(" · ")}"
        mark_used("preservation.preservation_national_library")
      end

      if pres[:deposit_policy_service]&.any?
        items << "**存储服务**: #{pres[:deposit_policy_service].join(" · ")}"
        mark_used("preservation.deposit_policy_service")
      end

      out << items.join("\n\n") + "\n\n" if items.any?

      # 相关链接
      links = []
      links << link("保存政策", pres[:preservation_url]) if pres[:preservation_url].present?
      links << link("存储政策", pres[:deposit_policy_url]) if pres[:deposit_policy_url].present?
      
      if links.any?
        out << links.join(" · ") + "\n"
        mark_used("preservation.preservation_url", "preservation.deposit_policy_url")
      end

      mark_used("preservation.has_deposit_policy") if pres[:has_deposit_policy].present?

      out.presence
    end

    # ==================== 学科与主题 ====================
    def render_subjects_content
      subjects = @data[:subjects_topics] || {}
      return nil unless subjects.values.any?(&:present?)

      out = +""

      # 学科分类（标签式展示）
      if subjects[:subject_list]&.any?
        terms = subjects[:subject_list].map do |subj|
          if subj.is_a?(Hash)
            subj[:term] || subj["term"] || subj[:code]
          else
            subj
          end
        end.compact
        out << "**学科**: #{terms.join(" · ")}\n\n" if terms.any?
        mark_used("subjects_topics.subject_list")
      end

      # 关键词（标签式展示）
      if subjects[:keywords]&.any?
        out << "**关键词**: #{subjects[:keywords].first(10).join(" · ")}\n\n"
        mark_used("subjects_topics.keywords")
      end

      # OpenAlex 主题（简化展示）
      if subjects[:topics_top]&.any?
        out << "**研究主题**\n\n"
        subjects[:topics_top].first(5).each do |topic|
          name = topic[:display_name] || "—"
          field = topic.dig(:field, :display_name)
          if field
            out << "- #{name} → #{field}\n"
          else
            out << "- #{name}\n"
          end
        end
        out << "\n"
        mark_used("subjects_topics.topics_top")
      end

      out.presence
    end

    # ==================== Crossref 元数据质量 ====================
    def render_crossref_content
      quality = @data[:crossref_quality] || {}
      return nil unless quality.values.any?(&:present?)

      out = +""

      # DOI 统计（简洁显示）
      if quality[:doi_counts]
        counts = quality[:doi_counts]
        total = counts[:total_dois] || counts[:"total-dois"]
        if total
          out << "**DOI 总数**: #{format_number(total)}\n\n"
        end
        mark_used("crossref_quality.doi_counts")
      end

      # 元数据覆盖率（柱状图）
      if quality[:metadata_coverage].present?
        coverage = quality[:metadata_coverage]
        if coverage.is_a?(Hash) && coverage.any?
          out << "**元数据覆盖率**\n\n"
          out << "```\n"
          
          # 选择主要字段展示
          key_fields = %w[abstracts references orcids funders licenses affiliations]
          coverage.each do |field, rate|
            next if rate.nil?
            next unless key_fields.include?(field.to_s) || coverage.size <= 8
            
            percentage = rate.is_a?(Numeric) ? (rate * 100).round(0) : rate.to_i
            bar_length = (percentage.to_f / 100 * 20).round
            bar = "█" * bar_length
            empty = "░" * (20 - bar_length)
            field_name = format_field_name(field.to_s)
            out << "#{field_name.ljust(12)} │#{bar}#{empty} #{percentage}%\n"
          end
          
          out << "```\n"
        end
        mark_used("crossref_quality.metadata_coverage")
      end

      out.presence
    end

    def format_field_name(field)
      names = {
        "abstracts" => "摘要",
        "references" => "参考文献",
        "orcids" => "ORCID",
        "funders" => "资助信息",
        "licenses" => "许可证",
        "affiliations" => "机构信息",
        "award-numbers" => "基金号",
        "resource-links" => "资源链接",
      }
      names[field] || field
    end

    # ==================== NLM 编目信息 ====================
    def render_nlm_content
      nlm = @data[:nlm_cataloging] || {}
      return nil unless nlm.values.any?(&:present?)

      out = +""
      
      items = []
      if nlm[:medline_ta].present?
        items << "**MEDLINE**: #{nlm[:medline_ta]}"
        mark_used("nlm_cataloging.medline_ta")
      end
      if nlm[:current_indexing_status].present?
        status = nlm[:current_indexing_status] == "Y" ? "已索引" : "未索引"
        items << "**状态**: #{status}"
      end
      if nlm[:nlm_date_revised].present?
        items << "**更新**: #{nlm[:nlm_date_revised]}"
        mark_used("nlm_cataloging.nlm_date_revised")
      end

      out << items.join(" · ") + "\n\n" if items.any?

      if nlm[:broad_heading]&.any?
        out << "**主题词**: #{nlm[:broad_heading].join(" · ")}\n"
        mark_used("nlm_cataloging.broad_heading")
      end

      # 标记其他字段为已使用
      mark_used("nlm_cataloging.resource_type") if nlm[:resource_type]&.any?

      out.presence
    end
  end
end
