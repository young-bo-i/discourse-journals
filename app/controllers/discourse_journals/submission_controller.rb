# frozen_string_literal: true

require "net/http"

module DiscourseJournals
  # Upstream serves submission guidelines and LaTeX templates under /api/open,
  # which now requires the API key — a browser following a direct link gets a 401
  # because it cannot send the header. Upstream's own docs say to fetch these
  # server-side and hand the bytes to the browser, which is what this does.
  #
  # Only the two documented submission paths are reachable, the journal id must
  # be an integer, and downloads are rate limited per IP. Crawlers are refused
  # before the upstream fetch: they find these links on every journal page and
  # made up ~99% of the traffic, each request holding a web worker for a full
  # file download that nothing indexes.
  class SubmissionController < ::ApplicationController
    requires_plugin DiscourseJournals::PLUGIN_NAME

    skip_before_action :check_xhr, only: [:show]

    KINDS = {
      "guideline" => { extension: "md", content_type: "text/markdown" },
      "latex" => { extension: "zip", content_type: "application/zip" },
    }.freeze

    # downloads per IP per minute
    RATE_LIMIT = 30
    MAX_BYTES = 25.megabytes

    def show
      raise Discourse::NotFound unless SiteSetting.discourse_journals_submission_proxy_enabled
      raise Discourse::NotFound unless ApiClient.configured?

      response.headers["X-Robots-Tag"] = "noindex, nofollow"
      if CrawlerDetection.crawler?(request.user_agent, request.env["HTTP_VIA"])
        return head :forbidden
      end

      kind_name = params[:kind].to_s
      kind = KINDS[kind_name]
      raise Discourse::NotFound if kind.nil?

      api_id = params[:api_id].to_s
      raise Discourse::NotFound unless api_id.match?(/\A\d+\z/)

      RateLimiter.new(
        current_user,
        "dj-submission-#{request.remote_ip}",
        RATE_LIMIT,
        1.minute,
      ).performed!

      file = fetch_upstream(api_id, kind_name)
      raise Discourse::NotFound if file.nil?

      send_data(
        file[:body],
        filename: "#{api_id}-#{kind_name}.#{kind[:extension]}",
        type: file[:content_type].presence || kind[:content_type],
        disposition: "attachment",
      )
    end

    private

    # Returns { body:, content_type: }, or nil for any upstream failure or a
    # response over MAX_BYTES. The body is streamed so an oversized file is
    # abandoned mid-download instead of being fully buffered first.
    def fetch_upstream(api_id, kind)
      uri = URI("#{SiteSetting.discourse_journals_api_base_url}/api/open/journals/#{api_id}/submission/#{kind}")
      result = nil

      # The whole fetch holds a web worker, so give up on a slow upstream early
      # rather than let a handful of stuck downloads tie up every worker.
      Net::HTTP.start(
        uri.host,
        uri.port,
        use_ssl: uri.scheme == "https",
        open_timeout: 5,
        read_timeout: 15,
      ) do |http|
        request = Net::HTTP::Get.new(uri.request_uri)
        request["X-API-Key"] = ApiClient.api_key

        http.request(request) do |response|
          next unless response.is_a?(Net::HTTPSuccess)
          next if response["Content-Length"].to_i > MAX_BYTES

          body = +""
          oversized = false
          response.read_body do |chunk|
            body << chunk
            if body.bytesize > MAX_BYTES
              oversized = true
              break
            end
          end

          next if oversized || body.empty?

          result = { body: body, content_type: response["Content-Type"] }
        end
      end

      result
    rescue StandardError => e
      Rails.logger.warn(
        "[DiscourseJournals::Submission] Upstream fetch failed for #{api_id}/#{kind}: #{e.class}: #{e.message}",
      )
      nil
    end
  end
end
