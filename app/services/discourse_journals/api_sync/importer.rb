# frozen_string_literal: true

module DiscourseJournals
  module ApiSync
    class Importer
      attr_reader :processed_count, :created_count, :updated_count, :skipped_count, :errors
      attr_reader :current_page, :last_processed_issn, :paused

      # 暂停检查间隔（每处理多少条检查一次）
      PAUSE_CHECK_INTERVAL = 50

      def initialize(api_url:, filters: {}, progress_callback: nil, import_log: nil)
        @api_url = api_url
        @filters = filters
        @progress_callback = progress_callback
        @import_log = import_log
        @client = Client.new(api_url)
        @processed_count = 0
        @created_count = 0
        @updated_count = 0
        @skipped_count = 0
        @errors = []
        @current_page = 1
        @last_processed_issn = nil
        @paused = false
      end

      # 导入第一页（测试用）
      def import_first_page!(page_size: 100)
        Rails.logger.info("[DiscourseJournals::ApiSync] Importing first page (#{page_size} items) with filters: #{@filters}")

        result = @client.fetch_page(page: 1, page_size: page_size, filters: @filters)
        journals = result[:journals]
        total = journals.size

        report_progress(0, total, "开始导入第一页：#{total} 个期刊...")

        journals.each_with_index do |journal, index|
          break if check_pause_requested?
          
          process_journal(journal, index)
          report_progress(index + 1, total, "已处理 #{index + 1}/#{total}")
        end

        if @paused
          report_progress(@processed_count, total, "导入已暂停")
        else
          report_progress(total, total, "第一页导入完成！")
        end
      end

      # 导入所有页（支持断点续传）
      def import_all_pages!(page_size: 100, start_page: 1, skip_count: 0)
        Rails.logger.info("[DiscourseJournals::ApiSync] Importing all pages from page #{start_page} with filters: #{@filters}")

        # 先获取总数
        first_result = @client.fetch_page(page: 1, page_size: 1, filters: @filters)
        total = first_result.dig(:pagination, "total") || 0
        total_pages = first_result.dig(:pagination, "totalPages") || 1

        # 如果是续传，恢复已处理的计数
        @processed_count = skip_count

        if start_page > 1
          report_progress(@processed_count, total, "从第 #{start_page} 页恢复导入，已处理 #{@processed_count} 条...")
        else
          report_progress(0, total, "准备导入所有数据：共 #{total} 个期刊...")
        end

        # 从指定页开始处理
        @current_page = start_page
        while @current_page <= total_pages
          break if check_pause_requested?

          result = @client.fetch_page(page: @current_page, page_size: page_size, filters: @filters)
          journals = result[:journals]

          journals.each_with_index do |journal, index|
            break if check_pause_requested?
            
            process_journal(journal, index)
            
            # 记录最后处理的 ISSN
            @last_processed_issn = journal["primary_issn"]

            # 每处理 PAUSE_CHECK_INTERVAL 个检查一次暂停
            if (@processed_count % PAUSE_CHECK_INTERVAL).zero?
              # 更新进度到数据库
              save_progress(total)
              
              report_progress(
                @processed_count,
                total,
                "已处理 #{@processed_count}/#{total} (#{@created_count} 新建, #{@updated_count} 更新, #{@errors.size} 错误)"
              )
            end
          end

          break if @paused

          @current_page += 1
        end

        # 最终保存进度
        save_progress(total)

        if @paused
          report_progress(@processed_count, total, "导入已暂停，可随时恢复")
        else
          report_progress(total, total, "全部导入完成！")
        end
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
          wikidata: sources_by_provider["wikidata"]&.dig("data"),
          wikipedia: sources_by_provider["wikipedia"]&.dig("data"),
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

      # 检查是否收到暂停请求
      def check_pause_requested?
        return false unless @import_log
        
        if @import_log.should_pause?
          @paused = true
          Rails.logger.info("[DiscourseJournals::ApiSync] Pause requested, stopping at page #{@current_page}")
          true
        else
          false
        end
      end

      # 保存当前进度到数据库
      def save_progress(total)
        return unless @import_log
        
        @import_log.update_progress!(
          page: @current_page,
          processed: @processed_count,
          total: total,
          last_issn: @last_processed_issn
        )
      end
    end
  end
end
