# frozen_string_literal: true

require "net/http"
require "json"

module DiscourseJournals
  module ApiSync
    class Client
      attr_reader :base_url

      def initialize(base_url)
        @base_url = base_url.to_s.gsub(/\/$/, "")
      end

      # 获取单页数据
      def fetch_page(page: 1, page_size: 100, filters: {})
        params = build_params(page, page_size, filters)
        url = "#{@base_url}/api/public/journals?#{params}"

        Rails.logger.info("[DiscourseJournals::ApiSync] Fetching: #{url}")

        uri = URI(url)
        response = Net::HTTP.get_response(uri)

        unless response.is_a?(Net::HTTPSuccess)
          raise "API request failed: #{response.code} #{response.message}"
        end

        data = JSON.parse(response.body)

        unless data["ok"]
          raise "API returned error: #{data["error"] || "Unknown error"}"
        end

        {
          journals: data["data"] || [],
          pagination: data["pagination"] || {},
          filters: data["filters"] || {}
        }
      rescue StandardError => e
        Rails.logger.error("[DiscourseJournals::ApiSync] Fetch failed: #{e.message}")
        raise e
      end

      # 获取所有页数据（返回枚举器，支持流式处理）
      def fetch_all_pages(page_size: 100, filters: {}, &block)
        page = 1
        total_fetched = 0

        loop do
          result = fetch_page(page: page, page_size: page_size, filters: filters)
          journals = result[:journals]
          pagination = result[:pagination]

          break if journals.empty?

          # 如果提供了 block，逐个处理
          if block_given?
            journals.each { |journal| yield journal, total_fetched }
            total_fetched += journals.size
          end

          # 检查是否还有更多页
          total_pages = pagination["totalPages"] || pagination["total_pages"]
          break if page >= total_pages.to_i

          page += 1

          # 避免过快请求
          sleep 0.1
        end

        total_fetched
      end

      private

      def build_params(page, page_size, filters)
        params = {
          page: page,
          pageSize: page_size
        }

        params[:q] = filters[:q] if filters[:q].present?
        params[:inDoaj] = filters[:in_doaj] if filters[:in_doaj].present?
        params[:inNlm] = filters[:in_nlm] if filters[:in_nlm].present?
        params[:hasWikidata] = filters[:has_wikidata] if filters[:has_wikidata].present?
        params[:isOpenAccess] = filters[:is_open_access] if filters[:is_open_access].present?
        params[:sortBy] = filters[:sort_by] if filters[:sort_by].present?
        params[:sortOrder] = filters[:sort_order] if filters[:sort_order].present?

        params.map { |k, v| "#{k}=#{CGI.escape(v.to_s)}" }.join("&")
      end
    end
  end
end
