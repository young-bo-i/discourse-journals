# frozen_string_literal: true

module DiscourseJournals
  # Reconciles every journal topic's cover with upstream, independently of the
  # analyze → apply pipeline. Topics are walked by id. Each candidate is probed
  # with a HEAD on its preview URL, then either switched to the upstream cover
  # (its local cover is deleted) or returned to the default when upstream has
  # none. Leftovers of the retired cover subsystem are cleared along the way.
  class CoverSyncer
    class PausedError < StandardError
    end

    BATCH_SIZE = 500
    PROBE_CONCURRENCY = 8
    MAX_REDIRECTS = 3
    STAT_KEYS = %w[
      scanned
      probed
      with_cover
      updated
      unchanged
      cleared
      purged
      legacy_cleaned
      skipped
      errors
    ].freeze

    def initialize(cover_sync:, progress_callback: nil, cancel_check: nil)
      @cover_sync = cover_sync
      @progress_callback = progress_callback
      @cancel_check = cancel_check

      checkpoint = cover_sync.checkpoint || {}
      @last_topic_id = checkpoint["last_topic_id"].to_i
      @processed = checkpoint["processed"].to_i
      @stats = STAT_KEYS.index_with(0).merge((cover_sync.stats || {}).slice(*STAT_KEYS))
    end

    def run!
      ApiClient.ensure_configured!
      @category_id = SiteSetting.discourse_journals_category_id.to_i
      raise I18n.t("discourse_journals.errors.missing_category") if @category_id.zero?

      rate_limiter = ApiRateLimiter.new(rate: SiteSetting.discourse_journals_cover_sync_rate_limit)
      @clients =
        Array.new(PROBE_CONCURRENCY) { ApiClient.new(rate_limiter: rate_limiter, read_timeout: 30) }
      resumed_from = @processed
      started_at = monotonic_now

      loop do
        raise PausedError if @cancel_check&.call

        rows = load_batch
        break if rows.empty?

        process_batch(rows)
        @last_topic_id = rows.last.topic_id
        @processed += rows.size
        save_checkpoint
        report_progress(resumed_from, started_at)
      end

      @stats
    ensure
      @clients&.each(&:finish!)
    end

    private

    # Journals without any ISSN never get a cover upstream (covers are keyed by
    # ISSN), so only topics with an ISSN, or with a stored cover to re-check,
    # are worth a request. ISSNs other than ISSN-L only live in the stored JSON.
    def load_batch
      DB.query(<<~SQL, category_id: @category_id, after_id: @last_topic_id, limit: BATCH_SIZE)
        SELECT DISTINCT ON (t.id)
               t.id AS topic_id,
               u.id IS NOT NULL AS has_local_upload,
               api.value AS api_id,
               cover.value AS cover_url,
               issn.topic_id IS NOT NULL OR COALESCE(json_issn.present, false) AS has_issn
        FROM topics t
        LEFT JOIN uploads u ON u.id = t.image_upload_id
        LEFT JOIN topic_custom_fields api
          ON api.topic_id = t.id AND api.name = 'discourse_journals_api_id'
        LEFT JOIN topic_custom_fields cover
          ON cover.topic_id = t.id AND cover.name = 'discourse_journals_cover_url'
        LEFT JOIN topic_custom_fields issn
          ON issn.topic_id = t.id AND issn.name = 'discourse_journals_issn_l'
        LEFT JOIN LATERAL (
          SELECT NULLIF(j.identity ->> 'print_issn', '') IS NOT NULL
                 OR NULLIF(j.identity ->> 'electronic_issn', '') IS NOT NULL
                 OR CASE
                      WHEN jsonb_typeof(j.identity -> 'issn_details') = 'array'
                      THEN jsonb_array_length(j.identity -> 'issn_details') > 0
                      ELSE false
                    END AS present
          FROM (
            SELECT d.value::jsonb -> 'identity' AS identity
            FROM topic_custom_fields d
            WHERE d.topic_id = t.id
              AND d.name = 'discourse_journals_data'
              AND issn.topic_id IS NULL
            LIMIT 1
          ) j
        ) json_issn ON true
        WHERE t.category_id = :category_id
          AND t.deleted_at IS NULL
          AND t.id > :after_id
          AND t.id IS DISTINCT FROM (SELECT c.topic_id FROM categories c WHERE c.id = :category_id)
        ORDER BY t.id
        LIMIT :limit
      SQL
    end

    def process_batch(rows)
      candidates =
        rows.select { |row| row.api_id.present? && (row.has_issn || row.cover_url.present?) }
      results = probe_all(candidates)

      # Every probe failing means upstream itself is in trouble; stop before
      # writing anything so a resume redoes this batch.
      if candidates.any? && results.values.all?(:error)
        raise ApiClient::Error, I18n.t("discourse_journals.cover_sync.errors.probes_failing")
      end

      legacy = LocalCoverPurger.clear_legacy!(rows.map(&:topic_id))
      @stats["legacy_cleaned"] += legacy[:dangling] + legacy[:fingerprints]

      rows.each { |row| reconcile(row, results[row.topic_id]) }
      @stats["scanned"] += rows.size
    end

    def probe_all(rows)
      return {} if rows.empty?

      queue = Queue.new
      rows.each { |row| queue << row }
      results = {}
      fatal = nil
      mutex = Mutex.new

      threads =
        @clients
          .first(rows.size)
          .map do |client|
            Thread.new do
              loop do
                row =
                  begin
                    queue.pop(true)
                  rescue ThreadError
                    break
                  end
                break if mutex.synchronize { fatal }

                result = probe(client, row)
                mutex.synchronize { results[row.topic_id] = result }
              rescue ApiClient::AuthError, ApiClient::CoverStorageUnavailableError => e
                mutex.synchronize { fatal ||= e }
                break
              end
            end
          end

      threads.each(&:join)
      raise fatal if fatal

      results
    end

    def probe(client, row)
      stored_path = CoverUrl.relative(row.cover_url)
      result = client.probe_cover(row.api_id, etag: CoverUrl.version(stored_path))

      MAX_REDIRECTS.times do
        break if result.status != :redirected
        result = client.probe_cover(result.api_id)
      end

      result.status == :redirected ? :error : result
    rescue ApiClient::AuthError, ApiClient::CoverStorageUnavailableError
      raise
    rescue StandardError => e
      Rails.logger.warn(
        "[DiscourseJournals::CoverSyncer] Probe failed for topic #{row.topic_id} " \
          "(api_id=#{row.api_id}): #{e.class}: #{e.message}",
      )
      :error
    end

    def reconcile(row, result)
      if result == :error
        @stats["errors"] += 1
        return
      end

      stored_path = CoverUrl.relative(row.cover_url)
      desired = desired_path(result, stored_path)

      if result
        @stats["probed"] += 1
        @stats["with_cover"] += 1 if desired
      else
        @stats["skipped"] += 1
      end

      topic = nil
      in_effect = desired == stored_path

      if in_effect
        @stats["unchanged"] += 1 if result
      else
        topic = Topic.find_by(id: row.topic_id)
        return if topic.nil?

        outcome = TopicCoverApplier.apply!(topic, desired)
        @stats[outcome.to_s] += 1 if %i[updated cleared unchanged].include?(outcome)
        in_effect = outcome != :skipped
      end

      # Only drop the local cover once the upstream one has actually replaced it.
      if desired && in_effect && row.has_local_upload
        topic ||= Topic.find_by(id: row.topic_id)
        @stats["purged"] += 1 if topic && LocalCoverPurger.purge!(topic)
      end
    rescue StandardError => e
      @stats["errors"] += 1
      Rails.logger.warn(
        "[DiscourseJournals::CoverSyncer] Reconcile failed for topic #{row.topic_id}: " \
          "#{e.class}: #{e.message}",
      )
    end

    # A topic that was not probed keeps a cover it cannot re-check, but loses a
    # legacy name-addressed one: those URLs are dead.
    def desired_path(result, stored_path)
      if result.nil?
        CoverUrl.legacy?(stored_path) ? nil : stored_path
      elsif %i[present unchanged].include?(result.status)
        CoverUrl.preview_path(result.api_id, result.content_hash)
      end
    end

    def save_checkpoint
      @cover_sync.update_columns(
        checkpoint: {
          "last_topic_id" => @last_topic_id,
          "processed" => @processed,
          "heartbeat" => Time.current.to_i,
        },
        stats: @stats,
        updated_at: Time.current,
      )
    end

    def report_progress(resumed_from, started_at)
      return if @progress_callback.nil?

      elapsed = monotonic_now - started_at
      speed = elapsed.positive? ? (@processed - resumed_from) / elapsed : 0
      total = [@cover_sync.total, @processed].max
      @progress_callback.call(
        processed: @processed,
        total: total,
        progress: total.positive? ? (@processed * 100.0 / total).round(1) : 100,
        speed: speed.round(1),
        eta_seconds: speed.positive? ? ((total - @processed) / speed).round : nil,
        stats: @stats,
      )
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
