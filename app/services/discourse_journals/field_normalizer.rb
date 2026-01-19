# frozen_string_literal: true

module DiscourseJournals
  # 字段归一化服务：将各数据源字段映射到统一结构
  class FieldNormalizer
    def initialize(journal_data)
      @journal_data = ensure_hash(journal_data).deep_symbolize_keys
      @unified_index = ensure_hash(@journal_data[:unified_index])
      @sources = ensure_hash(@journal_data[:sources])
    end

    def normalize
      {
        identity: build_identity,
        publication: build_publication,
        open_access: build_open_access,
        review_compliance: build_review_compliance,
        preservation: build_preservation,
        subjects_topics: build_subjects_topics,
        metrics: build_metrics,
        crossref_quality: build_crossref_quality,
        nlm_cataloging: build_nlm_cataloging,
      }
    end

    private

    attr_reader :journal_data, :unified_index, :sources

    def ensure_hash(data)
      return {} if data.nil?
      return data if data.is_a?(Hash)
      
      if data.is_a?(String)
        begin
          parsed = JSON.parse(data)
          return parsed if parsed.is_a?(Hash)
        rescue JSON::ParserError
          # fallthrough
        end
      end
      
      {}
    end

    def safe_dig(hash, *keys)
      return nil if hash.nil?
      
      # 如果是字符串，尝试解析为 JSON
      if hash.is_a?(String)
        begin
          hash = JSON.parse(hash)
        rescue JSON::ParserError
          return nil
        end
      end
      
      # 如果不是哈希类型，返回 nil
      return nil unless hash.respond_to?(:dig)
      
      hash.dig(*keys)
    rescue StandardError
      nil
    end

    # A. 身份与链接类
    def build_identity
      crossref = sources[:crossref] || {}
      doaj = sources[:doaj] || {}
      nlm = sources[:nlm] || {}
      openalex = sources[:openalex] || {}
      wikidata = sources[:wikidata] || {}

      crossref_msg = safe_dig(crossref, :message) || crossref
      doaj_result = safe_dig(doaj, :results, 0) || {}
      doaj_bibjson = doaj_result[:bibjson] || {}
      nlm_result = nlm[:result] || {}
      nlm_journal = nlm_result.values.find { |v| v.is_a?(Hash) && v[:uid] } || {}
      wikidata_bindings = safe_dig(wikidata, :results, :bindings) || []

      {
        title_main: extract_title,
        title_alternate: extract_alternate_titles(nlm_journal, openalex),
        issn_l: openalex[:issn_l] || journal_data[:issn],
        issn_list: extract_issn_list(crossref_msg, nlm_journal, openalex, doaj_bibjson),
        issn_type_detail: extract_issn_type_detail(crossref_msg, nlm_journal),
        homepage_url: extract_homepage(openalex, doaj_bibjson, wikidata_bindings),
        official_website_list: extract_official_websites(wikidata_bindings, doaj_bibjson),
        external_ids: {
          openalex_id: openalex[:id],
          wikidata_id: extract_wikidata_id(openalex, wikidata_bindings),
          nlm_unique_id: nlm_journal[:nlmuniqueid],
          crossref_status: crossref_msg[:status],
        },
      }
    end

    # B. 出版与地域类
    def build_publication
      crossref = sources[:crossref] || {}
      doaj = sources[:doaj] || {}
      nlm = sources[:nlm] || {}
      openalex = sources[:openalex] || {}

      crossref_msg = safe_dig(crossref, :message) || crossref
      doaj_result = safe_dig(doaj, :results, 0) || {}
      doaj_bibjson = doaj_result[:bibjson] || {}
      nlm_result = nlm[:result] || {}
      nlm_journal = nlm_result.values.find { |v| v.is_a?(Hash) && v[:uid] } || {}

      {
        publisher_name: extract_publisher_name(doaj_bibjson, crossref_msg, nlm_journal, openalex),
        publisher_country: extract_publisher_country(doaj_bibjson, openalex, nlm_journal),
        publication_place: safe_dig(nlm_journal, :publicationinfolist, 0, :place),
        start_year_cataloging: nlm_journal[:startyear],
        start_year_statistical: openalex[:first_publication_year],
        oa_start_year: doaj_bibjson[:oa_start],
        end_year: nlm_journal[:endyear],
        serial_publication_note: safe_dig(nlm_journal, :publicationinfolist, 0, :datesofserialpublication),
        language: extract_languages(unified_index, doaj_bibjson, nlm_journal),
      }
    end

    # C. 开放获取与费用类
    def build_open_access
      doaj = sources[:doaj] || {}
      openalex = sources[:openalex] || {}

      doaj_result = safe_dig(doaj, :results, 0) || {}
      doaj_bibjson = doaj_result[:bibjson] || {}

      {
        is_oa: openalex[:is_oa] || doaj_bibjson[:boai],
        is_in_doaj: openalex[:is_in_doaj] || !doaj_result.empty?,
        doaj_since_year: openalex[:is_in_doaj_since_year],
        oa_start_year: doaj_bibjson[:oa_start],
        author_retains_copyright: safe_dig(doaj_bibjson, :copyright, :author_retains),
        copyright_url: safe_dig(doaj_bibjson, :copyright, :url),
        license_list: doaj_bibjson[:license],
        license_terms_url: safe_dig(doaj_bibjson, :ref, :license_terms),
        has_apc: extract_has_apc(doaj_bibjson, openalex),
        apc_price: extract_apc_price(doaj_bibjson, openalex),
        apc_url: safe_dig(doaj_bibjson, :apc, :url),
        has_waiver: safe_dig(doaj_bibjson, :waiver, :has_waiver),
        waiver_url: safe_dig(doaj_bibjson, :waiver, :url),
        other_charges: doaj_bibjson[:other_charges],
      }
    end

    # D. 同行评审与伦理合规
    def build_review_compliance
      doaj = sources[:doaj] || {}
      doaj_result = safe_dig(doaj, :results, 0) || {}
      doaj_bibjson = doaj_result[:bibjson] || {}

      {
        review_process: safe_dig(doaj_bibjson, :editorial, :review_process),
        review_url: safe_dig(doaj_bibjson, :editorial, :review_url),
        editorial_board_url: safe_dig(doaj_bibjson, :editorial, :board_url),
        plagiarism_detection: safe_dig(doaj_bibjson, :plagiarism, :detection),
        plagiarism_url: safe_dig(doaj_bibjson, :plagiarism, :url),
        author_instructions_url: safe_dig(doaj_bibjson, :ref, :author_instructions),
        oa_statement_url: safe_dig(doaj_bibjson, :ref, :oa_statement),
        aims_scope_url: safe_dig(doaj_bibjson, :ref, :aims_scope),
        publication_time_weeks: doaj_bibjson[:publication_time_weeks],
      }
    end

    # E. 归档保存与索引政策
    def build_preservation
      doaj = sources[:doaj] || {}
      doaj_result = safe_dig(doaj, :results, 0) || {}
      doaj_bibjson = doaj_result[:bibjson] || {}

      {
        preservation_service: safe_dig(doaj_bibjson, :preservation, :service),
        preservation_national_library: safe_dig(doaj_bibjson, :preservation, :national_library),
        preservation_url: safe_dig(doaj_bibjson, :preservation, :url),
        has_deposit_policy: safe_dig(doaj_bibjson, :deposit_policy, :has_policy),
        deposit_policy_service: safe_dig(doaj_bibjson, :deposit_policy, :service),
        deposit_policy_url: safe_dig(doaj_bibjson, :deposit_policy, :url),
      }
    end

    # F. 学科与主题
    def build_subjects_topics
      doaj = sources[:doaj] || {}
      openalex = sources[:openalex] || {}

      doaj_result = safe_dig(doaj, :results, 0) || {}
      doaj_bibjson = doaj_result[:bibjson] || {}

      {
        subject_list: doaj_bibjson[:subject],
        keywords: doaj_bibjson[:keywords],
        topics_top: openalex[:topics],
        topic_share: safe_dig(openalex, :topic_share),
      }
    end

    # G. 产出、引用与指标
    def build_metrics
      openalex = sources[:openalex] || {}

      {
        works_count: openalex[:works_count] || unified_index[:works_count],
        oa_works_count: openalex[:oa_works_count],
        cited_by_count: openalex[:cited_by_count] || unified_index[:cited_by_count],
        two_year_mean_citedness: safe_dig(openalex, :summary_stats, :"2yr_mean_citedness"),
        h_index: safe_dig(openalex, :summary_stats, :h_index),
        i10_index: safe_dig(openalex, :summary_stats, :i10_index),
        counts_by_year: openalex[:counts_by_year],
        works_api_url: openalex[:works_api_url],
      }
    end

    # H. Crossref 覆盖度与存量统计
    def build_crossref_quality
      crossref = sources[:crossref] || {}
      crossref_msg = safe_dig(crossref, :message) || crossref

      {
        doi_counts: crossref_msg[:counts],
        dois_by_year: safe_dig(crossref_msg, :breakdowns, :dois_by_issued_year),
        metadata_coverage: crossref_msg[:coverage],
        coverage_type: crossref_msg[:"coverage-type"],
        deposit_flags: crossref_msg[:flags],
        crossref_subjects: crossref_msg[:subjects],
      }
    end

    # I. NLM 编目与索引信息
    def build_nlm_cataloging
      nlm = sources[:nlm] || {}
      nlm_result = nlm[:result] || {}
      nlm_journal = nlm_result.values.find { |v| v.is_a?(Hash) && v[:uid] } || {}

      {
        title_sort: nlm_journal[:titlemainsort],
        medline_ta: nlm_journal[:medlineta],
        current_indexing_status: nlm_journal[:currentindexingstatus],
        resource_type: nlm_journal[:resourceinfolist],
        nlm_date_revised: nlm_journal[:daterevised],
        broad_heading: nlm_journal[:broadheading],
        continuation_notes: nlm_journal[:continuationnotes],
      }
    end

    # 辅助方法
    def extract_title
      unified_index[:title] ||
        safe_dig(sources, :openalex, :display_name) ||
        safe_dig(sources, :crossref, :message, :title) ||
        safe_dig(sources, :doaj, :results, 0, :bibjson, :title) ||
        safe_dig(sources, :nlm, :result)&.values&.find { |v| v.is_a?(Hash) && v[:uid] }&.dig(:titlemainlist, 0, :title) ||
        journal_data[:name]
    end

    def extract_alternate_titles(nlm_journal, openalex)
      titles = []
      titles.concat(nlm_journal[:titleotherlist]&.map { |t| t[:titlealternate] } || [])
      titles.concat(openalex[:alternate_titles] || [])
      titles.compact.uniq
    end

    def extract_issn_list(crossref_msg, nlm_journal, openalex, doaj_bibjson)
      issns = []
      issns.concat(crossref_msg[:ISSN] || [])
      issns.concat(nlm_journal[:issnlist]&.map { |i| i[:issn] } || [])
      issns.concat(openalex[:issn] || [])
      issns << doaj_bibjson[:eissn] if doaj_bibjson[:eissn]
      issns << doaj_bibjson[:pissn] if doaj_bibjson[:pissn]
      issns.compact.uniq
    end

    def extract_issn_type_detail(crossref_msg, nlm_journal)
      details = []

      if crossref_msg[:"issn-type"]
        crossref_msg[:"issn-type"].each do |item|
          details << { issn: item[:value], type: item[:type], source: "Crossref" }
        end
      end

      if nlm_journal[:issnlist]
        nlm_journal[:issnlist].each do |item|
          details << { issn: item[:issn], type: item[:issntype], source: "NLM" }
        end
      end

      details
    end

    def extract_homepage(openalex, doaj_bibjson, wikidata_bindings)
      openalex[:homepage_url] ||
        safe_dig(doaj_bibjson, :ref, :journal) ||
        wikidata_bindings.first&.dig(:officialWebsite, :value) ||
        unified_index[:homepage]
    end

    def extract_official_websites(wikidata_bindings, doaj_bibjson)
      websites = []
      websites.concat(wikidata_bindings.map { |b| b.dig(:officialWebsite, :value) }.compact)
      websites << safe_dig(doaj_bibjson, :ref, :journal) if safe_dig(doaj_bibjson, :ref, :journal)
      websites.compact.uniq
    end

    def extract_wikidata_id(openalex, wikidata_bindings)
      openalex.dig(:ids, :wikidata) ||
        wikidata_bindings.first&.dig(:item, :value)&.split("/")&.last
    end

    def extract_publisher_name(doaj_bibjson, crossref_msg, nlm_journal, openalex)
      safe_dig(doaj_bibjson, :publisher, :name) ||
        safe_dig(nlm_journal, :publicationinfolist, 0, :publisher) ||
        openalex[:host_organization_name] ||
        crossref_msg[:publisher] ||
        unified_index[:publisher]
    end

    def extract_publisher_country(doaj_bibjson, openalex, nlm_journal)
      country_code = safe_dig(doaj_bibjson, :publisher, :country) || openalex[:country_code]
      country_name = nlm_journal[:country] || unified_index[:country]

      if country_code || country_name
        { code: country_code, name: country_name }.compact
      else
        nil
      end
    end

    def extract_languages(unified_index, doaj_bibjson, nlm_journal)
      langs = []
      langs.concat(unified_index[:languages] || [])
      langs.concat(doaj_bibjson[:language] || [])
      langs << nlm_journal[:language] if nlm_journal[:language]
      langs.compact.uniq
    end

    def extract_has_apc(doaj_bibjson, openalex)
      safe_dig(doaj_bibjson, :apc, :has_apc) ||
        (!openalex[:apc_prices].nil? && !openalex[:apc_prices].empty?) ||
        unified_index[:apc_has]
    end

    def extract_apc_price(doaj_bibjson, openalex)
      result = { primary: nil, alternatives: [] }

      # DOAJ 作为主值
      if safe_dig(doaj_bibjson, :apc, :max)&.any?
        max_apc = doaj_bibjson[:apc][:max].first
        result[:primary] = {
          price: max_apc[:price],
          currency: max_apc[:currency],
          source: "DOAJ",
        }
      end

      # OpenAlex 作为候选值
      if openalex[:apc_prices]&.any?
        openalex[:apc_prices].each do |apc|
          result[:alternatives] << { price: apc[:price], currency: apc[:currency], source: "OpenAlex" }
        end
      end

      # 添加美元估算
      result[:usd_estimate] = openalex[:apc_usd] if openalex[:apc_usd]

      result[:primary].nil? && result[:alternatives].empty? ? nil : result
    end
  end
end
