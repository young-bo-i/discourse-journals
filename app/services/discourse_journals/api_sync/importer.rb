# frozen_string_literal: true

module DiscourseJournals
  module ApiSync
    class Importer
      attr_reader :processed_count, :created_count, :updated_count, :skipped_count, :errors

      def initialize(api_url:, progress_callback: nil)
        @api_url = api_url
        @progress_callback = progress_callback
        @client = Client.new(api_url)
        @processed_count = 0
        @created_count = 0
        @updated_count = 0
        @skipped_count = 0
        @errors = []
      end

      # 导入第一页（测试用）
      def import_first_page!(page_size: 100)
        Rails.logger.info("[DiscourseJournals::ApiSync] Importing first page (#{page_size} items)")

        result = @client.fetch_page(page: 1, page_size: page_size)
        journals = result[:journals]
        total = journals.size

        report_progress(0, total, "开始导入第一页：#{total} 个期刊...")

        journals.each_with_index do |journal, index|
          process_journal(journal, index)
          report_progress(index + 1, total, "已处理 #{index + 1}/#{total}")
        end

        report_progress(total, total, "第一页导入完成！")
      end

      # 导入所有页
      def import_all_pages!(page_size: 100)
        Rails.logger.info("[DiscourseJournals::ApiSync] Importing all pages")

        # 先获取总数
        first_result = @client.fetch_page(page: 1, page_size: 1)
        total = first_result.dig(:pagination, "total") || 0

        report_progress(0, total, "准备导入所有数据：共 #{total} 个期刊...")

        # 流式处理所有页
        @client.fetch_all_pages(page_size: page_size) do |journal, index|
          process_journal(journal, index)

          # 每处理 100 个报告一次进度
          if (@processed_count % 100).zero?
            report_progress(
              @processed_count,
              total,
              "已处理 #{@processed_count}/#{total} (#{@created_count} 新建, #{@updated_count} 更新, #{@errors.size} 错误)"
            )
          end
        end

        report_progress(total, total, "全部导入完成！")
      end

      private

      def process_journal(journal_data, _index)
        @processed_count += 1

        primary_issn = journal_data["primary_issn"]
        if primary_issn.blank?
          @skipped_count += 1
          @errors << { message: "Missing primary_issn", details: nil }
          return
        end

        unified_index = journal_data["unified_index"] || {}
        title = unified_index["title"]
        if title.blank?
          @skipped_count += 1
          @errors << { message: "Missing title in unified_index for ISSN: #{primary_issn}", details: nil }
          return
        end

        journal_params = {
          issn: primary_issn,
          name: title,
          unified_index: unified_index,
          aliases: journal_data["aliases"] || [],
          sources: extract_sources(journal_data["sources_by_provider"] || {})
        }

        upserter = JournalUpserter.new(system_user: Discourse.system_user)
        result = upserter.upsert!(journal_params)

        case result
        when :created
          @created_count += 1
        when :updated
          @updated_count += 1
        end
      rescue StandardError => e
        error_msg = "Error processing ISSN #{primary_issn}: #{e.message}"
        Rails.logger.error("[DiscourseJournals::ApiSync] #{error_msg}")
        @errors << { message: error_msg, details: e.backtrace&.first(5)&.join("\n") }
        @skipped_count += 1
      end

      def extract_sources(sources_by_provider)
        {
          crossref: sources_by_provider["crossref"]&.dig("data"),
          doaj: sources_by_provider["doaj"]&.dig("data"),
          nlm: sources_by_provider["nlm"]&.dig("data"),
          openalex: sources_by_provider["openalex"]&.dig("data"),
          wikidata: sources_by_provider["wikidata"]&.dig("data")
        }
      end

      def report_progress(current, total, message)
        @progress_callback&.call(current, total, message)
      end
    end
  end
end
