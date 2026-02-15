# frozen_string_literal: true

require "net/http"
require "json"

module DiscourseJournals
  class TitleMatcher
    class PausedError < StandardError; end

    API_BASE_URL = "https://journal.scholay.com/api/open/journals"
    API_PAGE_SIZE = 1000
    PROGRESS_INTERVAL = 10

    attr_reader :forum_index, :api_index, :results

    def initialize(progress_callback: nil, cancel_check: nil)
      @progress_callback = progress_callback
      @cancel_check = cancel_check
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

    def self.normalize_title(title)
      return "" if title.blank?

      title
        .strip
        .downcase
        .gsub(/\s+/, " ")
        .gsub("&", " and ")
        .gsub(/[^\p{L}\p{N}\s]/, "")
        .gsub(/\s+/, " ")
        .strip
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
        normalized = self.class.normalize_title(topic.title)
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

      first_result = fetch_api_page(1, API_PAGE_SIZE)
      total_records = first_result[:total]
      total_pages = first_result[:total_pages]
      actual_page_size = first_result[:rows].size

      publish_progress(:api, 0, total_records, "API 共 #{total_records} 条记录，每页 #{actual_page_size} 条，共 #{total_pages} 页")

      # 处理第一页数据
      fetched = 0
      first_result[:rows].each do |row|
        unified = row["unified"] || {}
        canonical_name = unified["canonical_name"]
        next if canonical_name.blank?

        normalized = self.class.normalize_title(canonical_name)
        next if normalized.blank?

        @api_index[normalized] ||= []
        @api_index[normalized] << {
          api_id: unified["id"],
          canonical_name: canonical_name,
          issn_l: unified["issn_l"],
        }

        fetched += 1
      end

      publish_progress(:api, fetched, total_records, "API 数据获取中... 第 1/#{total_pages} 页 (#{fetched} 条)")

      page = 2

      while page <= total_pages
        check_cancelled!
        result = fetch_api_page(page, API_PAGE_SIZE)
        rows = result[:rows]
        break if rows.empty?

        rows.each do |row|
          unified = row["unified"] || {}
          canonical_name = unified["canonical_name"]
          next if canonical_name.blank?

          normalized = self.class.normalize_title(canonical_name)
          next if normalized.blank?

          @api_index[normalized] ||= []
          @api_index[normalized] << {
            api_id: unified["id"],
            canonical_name: canonical_name,
            issn_l: unified["issn_l"],
          }

          fetched += 1
        end

        if page % PROGRESS_INTERVAL == 0 || page == total_pages
          publish_progress(
            :api,
            fetched,
            total_records,
            "API 数据获取中... 第 #{page}/#{total_pages} 页 (#{fetched} 条)"
          )
        end

        page += 1
        sleep 0.05
      end

      publish_progress(:api, fetched, total_records, "API 索引构建完成：#{fetched} 条记录，#{@api_index.size} 个唯一标题")
    end

    def fetch_api_page(page, page_size)
      url = "#{API_BASE_URL}?page=#{page}&pageSize=#{page_size}"
      uri = URI(url)

      retries = 0
      max_retries = 3

      begin
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = (uri.scheme == "https")
        http.open_timeout = 30
        http.read_timeout = 60
        http.ssl_timeout = 30

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
          Rails.logger.warn("[DiscourseJournals::TitleMatcher] Page #{page} retry #{retries}/#{max_retries} after #{e.class}: #{e.message}, waiting #{wait}s")
          publish_progress(:api, 0, 0, "第 #{page} 页请求失败 (#{e.class.name.split('::').last})，#{wait}s 后第 #{retries} 次重试...")
          sleep wait
          retry
        end
        raise "API 第 #{page} 页请求失败 (重试 #{max_retries} 次后): #{e.message}"
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
