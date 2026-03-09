# frozen_string_literal: true

module DiscourseJournals
  class PerformanceLogger
    class << self
      def enabled?
        SiteSetting.discourse_journals_performance_logging
      rescue StandardError
        false
      end

      def measure(phase, topic_id: nil, source_type: nil, deferred: nil, cache_hit: nil, **extra)
        start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        result = yield

        log(
          phase,
          topic_id: topic_id,
          source_type: source_type,
          deferred: deferred,
          cache_hit: cache_hit,
          elapsed_ms: elapsed_ms_since(start),
          result: summarize_result(result),
          **extra,
        )

        result
      end

      def log(phase, topic_id: nil, source_type: nil, deferred: nil, cache_hit: nil, elapsed_ms: nil, **extra)
        return unless enabled?

        payload = {
          phase: phase,
          topic_id: topic_id,
          source_type: source_type,
          deferred: deferred,
          cache_hit: cache_hit,
          elapsed_ms: elapsed_ms,
        }.merge(extra).compact

        serialized =
          payload.map { |key, value| "#{key}=#{serialize_value(value)}" }.join(" ")
        Rails.logger.info("[DiscourseJournals::Perf] #{serialized}")
      end

      def elapsed_ms_since(start)
        ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000).round(1)
      end

      private

      def summarize_result(result)
        case result
        when NilClass
          "nil"
        when Symbol, String, Numeric, TrueClass, FalseClass
          result
        when Array
          "array(#{result.length})"
        when Hash
          "hash(#{result.keys.length})"
        else
          result.class.name
        end
      end

      def serialize_value(value)
        case value
        when String
          value.include?(" ") ? value.inspect : value
        else
          value.to_s
        end
      end
    end
  end
end
