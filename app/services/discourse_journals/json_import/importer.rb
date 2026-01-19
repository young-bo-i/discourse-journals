# frozen_string_literal: true

module DiscourseJournals
  module JsonImport
    class Importer
      attr_reader :processed_rows, :created_topics, :updated_topics, :skipped_rows, :errors

      def initialize(file_path:, system_user: Discourse.system_user, progress_callback: nil)
        @file_path = file_path
        @system_user = system_user
        @progress_callback = progress_callback
        @processed_rows = 0
        @created_topics = 0
        @updated_topics = 0
        @skipped_rows = 0
        @errors = []
      end

      def import!
        data = parse_json_file
        return unless data

        total = data.is_a?(Array) ? data.size : 1
        report_progress(0, total, "准备导入 #{total} 个期刊...")

        if data.is_a?(Array)
          data.each_with_index do |journal, index|
            process_journal(journal, index)
            
            # 每处理 10 个或最后一个时报告进度
            if (index + 1) % 10 == 0 || index == total - 1
              report_progress(
                index + 1,
                total,
                "已处理 #{index + 1}/#{total} (#{@created_topics} 新建, #{@updated_topics} 更新, #{@errors.size} 错误)"
              )
            end
          end
        elsif data.is_a?(Hash)
          process_journal(data, 0)
          report_progress(1, 1, "处理完成")
        else
          @errors << { message: "Invalid JSON format: expected Array or Hash", details: nil }
        end
      rescue StandardError => e
        @errors << { message: "Import failed: #{e.message}", details: e.backtrace&.first(5)&.join("\n") }
      end

      private

      attr_reader :file_path, :system_user

      def report_progress(current, total, message)
        @progress_callback&.call(current, total, message)
      end

      def parse_json_file
        content = File.read(file_path)
        JSON.parse(content)
      rescue JSON::ParserError => e
        @errors << { message: "JSON parse error: #{e.message}", details: nil }
        nil
      rescue StandardError => e
        @errors << { message: "File read error: #{e.message}", details: e.backtrace&.first(3)&.join("\n") }
        nil
      end

      def process_journal(journal, index)
        @processed_rows += 1

        primary_issn = journal["primary_issn"]
        if primary_issn.blank?
          @skipped_rows += 1
          @errors << { message: "Row #{index + 1}: Missing primary_issn", details: nil }
          return
        end

        unified_index = journal["unified_index"] || {}
        title = unified_index["title"]
        if title.blank?
          @skipped_rows += 1
          @errors << { message: "Row #{index + 1}: Missing title in unified_index", details: nil }
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
        error_msg = "Row #{index + 1} (ISSN: #{primary_issn}): #{e.message}"
        @errors << { 
          message: error_msg, 
          details: "Title: #{title}\n#{e.backtrace&.first(5)&.join("\n")}"
        }
        @skipped_rows += 1
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
