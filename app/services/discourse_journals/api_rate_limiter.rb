# frozen_string_literal: true

module DiscourseJournals
  # Token-bucket rate limiter for external API calls.
  # Thread-safe: multiple concurrent fetchers share one instance.
  class ApiRateLimiter
    DEFAULT_REQUESTS_PER_SECOND = 10

    def initialize(rate: DEFAULT_REQUESTS_PER_SECOND)
      @mutex = Mutex.new
      @interval = 1.0 / rate
      @last_request_at = 0.0
    end

    def throttle!
      sleep_time = nil

      @mutex.synchronize do
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        wait = @last_request_at + @interval - now
        if wait > 0
          sleep_time = wait
          @last_request_at = now + wait
        else
          @last_request_at = now
        end
      end

      sleep(sleep_time) if sleep_time
    end
  end
end
