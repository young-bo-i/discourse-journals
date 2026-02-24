# frozen_string_literal: true

module DiscourseJournals
  class ApiDataTransformer
    def self.transform(row)
      unified = row["unified"] || {}
      sources_raw = row["sources"] || {}

      {
        primary_id: unified["issn_l"],
        name: unified["canonical_name"],
        unified_index: build_unified_index(unified, row),
        aliases: [],
        sources: transform_sources(sources_raw),
        jcr: transform_jcr(sources_raw["jcr"]),
        cas_partition: transform_fqb(sources_raw["fqb"]),
      }
    end

    class << self
      private

      def build_unified_index(unified, row)
        {
          title: unified["canonical_name"],
          issn_l: unified["issn_l"],
          publisher: unified["crossref_publisher"],
          country: unified["openalex_country"],
          works_count: unified["openalex_works_count"],
          cited_by_count: unified["openalex_cited_by_count"],
          homepage: nil,
          issn_info: build_issn_info(unified, row["issn_details"]),
        }
      end

      def build_issn_info(unified, issn_details)
        info = {
          issn_l: unified["issn_l"],
          issn: unified["print_issn"],
          eissn: unified["electronic_issn"],
        }

        if issn_details.is_a?(Array)
          info[:all_issns] = issn_details.map { |d| { issn: d["issn"], type: d["type"] } }
        end

        info
      end

      def transform_sources(sources_raw)
        {
          crossref: transform_crossref(sources_raw["crossref"]),
          openalex: transform_openalex(sources_raw["openalex"]),
          wikidata: transform_wikidata(sources_raw["wikidata"]),
          doaj: nil,
          nlm: nil,
          wikipedia: nil,
        }
      end

      def transform_openalex(oa_raw)
        return nil if oa_raw.blank?
        main = oa_raw["main"] || {}

        result = {
          id: main["id"],
          display_name: main["display_name"],
          issn_l: main["issn_l"],
          host_organization_name: main["host_organization_name"],
          country_code: main["country_code"],
          is_oa: main["is_oa"],
          is_in_doaj: main["is_in_doaj"],
          is_in_doaj_since_year: main["is_in_doaj_since_year"],
          homepage_url: main["homepage_url"],
          first_publication_year: main["first_publication_year"],
          works_count: main["works_count"],
          oa_works_count: main["oa_works_count"],
          cited_by_count: main["cited_by_count"],
          summary_stats: {
            h_index: main["summary_stats_h_index"],
            i10_index: main["summary_stats_i10_index"],
            "2yr_mean_citedness": main["summary_stats_2yr_mean_citedness"],
          },
          works_api_url: main["works_api_url"],
          apc_usd: main["apc_usd"],
          type: main["type"],
        }

        if oa_raw["alternate_titles"].is_a?(Array)
          result[:alternate_titles] = oa_raw["alternate_titles"].map { |a| a.is_a?(Hash) ? a["title"] : a }.compact
        end

        result[:topics] = oa_raw["topics"] if oa_raw["topics"].is_a?(Array)
        result[:topic_share] = oa_raw["topic_shares"] if oa_raw["topic_shares"].is_a?(Array)
        result[:counts_by_year] = oa_raw["counts_by_year"] if oa_raw["counts_by_year"].is_a?(Array)
        result[:apc_prices] = oa_raw["apc_prices"] if oa_raw["apc_prices"].is_a?(Array)

        if oa_raw["issns"].is_a?(Array)
          result[:issn] = oa_raw["issns"].map { |i| i.is_a?(Hash) ? i["issn"] : i }.compact
        end

        result[:ids] = { wikidata: main["ids_wikidata"] } if main["ids_wikidata"]

        result
      end

      def transform_crossref(cr_raw)
        return nil if cr_raw.blank?
        main = cr_raw["main"] || {}

        msg = {
          title: main["title"],
          publisher: main["publisher"],
          status: main["last_status_check_time"].present? ? "active" : nil,
          counts: {
            total_dois: main["counts_total_dois"],
            current_dois: main["counts_current_dois"],
            backfile_dois: main["counts_backfile_dois"],
          },
        }

        coverage = {}
        flags = {}
        main.each do |k, v|
          next if v.nil?
          if k.start_with?("coverage_")
            coverage[k.sub("coverage_", "")] = v
          elsif k.start_with?("flag_")
            flags[k.sub("flag_", "")] = v
          end
        end
        msg[:coverage] = coverage unless coverage.empty?
        msg[:flags] = flags unless flags.empty?

        if cr_raw["issns"].is_a?(Array)
          msg[:ISSN] = cr_raw["issns"].map { |i| i["issn"] }.compact
          msg[:"issn-type"] = cr_raw["issns"].map { |i| { value: i["issn"], type: i["type"] } }
        end

        msg[:subjects] = cr_raw["subjects"] if cr_raw["subjects"].is_a?(Array)

        if cr_raw["dois_by_year"].is_a?(Array)
          msg[:breakdowns] = { dois_by_issued_year: cr_raw["dois_by_year"] }
        end

        { message: msg }
      end

      def transform_wikidata(wd_raw)
        return nil if wd_raw.blank?
        main = wd_raw["main"] || {}

        binding_data = {
          item: { value: "http://www.wikidata.org/entity/#{main["qid"]}" },
        }

        websites = wd_raw["websites"]
        if websites.is_a?(Array) && websites.any?
          url = websites.first.is_a?(Hash) ? websites.first["url"] : websites.first
          binding_data[:officialWebsite] = { value: url } if url
        end

        { results: { bindings: [binding_data] } }
      end

      def transform_jcr(jcr_raw)
        return nil if jcr_raw.blank?
        main = jcr_raw["main"]
        return nil if main.blank?

        {
          total_years: 1,
          data: [
            {
              year: main["year"],
              journal: main["journal"],
              issn: main["issn"],
              eissn: main["eissn"],
              category: main["category"],
              impact_factor: main["impact_factor"],
              quartile: main["if_quartile"],
              rank: main["if_rank"],
            },
          ],
        }
      end

      def transform_fqb(fqb_raw)
        return nil if fqb_raw.blank?
        main = fqb_raw["main"]
        return nil if main.blank?

        minor_cats = []
        if main["subcategory_1"].present?
          minor_cats << {
            name: main["subcategory_1"],
            quartile: main["subcategory_1_quartile"],
          }
        end

        {
          total_years: 1,
          data: [
            {
              year: main["year"],
              journal: main["journal"],
              issn: main["issn"],
              review: main["review"],
              open_access: main["open_access"],
              web_of_science: main["web_of_science"],
              major_category: main["major_category"],
              major_partition: main["major_quartile"],
              is_top_journal: main["top"],
              minor_categories: minor_cats,
            },
          ],
        }
      end
    end
  end
end
