# frozen_string_literal: true

module DiscourseJournals
  # Tells IndexNow search engines (Bing, Yandex, Naver, Seznam) about journal
  # pages the sync created or changed, so they are recrawled without waiting
  # for the next sitemap pass.
  module IndexNow
    ENDPOINT = "https://api.indexnow.org/indexnow"
    QUEUE_KEY = "discourse_journals_indexnow_urls"
    # Protocol maximum per request.
    BATCH_SIZE = 10_000
    RETRYABLE_STATUSES = [429, *500..599].freeze

    def self.enabled?
      SiteSetting.discourse_journals_enabled && SiteSetting.discourse_journals_indexnow_enabled
    end

    # Derived from the site secret so it stays stable without being stored.
    def self.key
      @key ||=
        begin
          seed = "discourse-journals-indexnow:#{GlobalSetting.safe_secret_key_base}"
          Digest::SHA256.hexdigest(seed).first(32)
        end
    end

    def self.key_location
      "#{Discourse.base_url}/#{key}.txt"
    end

    def self.queue(topic)
      return if !enabled? || topic.nil?

      Discourse.redis.sadd(QUEUE_KEY, "#{Discourse.base_url}#{topic.relative_url}")
    end

    def self.pending_count
      Discourse.redis.scard(QUEUE_KEY)
    end

    # Returns the number of URLs the endpoint accepted.
    def self.submit_pending!
      return 0 unless enabled?

      urls = Array(Discourse.redis.spop(QUEUE_KEY, BATCH_SIZE))
      return 0 if urls.empty?

      response =
        Excon.post(
          ENDPOINT,
          body: {
            host: URI(Discourse.base_url).host,
            key: key,
            keyLocation: key_location,
            urlList: urls,
          }.to_json,
          headers: {
            "Content-Type" => "application/json; charset=utf-8",
          },
          connect_timeout: 10,
          read_timeout: 30,
          write_timeout: 30,
        )

      return urls.size if [200, 202].include?(response.status)

      requeue(urls) if RETRYABLE_STATUSES.include?(response.status)
      Rails.logger.warn(
        "[DiscourseJournals] IndexNow returned HTTP #{response.status} for #{urls.size} URLs: #{response.body.to_s[0, 200]}",
      )
      0
    rescue Excon::Error => e
      requeue(urls)
      Rails.logger.warn("[DiscourseJournals] IndexNow request failed: #{e.message}")
      0
    end

    def self.requeue(urls)
      Discourse.redis.sadd(QUEUE_KEY, urls) if urls.present?
    end
    private_class_method :requeue
  end
end
