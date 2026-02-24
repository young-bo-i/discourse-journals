# frozen_string_literal: true

module DiscourseJournals
  class FieldNormalizer
    def initialize(journal_data)
      @data = journal_data.is_a?(Hash) ? journal_data.deep_symbolize_keys : {}
      @unified = @data[:unified] || {}
      @sources = @data[:sources] || {}
      @cover = @data[:cover] || {}
      @issn_details = @data[:issn_details] || []
    end

    def normalize
      {
        identity: build_identity,
        publication: build_publication,
        metrics: build_metrics,
        jcr: build_jcr,
        scimago: build_scimago,
        cas_partition: build_cas,
        warning: build_warning,
        open_access: build_open_access,
        subjects_topics: build_subjects,
        crossref_quality: build_crossref,
      }
    end

    private

    attr_reader :data, :unified, :sources, :cover, :issn_details

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

    def build_identity
      abbreviation = wd_main[:iso4_abbreviation] ||
        wd_main[:short_name] ||
        sources.dig(:openalex, :alternate_titles)&.first&.dig(:title)

      {
        title: unified[:canonical_name],
        abbreviation: abbreviation,
        issn_l: unified[:issn_l],
        issn_details: issn_details,
        alternate_titles: extract_alternate_titles,
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
      {
        is_oa: to_bool(unified[:openalex_is_oa]) || to_bool(oa_main[:is_oa]),
        is_in_doaj: to_bool(unified[:doaj_is_in_doaj]) || to_bool(oa_main[:is_in_doaj]),
        has_apc: to_bool(unified[:doaj_has_apc]) || to_bool(doaj_main[:apc_has_apc]),
        apc_usd: oa_main[:apc_usd],
        apc_prices: sources.dig(:openalex, :apc_prices) || [],
        doaj_apc_max: sources.dig(:doaj, :apc_max) || [],
        licenses: sources.dig(:doaj, :licenses) || [],
      }
    end

    def build_subjects
      oa_topics = sources.dig(:openalex, :topics) || []
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

    def extract_alternate_titles
      titles = []
      oa_alts = sources.dig(:openalex, :alternate_titles) || []
      oa_alts.each { |a| titles << (a.is_a?(Hash) ? a[:title] : a.to_s) }

      wd_titles = sources.dig(:wikidata, :titles) || []
      wd_titles.each { |t| titles << t[:title] if t[:title] }

      titles.compact.uniq.first(5)
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
