# frozen_string_literal: true

module DiscourseJournals
  # 统一档案渲染服务：将归一化字段渲染为Markdown格式
  class MasterRecordRenderer
    def initialize(normalized_data)
      @data = normalized_data
    end

    def render
      I18n.with_locale(SiteSetting.default_locale) do
        sections = []

        sections << render_identity if has_data?(@data[:identity])
        sections << render_publication if has_data?(@data[:publication])
        sections << render_open_access if has_data?(@data[:open_access])
        sections << render_review_compliance if has_data?(@data[:review_compliance])
        sections << render_preservation if has_data?(@data[:preservation])
        sections << render_subjects_topics if has_data?(@data[:subjects_topics])
        sections << render_metrics if has_data?(@data[:metrics])
        sections << render_crossref_quality if has_data?(@data[:crossref_quality])
        sections << render_nlm_cataloging if has_data?(@data[:nlm_cataloging])

        sections.compact.join("\n\n")
      end
    end

    private

    attr_reader :data

    def has_data?(section)
      return false if section.nil?
      section.values.any? { |v| v.present? }
    end

    def t(key)
      I18n.t("discourse_journals.master_record.#{key}")
    end

    def format_value(value, type = :default)
      return "—" if value.nil? || (value.respond_to?(:empty?) && value.empty?)

      case type
      when :boolean
        value ? I18n.t("discourse_journals.values.yes") : I18n.t("discourse_journals.values.no")
      when :array
        value.is_a?(Array) ? value.join(", ") : value.to_s
      when :url
        value
      else
        value.to_s
      end
    end

    # A. 身份与链接类
    def render_identity
      identity = @data[:identity]
      return nil unless identity

      out = +"# #{t("sections.identity")}\n\n"

      out << field_line("title_main", identity[:title_main])
      
      if identity[:title_alternate]&.any?
        out << field_line("title_alternate", format_value(identity[:title_alternate], :array))
      end

      out << field_line("issn_l", identity[:issn_l])
      
      if identity[:issn_list]&.any?
        out << field_line("issn_list", format_value(identity[:issn_list], :array))
      end

      # ISSN 类型明细表格
      if identity[:issn_type_detail]&.any?
        out << "\n**#{t("fields.issn_type_detail")}**:\n\n"
        out << "| #{t("columns.issn")} | #{t("columns.type")} | #{t("columns.source")} |\n"
        out << "|---|---|---|\n"
        identity[:issn_type_detail].each do |detail|
          out << "| #{detail[:issn]} | #{detail[:type]} | #{detail[:source]} |\n"
        end
        out << "\n"
      end

      out << field_line("homepage_url", identity[:homepage_url], :url)

      if identity[:official_website_list]&.any? && identity[:official_website_list].size > 1
        out << "\n**#{t("fields.official_website_list")}**:\n\n"
        identity[:official_website_list].each { |url| out << "- #{url}\n" }
        out << "\n"
      end

      # 外部 ID
      if identity[:external_ids]
        ids = identity[:external_ids]
        if ids.values.any?(&:present?)
          out << "\n**#{t("fields.external_ids")}**:\n\n"
          out << "- **OpenAlex**: #{ids[:openalex_id]}\n" if ids[:openalex_id]
          out << "- **Wikidata**: #{ids[:wikidata_id]}\n" if ids[:wikidata_id]
          out << "- **NLM**: #{ids[:nlm_unique_id]}\n" if ids[:nlm_unique_id]
        end
      end

      out
    end

    # B. 出版与地域类
    def render_publication
      pub = @data[:publication]
      return nil unless pub

      out = +"# #{t("sections.publication")}\n\n"

      out << field_line("publisher_name", pub[:publisher_name])
      
      if pub[:publisher_country]
        country_str = [pub[:publisher_country][:name], pub[:publisher_country][:code]].compact.join(" / ")
        out << field_line("publisher_country", country_str)
      end

      out << field_line("publication_place", pub[:publication_place])

      # 起始年份（可能有冲突）
      if pub[:start_year_cataloging] || pub[:start_year_statistical]
        out << "\n**#{t("fields.start_year")}**:\n"
        if pub[:start_year_cataloging]
          out << "- #{t("fields.start_year_cataloging")}: #{pub[:start_year_cataloging]}\n"
        end
        if pub[:start_year_statistical] && pub[:start_year_statistical] != pub[:start_year_cataloging]
          out << "- #{t("fields.start_year_statistical")}: #{pub[:start_year_statistical]}\n"
        end
        out << "\n"
      end

      out << field_line("oa_start_year", pub[:oa_start_year])
      out << field_line("end_year", pub[:end_year])
      out << field_line("serial_publication_note", pub[:serial_publication_note])
      
      if pub[:language]&.any?
        out << field_line("language", format_value(pub[:language], :array))
      end

      out
    end

    # C. 开放获取与费用类
    def render_open_access
      oa = @data[:open_access]
      return nil unless oa

      out = +"# #{t("sections.open_access")}\n\n"

      out << field_line("is_oa", oa[:is_oa], :boolean)
      out << field_line("is_in_doaj", oa[:is_in_doaj], :boolean)
      out << field_line("doaj_since_year", oa[:doaj_since_year])
      out << field_line("oa_start_year", oa[:oa_start_year])
      out << field_line("author_retains_copyright", oa[:author_retains_copyright], :boolean)
      out << field_line("copyright_url", oa[:copyright_url], :url)

      # 许可证列表
      if oa[:license_list]&.any?
        out << "\n**#{t("fields.license_list")}**:\n\n"
        oa[:license_list].each do |license|
          license_str = license[:type] || "Unknown"
          license_str += " (#{license[:url]})" if license[:url]
          out << "- #{license_str}\n"
        end
        out << "\n"
      end

      out << field_line("license_terms_url", oa[:license_terms_url], :url)
      out << field_line("has_apc", oa[:has_apc], :boolean)

      # APC 价格（含主值和候选值）
      if oa[:apc_price]
        out << "\n**#{t("fields.apc_price")}**:\n\n"
        if oa[:apc_price][:primary]
          primary = oa[:apc_price][:primary]
          out << "- #{t("apc.primary")}: #{primary[:price]} #{primary[:currency]} (#{primary[:source]})\n"
        end
        if oa[:apc_price][:alternatives]&.any?
          oa[:apc_price][:alternatives].each do |alt|
            out << "- #{t("apc.alternative")}: #{alt[:price]} #{alt[:currency]} (#{alt[:source]})\n"
          end
        end
        if oa[:apc_price][:usd_estimate]
          out << "- #{t("apc.usd_estimate")}: $#{oa[:apc_price][:usd_estimate]} USD\n"
        end
        out << "\n"
      end

      out << field_line("apc_url", oa[:apc_url], :url)
      out << field_line("has_waiver", oa[:has_waiver], :boolean)
      out << field_line("waiver_url", oa[:waiver_url], :url)

      if oa[:other_charges]
        out << field_line("other_charges_has", oa[:other_charges][:has_other_charges], :boolean)
        out << field_line("other_charges_url", oa[:other_charges][:url], :url)
      end

      out
    end

    # D. 同行评审与伦理合规
    def render_review_compliance
      review = @data[:review_compliance]
      return nil unless review

      out = +"# #{t("sections.review_compliance")}\n\n"

      if review[:review_process]&.any?
        out << field_line("review_process", format_value(review[:review_process], :array))
      end

      out << field_line("review_url", review[:review_url], :url)
      out << field_line("editorial_board_url", review[:editorial_board_url], :url)
      out << field_line("plagiarism_detection", review[:plagiarism_detection], :boolean)
      out << field_line("plagiarism_url", review[:plagiarism_url], :url)
      out << field_line("author_instructions_url", review[:author_instructions_url], :url)
      out << field_line("oa_statement_url", review[:oa_statement_url], :url)
      out << field_line("aims_scope_url", review[:aims_scope_url], :url)
      
      if review[:publication_time_weeks]
        out << field_line(
          "publication_time_weeks",
          "#{review[:publication_time_weeks]} #{t("values.weeks")}",
        )
      end

      out
    end

    # E. 归档保存与索引政策
    def render_preservation
      pres = @data[:preservation]
      return nil unless pres

      out = +"# #{t("sections.preservation")}\n\n"

      if pres[:preservation_service]&.any?
        out << field_line("preservation_service", format_value(pres[:preservation_service], :array))
      end

      if pres[:preservation_national_library]&.any?
        out <<
          field_line(
            "preservation_national_library",
            format_value(pres[:preservation_national_library], :array),
          )
      end

      out << field_line("preservation_url", pres[:preservation_url], :url)
      out << field_line("has_deposit_policy", pres[:has_deposit_policy], :boolean)

      if pres[:deposit_policy_service]&.any?
        out <<
          field_line("deposit_policy_service", format_value(pres[:deposit_policy_service], :array))
      end

      out << field_line("deposit_policy_url", pres[:deposit_policy_url], :url)

      out
    end

    # F. 学科与主题
    def render_subjects_topics
      subjects = @data[:subjects_topics]
      return nil unless subjects

      out = +"# #{t("sections.subjects_topics")}\n\n"

      # 学科分类
      if subjects[:subject_list]&.any?
        out << "**#{t("fields.subject_list")}**:\n\n"
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
      end

      # 关键词
      if subjects[:keywords]&.any?
        out << field_line("keywords", format_value(subjects[:keywords], :array))
      end

      # OpenAlex 主题
      if subjects[:topics_top]&.any?
        out << "\n**#{t("fields.topics_top")} (OpenAlex)**:\n\n"
        subjects[:topics_top].first(5).each do |topic|
          out << "- **#{topic[:display_name]}**\n"
          out << "  - #{t("fields.topic_field")}: #{topic.dig(:field, :display_name)}\n" if topic.dig(
            :field,
            :display_name,
          )
          out << "  - #{t("fields.topic_subfield")}: #{topic.dig(:subfield, :display_name)}\n" if topic.dig(
            :subfield,
            :display_name,
          )
          out << "  - #{t("fields.topic_count")}: #{topic[:count]}\n" if topic[:count]
        end
        out << "\n"
      end

      out
    end

    # G. 产出、引用与指标
    def render_metrics
      metrics = @data[:metrics]
      return nil unless metrics

      out = +"# #{t("sections.metrics")}\n\n"

      out << field_line("works_count", metrics[:works_count])
      out << field_line("oa_works_count", metrics[:oa_works_count])
      out << field_line("cited_by_count", metrics[:cited_by_count])
      out << field_line("two_year_mean_citedness", metrics[:two_year_mean_citedness]&.round(3))
      out << field_line("h_index", metrics[:h_index])
      out << field_line("i10_index", metrics[:i10_index])

      # 年度统计
      if metrics[:counts_by_year]&.any?
        out << "\n**#{t("fields.counts_by_year")}**:\n\n"
        out <<
          "| #{t("columns.year")} | #{t("columns.works")} | #{t("columns.oa_works")} | #{t("columns.cited_by")} |\n"
        out << "|---:|---:|---:|---:|\n"
        metrics[:counts_by_year].first(10).each do |item|
          out <<
            "| #{item[:year]} | #{item[:works_count]} | #{item[:oa_works_count]} | #{item[:cited_by_count]} |\n"
        end
        out << "\n"
      end

      out << field_line("works_api_url", metrics[:works_api_url], :url)

      out
    end

    # H. Crossref 覆盖度与存量统计
    def render_crossref_quality
      quality = @data[:crossref_quality]
      return nil unless quality

      out = +"# #{t("sections.crossref_quality")}\n\n"

      # DOI 统计
      if quality[:doi_counts]
        counts = quality[:doi_counts]
        out << "**#{t("fields.doi_counts")}**:\n\n"
        out << "- #{t("fields.total_dois")}: #{counts[:total_dois] || counts[:"total-dois"]}\n" if counts[
          :total_dois
        ] || counts[:"total-dois"]
        out << "- #{t("fields.current_dois")}: #{counts[:current_dois] || counts[:"current-dois"]}\n" if counts[
          :current_dois
        ] || counts[:"current-dois"]
        out << "- #{t("fields.backfile_dois")}: #{counts[:backfile_dois] || counts[:"backfile-dois"]}\n" if counts[
          :backfile_dois
        ] || counts[:"backfile-dois"]
        out << "\n"
      end

      # DOI 年份分布
      if quality[:dois_by_year]&.any?
        out << "**#{t("fields.dois_by_year")}**:\n\n"
        out << "| #{t("columns.year")} | #{t("columns.dois")} |\n"
        out << "|---:|---:|\n"
        quality[:dois_by_year].first(10).each { |year, count| out << "| #{year} | #{count} |\n" }
        out << "\n"
      end

      out
    end

    # I. NLM 编目与索引信息
    def render_nlm_cataloging
      nlm = @data[:nlm_cataloging]
      return nil unless nlm

      out = +"# #{t("sections.nlm_cataloging")}\n\n"

      out << field_line("title_sort", nlm[:title_sort])
      out << field_line("medline_ta", nlm[:medline_ta])

      if nlm[:current_indexing_status]
        status_text =
          nlm[:current_indexing_status] == "Y" ? I18n.t("discourse_journals.values.yes") : I18n.t(
            "discourse_journals.values.no",
          )
        out << field_line("current_indexing_status", status_text)
      end

      # 资源类型
      if nlm[:resource_type]&.any?
        types = nlm[:resource_type].map { |r| r.is_a?(Hash) ? r[:resourceunit] : r }.compact
        out << field_line("resource_type", format_value(types, :array)) if types.any?
      end

      out << field_line("nlm_date_revised", nlm[:nlm_date_revised])

      if nlm[:broad_heading]&.any?
        out << field_line("broad_heading", format_value(nlm[:broad_heading], :array))
      end

      out << field_line("continuation_notes", nlm[:continuation_notes])

      out
    end

    def field_line(key, value, type = :default)
      return "" if value.nil? || (value.respond_to?(:empty?) && value.empty?)

      formatted = format_value(value, type)
      return "" if formatted == "—"

      "- **#{t("fields.#{key}")}**: #{formatted}\n"
    end
  end
end
