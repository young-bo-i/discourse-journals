# frozen_string_literal: true

module DiscourseJournals
  # Fetches the comments of several journals at once. Upstream takes most of a
  # second per request from here, so one request at a time would leave the
  # full sync mostly waiting. The clients share one rate limiter, which keeps
  # the total within the configured requests per second.
  class CommentFetcher
    CONCURRENCY = 4

    def initialize(rate_limiter: ApiRateLimiter.new)
      @clients = Array.new(CONCURRENCY) { ApiClient.new(rate_limiter: rate_limiter) }
    end

    # `journals` is [[topic_id, api_id], ...]. Returns { topic_id => result },
    # where a result is what CommentSyncer.fetch returned or the error it raised,
    # so one failing journal does not lose the rest of the batch.
    def fetch(journals)
      queue = Queue.new
      journals.each { |journal| queue << journal }
      queue.close
      results = {}
      mutex = Mutex.new

      threads =
        @clients.map do |client|
          Thread.new do
            while (journal = queue.pop)
              topic_id, api_id = journal
              result = fetch_one(client, api_id)
              mutex.synchronize { results[topic_id] = result }
            end
          end
        end
      threads.each(&:join)
      results
    end

    def finish!
      @clients.each(&:finish!)
    end

    private

    def fetch_one(client, api_id)
      return :no_api_id, nil if api_id.blank?

      CommentSyncer.fetch(client, api_id.to_i)
    rescue StandardError => e
      e
    end
  end
end
