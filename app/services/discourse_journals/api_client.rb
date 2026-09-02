# frozen_string_literal: true

require "net/http"
require "json"

module DiscourseJournals
  # Single place that knows how to talk to the upstream journal API (contract v1,
  # documented at <base_url>/api-docs/).
  #
  # Every endpoint under /api/open now requires an API key, so all requests go
  # through here to guarantee the header is attached. It also owns the retry /
  # reconnect / rate-limit policy that TitleMatcher and MappingApplier used to
  # duplicate.
  class ApiClient
    class Error < StandardError
    end

    # 401 api_key_required / invalid_api_key. Never retried: retrying a bad key
    # just burns the whole sync window against a wall.
    class AuthError < Error
    end

    # 410 endpoint_gone. The upstream response carries a `successor` field with a
    # ready-to-run replacement, so surface it instead of a bare status code.
    class EndpointGoneError < Error
      attr_reader :successor

      def initialize(message, successor = nil)
        @successor = successor
        super(message)
      end
    end

    class RateLimitedError < Error
      attr_reader :retry_after

      def initialize(retry_after = 5)
        @retry_after = retry_after
        super("429 Too Many Requests")
      end
    end

    MAX_RETRIES = 5
    RETRYABLE = [
      Net::OpenTimeout,
      Net::ReadTimeout,
      OpenSSL::SSL::SSLError,
      Errno::ECONNRESET,
      Errno::ECONNREFUSED,
      Errno::EPIPE,
      EOFError,
      IOError,
      SocketError,
    ].freeze

    # Upstream caps `/journals` at pageSize=2000 (it was 100 before contract v4).
    # The cursor (`afterId`) walk has no deep-offset ceiling, so this is purely a
    # per-request size knob.
    LIST_PAGE_SIZE = 2_000

    # `ids` accepts up to 200 per request, but a `full=1` row is ~70 KB, so 200
    # ids is a ~14 MB response. 50 keeps the in-flight payload (4 concurrent +
    # 4 prefetched) inside a sane memory budget.
    IDS_BATCH_SIZE = 50
    IDS_MAX_PER_REQUEST = 200

    # Only the fields the analysis pass actually indexes. Cuts the full-catalogue
    # walk from ~2.9 MB to ~1 MB per 2000-row page.
    LIST_FIELDS = "id,canonical_name,issn_l"

    def self.api_key
      SiteSetting.discourse_journals_api_key.to_s.strip
    end

    def self.configured?
      api_key.present?
    end

    # Called before a sync job starts so the admin sees a precise error instead
    # of 5 retries' worth of 401s.
    def self.ensure_configured!
      return if configured?
      raise AuthError, I18n.t("discourse_journals.errors.missing_api_key")
    end

    def initialize(rate_limiter: nil, read_timeout: 60)
      @rate_limiter = rate_limiter || ApiRateLimiter.new
      @read_timeout = read_timeout
      @http = nil
    end

    def start!
      @http = build_connection
      self
    end

    def finish!
      @http&.finish
    rescue StandardError
      nil
    ensure
      @http = nil
    end

    def reconnect!
      finish!
      start!
    end

    # One page of the full-catalogue cursor walk.
    def fetch_journal_page(cursor: nil, page_size: LIST_PAGE_SIZE, fields: LIST_FIELDS)
      query = { "pageSize" => page_size }
      query["fields"] = fields if fields.present?
      query["afterId"] = cursor if cursor

      payload = get_data("/api/open/journals", query)

      {
        rows: payload["rows"] || [],
        next_cursor: payload["nextCursor"],
        has_more: payload["hasMore"] ? true : false,
      }
    end

    # Batch detail fetch. Replaces the retired /journals/byIds endpoint.
    #
    # `resolveIds=follow` folds ids that upstream has since merged into their new
    # target row, and the response's `redirects` map ({old_id => new_id|nil})
    # tells us which of our stored api_ids moved or died — see MappingApplier,
    # which re-points the topic instead of orphaning it.
    def fetch_journals_by_ids(ids)
      ids = Array(ids).compact
      return { rows: [], redirects: {}, lookup: {} } if ids.empty?

      if ids.size > IDS_MAX_PER_REQUEST
        raise Error, "ids 单次上限 #{IDS_MAX_PER_REQUEST} 个（收到 #{ids.size} 个）"
      end

      payload =
        get_data(
          "/api/open/journals",
          { "ids" => ids.join(","), "full" => 1, "resolveIds" => "follow" },
        )

      {
        rows: payload["rows"] || [],
        redirects: payload["redirects"] || {},
        lookup: payload["lookup"] || {},
      }
    end

    private

    def get_data(path, query = {})
      body = get_json(path, query)

      unless body["success"]
        raise Error, "API 返回错误: #{body["error"] || body["message"] || "Unknown"}"
      end

      body["data"] || {}
    end

    def get_json(path, query = {})
      full_path = query.present? ? "#{path}?#{URI.encode_www_form(query)}" : path
      retries = 0

      begin
        @rate_limiter.throttle!
        start! if @http.nil?

        request = Net::HTTP::Get.new(full_path)
        request["X-API-Key"] = self.class.api_key
        request["Accept"] = "application/json"

        response = @http.request(request)
        code = response.code.to_i

        case code
        when 401
          raise AuthError, auth_error_message(response)
        when 410
          parsed = safe_parse(response.body)
          raise EndpointGoneError.new(
                  "API 端点已下线: #{path}#{" — 请改用 #{parsed["successor"]}" if parsed["successor"].present?}",
                  parsed["successor"],
                )
        when 429
          raise RateLimitedError.new((response["Retry-After"] || (retries * 5 + 5)).to_i.clamp(2, 60))
        end

        unless response.is_a?(Net::HTTPSuccess)
          raise Error, "API 请求失败: #{code} #{response.message} (#{path})"
        end

        JSON.parse(response.body)
      rescue RateLimitedError => e
        retries += 1
        raise Error, "API 请求被限流 (#{path} 重试 #{MAX_RETRIES} 次后仍为 429)" if retries > MAX_RETRIES

        Rails.logger.warn(
          "[DiscourseJournals::ApiClient] #{path} rate-limited (429), " \
            "retry #{retries}/#{MAX_RETRIES}, waiting #{e.retry_after}s",
        )
        sleep e.retry_after
        retry
      rescue *RETRYABLE => e
        retries += 1
        if retries > MAX_RETRIES
          raise Error, "API 请求失败 (#{path} 重试 #{MAX_RETRIES} 次后): #{e.message}"
        end

        wait = retries * 3
        Rails.logger.warn(
          "[DiscourseJournals::ApiClient] #{path} retry #{retries}/#{MAX_RETRIES} " \
            "after #{e.class}: #{e.message}, waiting #{wait}s",
        )
        begin
          reconnect!
        rescue StandardError => re
          Rails.logger.warn("[DiscourseJournals::ApiClient] Reconnect failed: #{re.message}")
        end
        sleep wait
        retry
      rescue JSON::ParserError => e
        raise Error, "API 响应不是合法 JSON (#{path}): #{e.message}"
      end
    end

    def auth_error_message(response)
      parsed = safe_parse(response.body)
      if parsed["error"] == "invalid_api_key"
        I18n.t("discourse_journals.errors.invalid_api_key")
      else
        I18n.t("discourse_journals.errors.missing_api_key")
      end
    end

    def safe_parse(body)
      parsed = JSON.parse(body.to_s)
      parsed.is_a?(Hash) ? parsed : {}
    rescue StandardError
      {}
    end

    def build_connection
      uri = URI(SiteSetting.discourse_journals_api_base_url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = 30
      http.read_timeout = @read_timeout
      http.keep_alive_timeout = 120
      http.start
      http
    end
  end
end
