# frozen_string_literal: true

module DiscourseJournals
  # Shapes one raw `full=1` row from the upstream API into symbol-keyed hashes for
  # FieldNormalizer. Source keys track upstream contract v4: `scirev` and `letpub`
  # were retired, and `jufo` / `cwts` / `submission` / `comments` were added.
  class ApiDataTransformer
    def self.transform(row)
      row = row.is_a?(Hash) ? row : {}
      unified = row["unified"] || {}
      sources_raw = row["sources"] || {}

      {
        unified: symbolize_flat(unified),
        cover: symbolize_flat(row["cover"]),
        issn_details: normalize_array(row["issn_details"]),
        # Row-level summaries. Present on every row (list and detail alike), so
        # they are the cheap way to know a journal has submission material or
        # reader reviews without a second request.
        submission_summary: symbolize_flat(row["submission"]),
        comments_summary: symbolize_flat(row["comments"]),
        # `partial: true` means an optional source query failed for this row —
        # a missing source key then does NOT mean "no data for this journal".
        partial: row["partial"] ? true : false,
        degraded_sources: normalize_array(row["degraded_sources"]),
        sources: {
          crossref: transform_crossref(sources_raw["crossref"]),
          openalex: transform_openalex(sources_raw["openalex"]),
          doaj: transform_doaj(sources_raw["doaj"]),
          wikidata: transform_wikidata(sources_raw["wikidata"]),
          scimago: transform_with_history(sources_raw["scimago"]),
          jcr: transform_with_history(sources_raw["jcr"]),
          fqb: transform_with_history(sources_raw["fqb"]),
          gjqk: transform_with_history(sources_raw["gjqk"]),
          xr: transform_with_history(sources_raw["xr"]),
          ccf: transform_with_history(sources_raw["ccf"]),
          cwts: transform_with_history(sources_raw["cwts"]),
          jufo: transform_jufo(sources_raw["jufo"]),
          submission: transform_submission(sources_raw["submission"]),
          comments: transform_comments(sources_raw["comments"]),
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
          concepts: normalize_array(raw["concepts"]),
          counts_by_year: normalize_array(raw["counts_by_year"]),
          apc_prices: normalize_array(raw["apc_prices"]),
          apc_usd_by_year: normalize_array(raw["apc_usd_by_year"]),
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
          external_ids: normalize_array(raw["external_ids"]),
          aliases: normalize_array(raw["aliases"]),
        }
      end

      def transform_with_history(raw)
        return nil if raw.blank?
        {
          main: symbolize_flat(raw["main"]),
          all_years: normalize_array(raw["all_years"]),
        }
      end

      # JUFO's per-year list is `levels`, not `all_years` — the one source that
      # breaks the convention.
      def transform_jufo(raw)
        return nil if raw.blank?
        {
          main: symbolize_flat(raw["main"]),
          levels: normalize_array(raw["levels"]),
        }
      end

      def transform_submission(raw)
        return nil if raw.blank?
        {
          main: symbolize_flat(raw["main"]),
          latex: symbolize_flat(raw["latex"]),
          guide_master: symbolize_flat(raw["guide_master"]),
          fields_json: deep_symbolize(raw["fields_json"]),
        }
      end

      # `comments` is a flat aggregate object with no `main` wrapper.
      def transform_comments(raw)
        return nil if raw.blank?
        aggregate = symbolize_flat(raw)
        aggregate[:recent] = normalize_array(raw["recent"])
        aggregate[:status_counts] = symbolize_flat(raw["status_counts"])
        aggregate[:tag_counts] = symbolize_flat(raw["tag_counts"])
        aggregate[:top_positive_tags] = normalize_array(raw["top_positive_tags"])
        aggregate[:top_negative_tags] = normalize_array(raw["top_negative_tags"])
        aggregate
      end

      def deep_symbolize(value)
        case value
        when Hash
          value.each_with_object({}) { |(k, v), memo| memo[k.to_sym] = deep_symbolize(v) }
        when Array
          value.map { |v| deep_symbolize(v) }
        else
          value
        end
      end
    end
  end
end
