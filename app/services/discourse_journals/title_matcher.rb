# frozen_string_literal: true

require "net/http"
require "json"
require "cgi"

module DiscourseJournals
  class TitleMatcher
    class PausedError < StandardError; end

    API_BASE_URL = "https://journal.scholay.com/api/open/journals"
    API_PAGE_SIZE = 1000
    API_CONCURRENCY = 5
    PROGRESS_BATCH_INTERVAL = 5

    attr_reader :forum_index, :api_index, :results

    def initialize(progress_callback: nil, cancel_check: nil)
      @progress_callback = progress_callback
      @cancel_check = cancel_check
      @rate_limiter = ApiRateLimiter.new
      @forum_index = {}
      @api_index = {}
      @results = {
        exact_1to1: [],
        forum_1_to_api_n: [],
        forum_n_to_api_1: [],
        forum_n_to_api_m: [],
        forum_only: [],
        api_only: [],
      }
    end

    # 论坛标题规范化：HTML 反转义 + 小写（标题已经过 Discourse TextCleaner 处理）
    def self.normalize_forum_title(title)
      return "" if title.blank?

      CGI.unescapeHTML(title).strip.downcase
    end

    # API 标题规范化：模拟 Discourse 保存标题时的清洗逻辑 + 小写
    def self.normalize_api_title(title)
      return "" if title.blank?

      cleaned = TextCleaner.clean_title(TextSentinel.title_sentinel(title).text)
      cleaned.strip.downcase
    end

    def run!
      build_forum_index
      build_api_index
      cross_match
      results
    end

    private

    def publish_progress(phase, current, total, message)
      @progress_callback&.call(phase, current, total, message)
    end

    def check_cancelled!
      raise PausedError, "分析已被用户暂停" if @cancel_check&.call
    end

    def build_forum_index
      category_id = SiteSetting.discourse_journals_category_id.to_i
      if category_id.zero?
        raise "请先在设置中配置期刊分类 (discourse_journals_category_id)"
      end

      publish_progress(:forum, 0, 0, "正在查询论坛期刊数据...")

      base_scope = Topic.where(category_id: category_id).where(deleted_at: nil)
      total = base_scope.count
      topics = base_scope.select(:id, :title)
      publish_progress(:forum, 0, total, "正在建立论坛标题索引 (#{total} 个话题)...")

      topics.find_each.with_index do |topic, idx|
        normalized = self.class.normalize_forum_title(topic.title)
        next if normalized.blank?

        @forum_index[normalized] ||= []
        @forum_index[normalized] << {
          topic_id: topic.id,
          title: topic.title,
        }

        if (idx + 1) % 10_000 == 0
          check_cancelled!
          publish_progress(:forum, idx + 1, total, "论坛索引构建中... #{idx + 1}/#{total}")
        end
      end

      publish_progress(:forum, total, total, "论坛索引构建完成：#{total} 个话题，#{@forum_index.size} 个唯一标题")
    end

    def build_api_index
      publish_progress(:api, 0, 0, "正在获取 API 数据...")

      first_result = fetch_api_page_oneoff(1, API_PAGE_SIZE)
      total_records = first_result[:total]
      total_pages = first_result[:total_pages]
      actual_page_size = first_result[:rows].size

      publish_progress(
        :api,
        0,
        total_records,
        "API 共 #{total_records} 条记录，每页 #{actual_page_size} 条，共 #{total_pages} 页 (#{API_CONCURRENCY} 线程并发)",
      )

      fetched = process_api_rows(first_result[:rows])

      if total_pages <= 1
        publish_progress(:api, fetched, total_records, "API 索引构建完成：#{fetched} 条记录，#{@api_index.size} 个唯一标题")
        return
      end

      connections = API_CONCURRENCY.times.map { create_persistent_connection }
      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      begin
        remaining_pages = (2..total_pages).to_a
        batch_count = 0

        remaining_pages.each_slice(API_CONCURRENCY) do |batch|
          check_cancelled!

          batch_results = fetch_batch_concurrent(connections, batch)

          batch_results.each do |result|
            fetched += process_api_rows(result[:rows])
          end

          batch_count += 1
          last_page = batch.last

          if batch_count % PROGRESS_BATCH_INTERVAL == 0 || last_page == total_pages
            elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time
            speed = (fetched.to_f / elapsed).round(0)
            eta = elapsed > 0 && fetched > 0 ? ((total_records - fetched).to_f / speed).round(0) : 0
            eta_str = format_eta(eta)

            publish_progress(
              :api,
              fetched,
              total_records,
              "API 获取中... #{last_page}/#{total_pages} 页 (#{fetched} 条, #{speed} 条/秒#{eta_str})",
            )
          end
        end
      ensure
        connections.each do |conn|
          conn.finish
        rescue StandardError
          nil
        end
      end

      elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time).round(1)
      publish_progress(
        :api,
        fetched,
        total_records,
        "API 索引构建完成：#{fetched} 条记录，#{@api_index.size} 个唯一标题 (耗时 #{elapsed}s)",
      )
    end

    def create_persistent_connection
      uri = URI(API_BASE_URL)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = 30
      http.read_timeout = 60
      http.keep_alive_timeout = 120
      http.start
      http
    end

    def reconnect!(http)
      http.finish
    rescue StandardError
      nil
    ensure
      http.start
    end

    def fetch_batch_concurrent(connections, pages)
      threads = pages.each_with_index.map do |page, idx|
        conn = connections[idx % connections.size]
        Thread.new { fetch_api_page_persistent(conn, page) }
      end

      threads.map(&:value)
    end

    def fetch_api_page_persistent(http, page)
      path = "/api/open/journals?page=#{page}&pageSize=#{API_PAGE_SIZE}"
      retries = 0
      max_retries = 3

      begin
        @rate_limiter.throttle!
        request = Net::HTTP::Get.new(path)
        response = http.request(request)

        unless response.is_a?(Net::HTTPSuccess)
          raise "API 请求失败: #{response.code} #{response.message}"
        end

        data = JSON.parse(response.body)
        unless data["success"]
          raise "API 返回错误: #{data["error"] || "Unknown"}"
        end

        payload = data["data"] || {}
        {
          rows: payload["rows"] || [],
          total: payload["total"].to_i,
          page: payload["page"].to_i,
          total_pages: payload["totalPages"].to_i,
        }
      rescue Net::OpenTimeout, Net::ReadTimeout, OpenSSL::SSL::SSLError, Errno::ECONNRESET, EOFError, IOError => e
        retries += 1
        if retries <= max_retries
          wait = retries * 2
          Rails.logger.warn(
            "[DiscourseJournals::TitleMatcher] Page #{page} retry #{retries}/#{max_retries} after #{e.class}: #{e.message}, waiting #{wait}s",
          )
          begin
            reconnect!(http)
          rescue StandardError => re
            Rails.logger.warn("[DiscourseJournals::TitleMatcher] Reconnect failed: #{re.message}")
          end
          sleep wait
          retry
        end
        raise "API 第 #{page} 页请求失败 (重试 #{max_retries} 次后): #{e.message}"
      end
    end

    def fetch_api_page_oneoff(page, page_size)
      url = "#{API_BASE_URL}?page=#{page}&pageSize=#{page_size}"
      uri = URI(url)

      retries = 0
      max_retries = 3

      begin
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = (uri.scheme == "https")
        http.open_timeout = 30
        http.read_timeout = 60

        response = http.get(uri.request_uri)
        unless response.is_a?(Net::HTTPSuccess)
          raise "API 请求失败: #{response.code} #{response.message}"
        end

        data = JSON.parse(response.body)
        unless data["success"]
          raise "API 返回错误: #{data["error"] || "Unknown"}"
        end

        payload = data["data"] || {}
        {
          rows: payload["rows"] || [],
          total: payload["total"].to_i,
          page: payload["page"].to_i,
          total_pages: payload["totalPages"].to_i,
        }
      rescue Net::OpenTimeout, Net::ReadTimeout, OpenSSL::SSL::SSLError, Errno::ECONNRESET, EOFError => e
        retries += 1
        if retries <= max_retries
          wait = retries * 5
          Rails.logger.warn(
            "[DiscourseJournals::TitleMatcher] Page #{page} retry #{retries}/#{max_retries} after #{e.class}: #{e.message}, waiting #{wait}s",
          )
          sleep wait
          retry
        end
        raise "API 第 #{page} 页请求失败 (重试 #{max_retries} 次后): #{e.message}"
      end
    end

    def process_api_rows(rows)
      count = 0
      rows.each do |row|
        unified = row["unified"] || {}
        canonical_name = unified["canonical_name"]
        next if canonical_name.blank?

        normalized = self.class.normalize_api_title(canonical_name)
        next if normalized.blank?

        @api_index[normalized] ||= []
        @api_index[normalized] << {
          api_id: unified["id"],
          canonical_name: canonical_name,
          issn_l: unified["issn_l"],
        }

        count += 1
      end
      count
    end

    def format_eta(seconds)
      return "" if seconds <= 0

      if seconds < 60
        ", 约 #{seconds}s"
      elsif seconds < 3600
        mins = seconds / 60
        secs = seconds % 60
        secs > 0 ? ", 约 #{mins}m#{secs}s" : ", 约 #{mins}m"
      else
        hours = seconds / 3600
        mins = (seconds % 3600) / 60
        mins > 0 ? ", 约 #{hours}h#{mins}m" : ", 约 #{hours}h"
      end
    end

    def cross_match
      publish_progress(:match, 0, 0, "正在进行标题交叉比对...")

      all_normalized_titles = (@forum_index.keys + @api_index.keys).uniq
      total = all_normalized_titles.size

      all_normalized_titles.each_with_index do |normalized_title, idx|
        forum_entries = @forum_index[normalized_title]
        api_entries = @api_index[normalized_title]

        if forum_entries && api_entries
          forum_count = forum_entries.size
          api_count = api_entries.size

          entry = {
            normalized_title: normalized_title,
            forum: forum_entries,
            api: api_entries,
          }

          if forum_count == 1 && api_count == 1
            @results[:exact_1to1] << entry
          elsif forum_count == 1 && api_count > 1
            @results[:forum_1_to_api_n] << entry
          elsif forum_count > 1 && api_count == 1
            @results[:forum_n_to_api_1] << entry
          else
            @results[:forum_n_to_api_m] << entry
          end
        elsif forum_entries && api_entries.nil?
          @results[:forum_only] << {
            normalized_title: normalized_title,
            forum: forum_entries,
          }
        elsif forum_entries.nil? && api_entries
          @results[:api_only] << {
            normalized_title: normalized_title,
            api: api_entries,
          }
        end

        if (idx + 1) % 50_000 == 0 || idx + 1 == total
          check_cancelled!
          publish_progress(:match, idx + 1, total, "比对进行中... #{idx + 1}/#{total}")
        end
      end

      publish_progress(:match, total, total, "比对完成！")
    end
  end
end
