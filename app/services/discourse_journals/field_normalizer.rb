# frozen_string_literal: true

module DiscourseJournals
  class FieldNormalizer
    def initialize(journal_data)
      @data = journal_data.is_a?(Hash) ? journal_data.deep_symbolize_keys : {}
      @unified = @data[:unified] || {}
      @sources = @data[:sources] || {}
      @cover = @data[:cover] || {}
      @issn_details = @data[:issn_details] || []
      @submission_summary = @data[:submission_summary] || {}
      @comments_summary = @data[:comments_summary] || {}
    end

    def normalize
      {
        identity: build_identity,
        publication: build_publication,
        metrics: build_metrics,
        jcr: build_jcr,
        scimago: build_scimago,
        cas_partition: build_cas,
        xinrui_partition: build_xinrui,
        warning: build_warning,
        open_access: build_open_access,
        subjects_topics: build_subjects,
        crossref_quality: build_crossref,
        reviews: build_reviews,
        ccf: build_ccf,
        cwts: build_cwts,
        jufo: build_jufo,
        submission: build_submission,
        wikidata_meta: build_wikidata_meta,
        preservation: build_preservation,
        provenance: build_provenance,
      }
    end

    private

    attr_reader :data, :unified, :sources, :cover, :issn_details,
                :submission_summary, :comments_summary

    def oa_main
      @_oa_main ||= sources.dig(:openalex, :main) || {}
    end

    def wd_main
      @_wd_main ||= sources.dig(:wikidata, :main) || {}
    end

    def doaj_main
      @_doaj_main ||= sources.dig(:doaj, :main) || {}
    end

    def scimago_main
      @_scimago_main ||= sources.dig(:scimago, :main) || {}
    end

    def jcr_main
      @_jcr_main ||= sources.dig(:jcr, :main) || {}
    end

    def fqb_main
      @_fqb_main ||= sources.dig(:fqb, :main) || {}
    end

    def cwts_main
      @_cwts_main ||= sources.dig(:cwts, :main) || {}
    end

    def build_identity
      abbreviation = wd_main[:iso4_abbreviation] ||
        wd_main[:short_name] ||
        sources.dig(:openalex, :alternate_titles)&.first&.dig(:title)

      {
        # The upstream row id. JournalUpserter persists it as
        # discourse_journals_api_id, which is TitleMatcher's second matching key —
        # it used to read a :unified key that normalize() never produced, so the
        # field was never written and the api_id match phase never fired.
        api_id: unified[:id],
        title: unified[:canonical_name],
        abbreviation: abbreviation,
        issn_l: unified[:issn_l],
        print_issn: unified[:print_issn],
        electronic_issn: unified[:electronic_issn],
        issn_details: issn_details,
        alternate_titles: extract_alternate_titles,
        aliases: extract_aliases,
        external_ids: extract_external_ids,
        openalex_id: unified[:openalex_id],
        openalex_type: unified[:openalex_type] || oa_main[:type],
        wikidata_qid: unified[:wikidata_qid],
        cover_url: cover[:cover_url],
        cover_original_url: cover[:original_url],
        homepage_url: oa_main[:homepage_url] || extract_wikidata_homepage,
      }
    end

    def build_publication
      {
        publisher_name: unified[:crossref_publisher] || unified[:doaj_publisher] || oa_main[:host_organization_name],
        publisher_id: oa_main[:host_organization],
        country_code: unified[:openalex_country] || unified[:doaj_country] || oa_main[:country_code],
        country_name: unified[:wikidata_country] || unified[:scimago_country] || wd_main[:country_label],
        first_publication_year: oa_main[:first_publication_year],
        last_publication_year: oa_main[:last_publication_year],
        is_core: oa_main[:is_core],
        is_preprint_repository: to_bool(oa_main[:is_preprint_repository]),
      }
    end

    def build_metrics
      counts_by_year = sources.dig(:openalex, :counts_by_year) || []
      sorted_counts = counts_by_year
        .select { |c| c[:year] && c[:works_count] }
        .sort_by { |c| -c[:year] }

      {
        works_count: unified[:openalex_works_count] || oa_main[:works_count],
        oa_works_count: oa_main[:oa_works_count],
        cited_by_count: unified[:openalex_cited_by_count] || oa_main[:cited_by_count],
        h_index: unified[:openalex_h_index] || oa_main[:summary_stats_h_index],
        i10_index: unified[:openalex_i10_index] || oa_main[:summary_stats_i10_index],
        two_year_mean_citedness: unified[:openalex_2yr_mean_citedness] || oa_main[:summary_stats_2yr_mean_citedness],
        snip: unified[:cwts_snip] || cwts_main[:snip],
        ipp: unified[:cwts_ipp] || cwts_main[:ipp],
        self_citation_pct: unified[:cwts_self_cit_pct] || cwts_main[:self_cit_pct],
        cwts_year: unified[:cwts_year] || cwts_main[:year],
        apc_usd: oa_main[:apc_usd],
        counts_by_year: sorted_counts.first(15).map { |c|
          {
            year: c[:year],
            works_count: c[:works_count].to_i,
            oa_works_count: c[:oa_works_count].to_i,
            cited_by_count: c[:cited_by_count].to_i,
          }
        },
      }
    end

    def build_jcr
      main = jcr_main
      all_years = sources.dig(:jcr, :all_years) || []
      return nil if main.empty? && all_years.empty?

      years = all_years.any? ? all_years : [main]
      {
        data: years
          .select { |y| y[:year] }
          .sort_by { |y| -y[:year].to_i }
          .map { |y|
            {
              year: y[:year],
              impact_factor: y[:impact_factor],
              quartile: y[:if_quartile],
              rank: y[:if_rank],
              category: y[:category],
            }
          },
      }
    end

    def build_scimago
      main = scimago_main
      all_years = sources.dig(:scimago, :all_years) || []
      return nil if main.empty? && all_years.empty?

      years = all_years.any? ? all_years : [main]
      {
        data: years
          .select { |y| y[:year] }
          .sort_by { |y| -y[:year].to_i }
          .map { |y|
            {
              year: y[:year],
              sjr: parse_decimal(y[:sjr]),
              best_quartile: y[:sjr_best_quartile],
              h_index: y[:h_index],
              total_docs_year: y[:total_docs_year],
              total_docs_3years: y[:total_docs_3years],
              total_refs: y[:total_refs],
              total_citations_3years: y[:total_citations_3years],
              citable_docs_3years: y[:citable_docs_3years],
              citations_per_doc_2years: parse_decimal(y[:citations_per_doc_2years]),
              ref_per_doc: parse_decimal(y[:ref_per_doc]),
              female_pct: parse_decimal(y[:female_pct]),
              overton: y[:overton],
              sdg: y[:sdg],
              categories: y[:categories],
            }
          },
      }
    end

    def build_cas
      main = fqb_main
      all_years = sources.dig(:fqb, :all_years) || []
      return nil if main.empty? && all_years.empty?

      years = all_years.any? ? all_years : [main]
      {
        data: years
          .select { |y| y[:year] }
          .sort_by { |y| -y[:year].to_i }
          .map { |y|
            minor_cats = (1..6).filter_map { |i|
              cat = y[:"subcategory_#{i}"]
              next unless cat.present?
              { category: cat, quartile: y[:"subcategory_#{i}_quartile"] }
            }
            {
              year: y[:year],
              major_category: y[:major_category],
              major_quartile: y[:major_quartile],
              top: y[:top],
              web_of_science: y[:web_of_science],
              open_access: y[:open_access],
              minor_categories: minor_cats,
            }
          },
      }
    end

    def build_xinrui
      main = sources.dig(:xr, :main) || {}
      all_years = sources.dig(:xr, :all_years) || []
      return nil if main.empty? && all_years.empty?

      years = all_years.any? ? all_years : [main]
      {
        data: years
          .select { |y| y[:year] }
          .sort_by { |y| -y[:year].to_i }
          .map { |y|
            minor_cats = (1..6).filter_map { |i|
              cat = y[:"subcategory_#{i}"]
              next unless cat.present?
              {
                category: cat,
                category_cn: y[:"subcategory_#{i}_cn"],
                quartile: y[:"subcategory_#{i}_quartile"],
              }
            }
            {
              year: y[:year],
              major_category: y[:major_category],
              major_category_cn: y[:major_category_cn],
              major_quartile: y[:major_quartile],
              top: y[:top],
              major_category2: y[:major_category2],
              major_category2_cn: y[:major_category2_cn],
              major_quartile2: y[:major_quartile2],
              top2: y[:top2],
              database_src: y[:database_src],
              minor_categories: minor_cats,
            }
          },
      }
    end

    def build_warning
      main = sources.dig(:gjqk, :main) || {}
      all_years = sources.dig(:gjqk, :all_years) || []
      return nil if main.empty? && all_years.empty?

      years = all_years.any? ? all_years : [main]
      {
        data: years
          .select { |y| y[:year] }
          .sort_by { |y| -y[:year].to_i }
          .map { |y|
            {
              year: y[:year],
              level: y[:warning_level],
              reason: y[:warning_reason],
            }
          },
      }
    end

    def build_open_access
      diamond_oa = to_bool(scimago_main[:open_access_diamond])
      {
        is_oa: to_bool(unified[:openalex_is_oa]) || to_bool(oa_main[:is_oa]),
        is_in_doaj: to_bool(unified[:doaj_is_in_doaj]) || to_bool(oa_main[:is_in_doaj]),
        has_apc: to_bool(unified[:doaj_has_apc]) || to_bool(doaj_main[:apc_has_apc]),
        diamond_oa: diamond_oa,
        boai: to_bool(doaj_main[:boai]),
        copyright_author_retains: to_bool(doaj_main[:copyright_author_retains]),
        plagiarism_detection: to_bool(doaj_main[:plagiarism_detection]),
        has_preservation: to_bool(doaj_main[:preservation_has_preservation]),
        has_deposit_policy: to_bool(doaj_main[:deposit_policy_has_policy]),
        has_waiver: to_bool(doaj_main[:waiver_has_waiver]),
        has_other_charges: to_bool(doaj_main[:other_charges_has_other_charges]),
        publication_time_weeks: doaj_main[:publication_time_weeks],
        apc_usd: oa_main[:apc_usd],
        apc_prices: sources.dig(:openalex, :apc_prices) || [],
        apc_usd_by_year: build_apc_history,
        doaj_apc_max: sources.dig(:doaj, :apc_max) || [],
        licenses: sources.dig(:doaj, :licenses) || [],
        cas_review: fqb_main[:review],
        cas_oaj: fqb_main[:oaj],
        cas_top: fqb_main[:top],
      }
    end

    def build_subjects
      oa_topics = sources.dig(:openalex, :topics) || []
      oa_topic_shares = sources.dig(:openalex, :topic_shares) || []
      doaj_keywords = sources.dig(:doaj, :keywords) || []
      doaj_subjects = sources.dig(:doaj, :subjects) || []

      {
        topics: oa_topics
          .select { |t| t[:display_name] }
          .first(8)
          .map { |t|
            {
              name: t[:display_name],
              count: t[:count],
              score: t[:score],
              field: t[:field_display_name],
              domain: t[:domain_display_name],
            }
          },
        topic_shares: oa_topic_shares
          .select { |ts| ts[:display_name] && ts[:value] }
          .first(8)
          .map { |ts|
            {
              name: ts[:display_name],
              value: ts[:value].to_f,
              field: ts[:field_display_name],
              domain: ts[:domain_display_name],
            }
          },
        keywords: doaj_keywords.map { |k| k[:keyword] }.compact,
        subjects: doaj_subjects.map { |s| s[:term] || s[:code] }.compact,
      }
    end

    def build_crossref
      cr = sources[:crossref]
      return nil unless cr

      main = cr[:main] || {}
      dois_by_year = (cr[:dois_by_year] || [])
        .select { |d| d[:year] && d[:count] }
        .sort_by { |d| -d[:year].to_i }
        .first(15)
        .map { |d| { year: d[:year], count: d[:count].to_i } }

      coverage = (cr[:coverage_types] || []).find { |c| c[:type_name] == "all" }

      {
        total_dois: main[:counts_total_dois],
        current_dois: main[:counts_current_dois],
        dois_by_year: dois_by_year,
        coverage: coverage ? extract_coverage(coverage) : nil,
      }
    end

    # Real submission experiences reported by authors. Replaces the retired
    # `scirev` source: same intent, far more detail (per-dimension 0-5 scores,
    # outcome rates, handling times, sentiment tags).
    #
    # Only the aggregate is normalised. The individual comments (`recent`) are
    # deliberately left out of the stored JSON: 20 comment bodies per topic would
    # multiply discourse_journals_data's size across ~280k rows, and they belong
    # in the separate comment-sync pipeline (docs/comments-sync-plan.md).
    def build_reviews
      agg = sources[:comments] || {}
      summary = comments_summary

      count = agg[:comment_count] || summary[:count]
      return nil if count.nil? || count.to_i.zero?

      {
        count: count.to_i,
        source_count: agg[:source_count],
        latest_at: agg[:latest_comment_at] || summary[:latest_at],
        rating: parse_decimal(agg[:journal_rating_0_5] || summary[:rating]),
        raw_rating: parse_decimal(agg[:raw_rating_0_5]),
        rating_confidence: agg[:rating_confidence] || summary[:rating_confidence],
        difficulty: parse_decimal(agg[:difficulty_index_0_5] || summary[:difficulty_index]),
        quality: parse_decimal(agg[:quality_index_0_5]),
        speed: parse_decimal(agg[:speed_index_0_5] || summary[:speed_index]),
        communication: parse_decimal(agg[:communication_index_0_5]),
        cost: parse_decimal(agg[:cost_index_0_5]),
        acceptance_rate: parse_decimal(agg[:acceptance_reported_rate]),
        rejection_rate: parse_decimal(agg[:rejection_reported_rate]),
        desk_reject_rate: parse_decimal(agg[:desk_reject_rate]),
        revision_rate: parse_decimal(agg[:revision_rate]),
        avg_first_review_days: parse_decimal(agg[:avg_first_review_days]),
        median_first_review_days: parse_decimal(agg[:median_first_review_days]),
        avg_total_handling_days: parse_decimal(agg[:avg_total_handling_days]),
        median_total_handling_days: parse_decimal(agg[:median_total_handling_days]),
        avg_review_rounds: parse_decimal(agg[:avg_review_rounds]),
        positive_tags: (agg[:top_positive_tags] || []).compact.first(5),
        negative_tags: (agg[:top_negative_tags] || []).compact.first(5),
        status_counts: agg[:status_counts] || {},
      }
    end

    # CWTS SNIP (field-normalised impact) and IPP, latest year plus history.
    def build_cwts
      main = cwts_main
      all_years = sources.dig(:cwts, :all_years) || []
      return nil if main.empty? && all_years.empty?

      years = all_years.any? ? all_years : [main]
      {
        # Capped: the SNIP trend chart and its 8-row table never read past this,
        # and every extra year is stored on ~280k topics.
        data: years
          .select { |y| y[:year] }
          .sort_by { |y| -y[:year].to_i }
          .first(15)
          .map { |y|
            {
              year: y[:year],
              snip: parse_decimal(y[:snip]),
              ipp: parse_decimal(y[:ipp]),
              self_cit_pct: parse_decimal(y[:self_cit_pct]),
              docs: y[:p],
            }
          },
      }
    end

    # JUFO — the Finnish/Norwegian/Danish publication-channel rankings.
    def build_jufo
      main = sources.dig(:jufo, :main) || {}
      levels = sources.dig(:jufo, :levels) || []
      return nil if main.empty? && levels.empty?

      {
        level_fi: unified[:jufo_level_fi] || main[:level_fi],
        level_no: unified[:jufo_level_no] || main[:level_no],
        level_dk: unified[:jufo_level_dk] || main[:level_dk],
        channel_type: main[:channel_type],
        oa_type: main[:oa_type],
        self_archiving: main[:self_archiving],
        active: main[:active],
        year_start: main[:year_start],
        year_end: main[:year_end],
        levels: levels
          .select { |l| l[:year] }
          .sort_by { |l| -l[:year].to_i }
          .first(15)
          .map { |l| { year: l[:year], level: l[:level] } },
      }
    end

    # Submission guidelines / LaTeX template: existence, download paths and the
    # structured requirements upstream extracted from the guide.
    def build_submission
      summary = submission_summary
      main = sources.dig(:submission, :main) || {}
      latex = sources.dig(:submission, :latex) || {}
      fields = sources.dig(:submission, :fields_json) || {}

      has_guideline = to_bool(summary[:has_guideline]) || to_bool(main[:has_guideline])
      has_latex = to_bool(summary[:has_latex]) || to_bool(main[:has_latex])
      return nil unless has_guideline || has_latex

      {
        has_guideline: has_guideline,
        has_latex: has_latex,
        latex_class: summary[:latex_class] || latex[:class],
        latex_zip: latex[:master_zip],
        word_limit: main[:word_limit] || fields[:word_limit],
        page_limit: main[:page_limit] || fields[:page_limit],
        peer_review_model: main[:peer_review_model] || fields.dig(:peer_review, :model),
        reference_style: main[:reference_style_list] || fields.dig(:reference_style, :list),
        reference_intext: fields.dig(:reference_style, :intext),
        abstract_word_limit: fields.dig(:abstract, :word_limit),
        keywords_min: fields.dig(:keywords, :min),
        keywords_max: fields.dig(:keywords, :max),
        article_types: Array(fields[:article_types]).compact.first(12),
        file_formats: Array(fields.dig(:submission, :file_formats)).compact,
        figure_formats: Array(fields.dig(:figures, :formats)).compact,
        submission_system_url: fields.dig(:submission, :system_url),
        ai_disclosure_required: to_bool(fields.dig(:ethics, :ai_disclosure_required)),
        oa_licenses: Array(fields.dig(:open_access, :licenses)).compact,
        capture_quality: main[:capture_quality] || fields[:capture_quality],
      }
    end

    # Which upstream sources actually backed this record, and whether the row we
    # rendered from was complete. `partial` matters downstream: a missing source
    # on a partial row means "the query failed", not "this journal has no data".
    def build_provenance
      source_list = unified[:sources].to_s.split(",").map(&:strip).reject(&:blank?)

      {
        source_count: unified[:source_count],
        sources: source_list,
        built_at: unified[:built_at],
        partial: data[:partial] ? true : false,
        degraded_sources: data[:degraded_sources] || [],
      }
    end

    def build_ccf
      ccf = sources.dig(:ccf, :main) || {}
      return nil if ccf.empty?

      {
        rank: ccf[:ccf_rank],
        field: ccf[:field],
        category: ccf[:ccf_category],
        abbreviation: ccf[:abbreviation],
        source_type: ccf[:source_type],
      }
    end

    def build_wikidata_meta
      wd = wd_main
      return nil if wd.empty?

      indexed_in = (sources.dig(:wikidata, :indexed_in) || []).filter_map { |db|
        db[:database_label] if db[:database_label]
      }
      editors = (sources.dig(:wikidata, :editors) || []).filter_map { |e|
        e[:editor_label] || e[:label]
      }
      languages = (sources.dig(:wikidata, :languages) || []).filter_map { |l|
        l[:language_label] || l[:label]
      }

      {
        description_en: wd[:description_en],
        description_zh: wd[:description_zh],
        inception: wd[:inception],
        frequency: wd[:frequency_label],
        coden: wd[:coden],
        indexed_in: indexed_in,
        editors: editors,
        languages: languages,
      }
    end

    def build_preservation
      preservation_services = (sources.dig(:doaj, :preservation_services) || []).filter_map { |ps|
        ps[:service_name]
      }
      deposit_services = (sources.dig(:doaj, :deposit_policy_services) || []).filter_map { |ds|
        ds[:service_name]
      }
      return nil if preservation_services.empty? && deposit_services.empty?

      {
        preservation_services: preservation_services,
        deposit_services: deposit_services,
      }
    end

    def extract_alternate_titles
      titles = []
      oa_alts = sources.dig(:openalex, :alternate_titles) || []
      oa_alts.each { |a| titles << (a.is_a?(Hash) ? a[:title] : a.to_s) }

      wd_titles = sources.dig(:wikidata, :titles) || []
      wd_titles.each { |t| titles << t[:title] if t[:title] }

      titles.compact.uniq.first(5)
    end

    # Wikidata multilingual aliases, deduped and capped — useful for search recall
    # on Chinese/other-script journal names.
    def extract_aliases
      (sources.dig(:wikidata, :aliases) || [])
        .filter_map { |a| a[:alias].presence }
        .uniq
        .first(8)
    end

    # Stable identifiers on external platforms (Scopus, NLM, VIAF, JUFO, …).
    def extract_external_ids
      (sources.dig(:wikidata, :external_ids) || [])
        .filter_map { |e|
          next if e[:property].blank? || e[:identifier].blank?
          { property: e[:property], identifier: e[:identifier] }
        }
        .uniq
        .first(12)
    end

    def build_apc_history
      (sources.dig(:openalex, :apc_usd_by_year) || [])
        .select { |a| a[:year] && a[:price] }
        .sort_by { |a| -a[:year].to_i }
        .first(10)
        .map { |a| { year: a[:year], price: a[:price].to_i } }
    end

    def extract_wikidata_homepage
      websites = sources.dig(:wikidata, :websites) || []
      websites.first&.dig(:url)
    end

    def extract_coverage(cov)
      %i[abstracts references orcids funders licenses affiliations].filter_map { |key|
        val = cov[key]
        next unless val.is_a?(Numeric) && val > 0
        [key, (val * 100).round(0)]
      }.to_h
    end

    def parse_decimal(val)
      return nil if val.nil?
      val.to_s.tr(",", ".").to_f
    end

    def to_bool(val)
      return nil if val.nil?
      val == true || val == 1 || val == "1"
    end
  end
end
