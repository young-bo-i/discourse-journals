# frozen_string_literal: true

module DiscourseJournals
  class ApiDataTransformer
    def self.transform(row)
      row = row.is_a?(Hash) ? row : {}
      unified = row["unified"] || {}
      sources_raw = row["sources"] || {}

      {
        unified: symbolize_flat(unified),
        cover: symbolize_flat(row["cover"]),
        issn_details: normalize_array(row["issn_details"]),
        sources: {
          crossref: transform_crossref(sources_raw["crossref"]),
          openalex: transform_openalex(sources_raw["openalex"]),
          doaj: transform_doaj(sources_raw["doaj"]),
          wikidata: transform_wikidata(sources_raw["wikidata"]),
          scimago: transform_with_history(sources_raw["scimago"]),
          jcr: transform_with_history(sources_raw["jcr"]),
          fqb: transform_with_history(sources_raw["fqb"]),
          gjqk: transform_with_history(sources_raw["gjqk"]),
          scirev: transform_scirev(sources_raw["scirev"]),
          letpub: transform_simple(sources_raw["letpub"]),
          ccf: transform_simple(sources_raw["ccf"]),
        },
      }
    end

    class << self
      private

      def symbolize_flat(hash)
        return {} if hash.nil? || !hash.is_a?(Hash)
        hash.transform_keys(&:to_sym)
      end

      def normalize_array(arr)
        return [] unless arr.is_a?(Array)
        arr.map { |item| item.is_a?(Hash) ? item.transform_keys(&:to_sym) : item }
      end

      def transform_crossref(raw)
        return nil if raw.blank?
        {
          main: symbolize_flat(raw["main"]),
          issns: normalize_array(raw["issns"]),
          subjects: normalize_array(raw["subjects"]),
          dois_by_year: normalize_array(raw["dois_by_year"]),
          coverage_types: normalize_array(raw["coverage_types"]),
        }
      end

      def transform_openalex(raw)
        return nil if raw.blank?
        {
          main: symbolize_flat(raw["main"]),
          issns: normalize_array(raw["issns"]),
          alternate_titles: normalize_array(raw["alternate_titles"]),
          topics: normalize_array(raw["topics"]),
          topic_shares: normalize_array(raw["topic_shares"]),
          counts_by_year: normalize_array(raw["counts_by_year"]),
          apc_prices: normalize_array(raw["apc_prices"]),
          host_org_lineage: normalize_array(raw["host_org_lineage"]),
          societies: normalize_array(raw["societies"]),
        }
      end

      def transform_doaj(raw)
        return nil if raw.blank?
        {
          main: symbolize_flat(raw["main"]),
          keywords: normalize_array(raw["keywords"]),
          subjects: normalize_array(raw["subjects"]),
          languages: normalize_array(raw["languages"]),
          licenses: normalize_array(raw["licenses"]),
          apc_max: normalize_array(raw["apc_max"]),
          editorial_review_processes: normalize_array(raw["editorial_review_processes"]),
          preservation_services: normalize_array(raw["preservation_services"]),
          preservation_national_libraries: normalize_array(raw["preservation_national_libraries"]),
          deposit_policy_services: normalize_array(raw["deposit_policy_services"]),
          pid_schemes: normalize_array(raw["pid_schemes"]),
        }
      end

      def transform_wikidata(raw)
        return nil if raw.blank?
        {
          main: symbolize_flat(raw["main"]),
          types: normalize_array(raw["types"]),
          titles: normalize_array(raw["titles"]),
          issns: normalize_array(raw["issns"]),
          websites: normalize_array(raw["websites"]),
          languages: normalize_array(raw["languages"]),
          publishers: normalize_array(raw["publishers"]),
          subjects: normalize_array(raw["subjects"]),
          indexed_in: normalize_array(raw["indexed_in"]),
        }
      end

      def transform_with_history(raw)
        return nil if raw.blank?
        {
          main: symbolize_flat(raw["main"]),
          all_years: normalize_array(raw["all_years"]),
        }
      end

      def transform_scirev(raw)
        return nil if raw.blank?
        {
          main: symbolize_flat(raw["main"]),
          reviews: normalize_array(raw["reviews"]),
        }
      end

      def transform_simple(raw)
        return nil if raw.blank?
        { main: symbolize_flat(raw.is_a?(Hash) && raw.key?("main") ? raw["main"] : raw) }
      end
    end
  end
end
