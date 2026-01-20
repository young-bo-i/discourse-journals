# frozen_string_literal: true

module DiscourseJournals
  module ApiSync
    class Importer
      attr_reader :processed_count, :created_count, :updated_count, :skipped_count, :errors

      def initialize(api_url:, filters: {}, progress_callback: nil)
        @api_url = api_url
        @filters = filters
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
        Rails.logger.info("[DiscourseJournals::ApiSync] Importing first page (#{page_size} items) with filters: #{@filters}")

        result = @client.fetch_page(page: 1, page_size: page_size, filters: @filters)
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
        Rails.logger.info("[DiscourseJournals::ApiSync] Importing all pages with filters: #{@filters}")

        # 先获取总数
        first_result = @client.fetch_page(page: 1, page_size: 1, filters: @filters)
        total = first_result.dig(:pagination, "total") || 0

        report_progress(0, total, "准备导入所有数据：共 #{total} 个期刊...")

        # 流式处理所有页
        @client.fetch_all_pages(page_size: page_size, filters: @filters) do |journal, index|
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
          skip_journal("缺少 primary_issn", nil, journal_data)
          return
        end

        unified_index = journal_data["unified_index"] || {}
        title = unified_index["title"]
        if title.blank?
          skip_journal("缺少 title 字段", primary_issn, journal_data)
          return
        end

        # 构建期刊参数
        journal_params = {
          issn: primary_issn,
          name: title,
          unified_index: unified_index,
          aliases: journal_data["aliases"] || [],
          sources: extract_sources(journal_data["sources_by_provider"] || {}),
          jcr: extract_jcr(journal_data["jcr"]),
          cas_partition: extract_cas_partition(journal_data["cas_partition"]),
        }

        # 尝试创建/更新帖子
        upserter = JournalUpserter.new(system_user: Discourse.system_user)
        result = upserter.upsert!(journal_params)

        case result
        when :created
          @created_count += 1
          Rails.logger.info("[DiscourseJournals::ApiSync] ✓ Created: #{title} (#{primary_issn})")
        when :updated
          @updated_count += 1
          Rails.logger.info("[DiscourseJournals::ApiSync] ✓ Updated: #{title} (#{primary_issn})")
        end
      rescue StandardError => e
        # 数据处理失败，跳过该期刊
        skip_journal(e.message, primary_issn, journal_data, e)
      end
      
      def skip_journal(reason, issn, journal_data, exception = nil)
        @skipped_count += 1
        
        issn_display = issn || journal_data["primary_issn"] || "Unknown"
        title_display = journal_data.dig("unified_index", "title") || journal_data["name"] || "Unknown"
        
        error_info = {
          issn: issn_display,
          title: title_display,
          reason: reason,
          timestamp: Time.now.iso8601
        }
        
        # 记录错误到日志
        Rails.logger.warn("[DiscourseJournals::ApiSync] ✗ Skipped: #{title_display} (#{issn_display})")
        Rails.logger.warn("[DiscourseJournals::ApiSync]   Reason: #{reason}")
        
        if exception
          error_info[:error_class] = exception.class.name
          error_info[:backtrace] = exception.backtrace&.first(3)
          Rails.logger.warn("[DiscourseJournals::ApiSync]   Error: #{exception.class} - #{exception.message}")
          Rails.logger.warn("[DiscourseJournals::ApiSync]   Backtrace:\n    #{exception.backtrace&.first(3)&.join("\n    ")}")
        end
        
        @errors << error_info
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

      def extract_jcr(jcr_data)
        return nil if jcr_data.blank?
        
        {
          total_years: jcr_data["total_years"],
          data: jcr_data["data"]
        }
      end

      def extract_cas_partition(cas_data)
        return nil if cas_data.blank?
        
        {
          total_years: cas_data["total_years"],
          data: cas_data["data"]
        }
      end

      def report_progress(current, total, message)
        @progress_callback&.call(current, total, message)
      end
    end
  end
end
