# frozen_string_literal: true

module DiscourseJournals
  module Json
    class Importer
      attr_reader :processed_rows, :created_topics, :updated_topics, :skipped_rows, :errors

      def initialize(file_path:, system_user: Discourse.system_user)
        @file_path = file_path
        @system_user = system_user
        @processed_rows = 0
        @created_topics = 0
        @updated_topics = 0
        @skipped_rows = 0
        @errors = []
      end

      def import!
        data = parse_json_file
        return unless data

        if data.is_a?(Array)
          data.each_with_index { |journal, index| process_journal(journal, index) }
        elsif data.is_a?(Hash)
          process_journal(data, 0)
        else
          @errors << "Invalid JSON format: expected Array or Hash"
        end
      rescue StandardError => e
        @errors << "Import failed: #{e.message}"
      end

      private

      attr_reader :file_path, :system_user

      def parse_json_file
        content = File.read(file_path)
        JSON.parse(content)
      rescue JSON::ParserError => e
        @errors << "JSON parse error: #{e.message}"
        nil
      rescue StandardError => e
        @errors << "File read error: #{e.message}"
        nil
      end

      def process_journal(journal, index)
        @processed_rows += 1

        primary_issn = journal["primary_issn"]
        if primary_issn.blank?
          @skipped_rows += 1
          @errors << "Row #{index + 1}: Missing primary_issn"
          return
        end

        unified_index = journal["unified_index"] || {}
        title = unified_index["title"]
        if title.blank?
          @skipped_rows += 1
          @errors << "Row #{index + 1}: Missing title in unified_index"
          return
        end

        journal_data = {
          issn: primary_issn,
          name: title,
          unified_index: unified_index,
          aliases: journal["aliases"] || [],
          sources: extract_sources(journal["sources_by_provider"] || {})
        }

        upserter = JournalUpserter.new(system_user: system_user)
        result = upserter.upsert!(journal_data)

        case result
        when :created
          @created_topics += 1
        when :updated
          @updated_topics += 1
        end
      rescue StandardError => e
        @errors << "Row #{index + 1} (ISSN: #{primary_issn}): #{e.message}"
      end

      def extract_sources(sources_by_provider)
        {
          crossref: sources_by_provider.dig("crossref", "data"),
          doaj: sources_by_provider.dig("doaj", "data"),
          nlm: sources_by_provider.dig("nlm", "data"),
          openalex: sources_by_provider.dig("openalex", "data"),
          wikidata: sources_by_provider.dig("wikidata", "data")
        }
      end
    end
  end
end
