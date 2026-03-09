# frozen_string_literal: true

require "json"
require "securerandom"

module DiscourseJournals
  class TopicCoverManager
    class SlotUnavailableError < StandardError; end
    class TopicLockedError < StandardError; end

    COVER_FINGERPRINT_VERSION = "cover_v2"
    FINGERPRINT_FIELD = "discourse_journals_cover_url_hash"
    MAX_REMOTE_FILE_SIZE = 5.megabytes
    REDIS_CONCURRENCY_KEY = "dj_cover_processing_count"
    TOPIC_LOCK_TTL_SECONDS = 120
    MAX_GLOBAL_CONCURRENT = 2
    SLOT_WAIT_SECONDS = 1
    MAX_SLOT_WAIT_ATTEMPTS = 3
    SLOT_TTL_SECONDS = 600

    class << self
      def normalize_cover_url(cover_url)
        url = cover_url.to_s.strip
        return nil if url.blank?

        url.start_with?("http") ? url : "https://journal.scholay.com#{url}"
      end

      def process!(
        topic:,
        cover_url: nil,
        issn: nil,
        country: nil,
        publisher: nil,
        force: false,
        thumbnail_sizes: nil
      )
        new(
          topic: topic,
          cover_url: cover_url,
          issn: issn,
          country: country,
          publisher: publisher,
          force: force,
          thumbnail_sizes: thumbnail_sizes,
        ).process!
      end

      def with_global_slot
        slot = acquire_global_slot
        raise SlotUnavailableError, "cover processing slot unavailable" unless slot

        heartbeat = start_slot_heartbeat(slot)

        begin
          yield
        ensure
          heartbeat&.kill
          heartbeat&.join
          release_global_slot(slot)
        end
      end

      private

      def acquire_global_slot
        attempts = 0

        loop do
          token = SecureRandom.hex(16)

          MAX_GLOBAL_CONCURRENT.times do |slot_index|
            slot_key = "#{REDIS_CONCURRENCY_KEY}:slot:#{slot_index}"
            acquired = Discourse.redis.set(slot_key, token, nx: true, ex: SLOT_TTL_SECONDS)
            return { key: slot_key, token: token } if acquired
          end

          attempts += 1
          return false if attempts >= MAX_SLOT_WAIT_ATTEMPTS

          sleep SLOT_WAIT_SECONDS
        end
      end

      def start_slot_heartbeat(slot)
        Thread.new do
          loop do
            sleep(SLOT_TTL_SECONDS / 3)
            current = Discourse.redis.get(slot[:key])
            break unless current == slot[:token]

            Discourse.redis.expire(slot[:key], SLOT_TTL_SECONDS)
          end
        end
      end

      def release_global_slot(slot)
        current = Discourse.redis.get(slot[:key])
        Discourse.redis.del(slot[:key]) if current == slot[:token]
      end
    end

    def initialize(topic:, cover_url: nil, issn: nil, country: nil, publisher: nil, force: false, thumbnail_sizes: nil)
      @topic = topic
      @cover_url = cover_url.to_s.strip
      @issn = issn.to_s.strip
      @country = country.to_s.strip
      @publisher = publisher.to_s.strip
      @force = force
      @thumbnail_sizes = thumbnail_sizes
    end

    def process!
      return :disabled unless SiteSetting.discourse_journals_download_covers

      with_topic_lock do
        preferred_source = cover_source
        preferred_fingerprints = acceptable_fingerprints(preferred_source)

        if skip_processing?(preferred_fingerprints)
          PerformanceLogger.log(
            "cover.skip",
            topic_id: @topic.id,
            source_type: preferred_source.to_s,
            cache_hit: true,
            elapsed_ms: 0,
          )
          return :unchanged
        end

        actual_source = preferred_source
        tempfile =
          if preferred_source == :remote
            PerformanceLogger.measure("cover.download", topic_id: @topic.id, source_type: "remote") do
              download_remote_cover
            end
          end

        if tempfile.nil?
          actual_source = preferred_source == :remote ? :remote_fallback : :generated
          tempfile =
            PerformanceLogger.measure("cover.generate", topic_id: @topic.id, source_type: actual_source.to_s) do
              generate_cover
            end
        end

        return :failed if tempfile.nil?

        upload =
          PerformanceLogger.measure("cover.upload", topic_id: @topic.id, source_type: actual_source.to_s) do
            upload_cover(tempfile)
          end
        return :failed if upload.blank? || upload.errors.any?

        PerformanceLogger.measure("cover.apply_upload", topic_id: @topic.id, source_type: actual_source.to_s) do
          apply_upload(upload)
        end
        persist_fingerprint(build_fingerprint(actual_source))

        actual_source == :remote ? :downloaded : :generated
      end
    rescue SlotUnavailableError => e
      PerformanceLogger.log("cover.defer", topic_id: @topic.id, deferred: true, elapsed_ms: 0)
      Rails.logger.warn("[DiscourseJournals] Deferred cover processing for topic #{@topic.id}: #{e.message}")
      :deferred
    rescue TopicLockedError => e
      PerformanceLogger.log("cover.defer", topic_id: @topic.id, deferred: true, elapsed_ms: 0)
      Rails.logger.warn("[DiscourseJournals] Deferred cover processing for topic #{@topic.id}: #{e.message}")
      :deferred
    rescue StandardError => e
      Rails.logger.warn("[DiscourseJournals] Failed to process cover for topic #{@topic.id}: #{e.message}")
      :failed
    ensure
      tempfile&.close! if tempfile.respond_to?(:close!)
    end

    private

    def with_topic_lock
      lock_key = "dj_topic_cover_lock:#{@topic.id}"
      token = SecureRandom.hex(12)
      acquired = Discourse.redis.set(lock_key, token, nx: true, ex: TOPIC_LOCK_TTL_SECONDS)
      raise TopicLockedError, "topic cover lock unavailable" unless acquired

      yield
    ensure
      current = Discourse.redis.get(lock_key)
      Discourse.redis.del(lock_key) if current == token
    end

    def skip_processing?(fingerprints)
      return false if @force

      current_fingerprint = TopicCustomField.where(topic_id: @topic.id, name: FINGERPRINT_FIELD).pick(:value)

      fingerprints.include?(current_fingerprint) && @topic.image_upload_id.present?
    end

    def acceptable_fingerprints(source)
      fingerprints = [build_fingerprint(source)]
      fingerprints << build_fingerprint(:remote_fallback) if source == :remote
      fingerprints
    end

    def cover_source
      normalized_remote_cover_url.present? ? :remote : :generated
    end

    def normalized_remote_cover_url
      @normalized_remote_cover_url ||= self.class.normalize_cover_url(@cover_url)
    end

    def build_fingerprint(source = cover_source)
      payload = {
        version: COVER_FINGERPRINT_VERSION,
        source: source,
        cover_url: source == :remote ? normalized_remote_cover_url : nil,
        title: @topic.title.to_s,
        issn: @issn,
        country: @country,
        publisher: @publisher,
      }

      Digest::SHA256.hexdigest(payload.to_json)
    end

    def download_remote_cover
      FileHelper.download(
        normalized_remote_cover_url,
        max_file_size: MAX_REMOTE_FILE_SIZE,
        tmp_file_name: "journal_cover",
        follow_redirect: true,
      )
    rescue StandardError => e
      Rails.logger.warn(
        "[DiscourseJournals] Cover download failed for topic #{@topic.id}: #{e.message}",
      )
      nil
    end

    def generate_cover
      self.class.with_global_slot do
        CoverImageGenerator.generate(
          title: @topic.title,
          issn: @issn.presence,
          country: @country.presence,
          publisher: @publisher.presence,
        )
      end
    end

    def upload_cover(tempfile)
      ext = tempfile.respond_to?(:path) && tempfile.path.end_with?(".png") ? "png" : "jpg"

      self.class.with_global_slot do
        UploadCreator.new(tempfile, "journal_cover_#{@topic.id}.#{ext}").create_for(
          Discourse.system_user.id,
        )
      end
    end

    def apply_upload(upload)
      @topic.update_column(:image_upload_id, upload.id)
      first_post = @topic.first_post
      return unless first_post

      first_post.update_column(:image_upload_id, upload.id)
      UploadReference.ensure_exist!(upload_ids: [upload.id], target: first_post)

      extra_sizes =
        @thumbnail_sizes || ThemeModifierHelper.new(theme_ids: Theme.user_selectable.pluck(:id)).topic_thumbnail_sizes
      PerformanceLogger.measure("cover.thumbnail", topic_id: @topic.id) do
        @topic.generate_thumbnails!(extra_sizes: extra_sizes)
      end
    end

    def persist_fingerprint(fingerprint)
      TopicCustomField.where(topic_id: @topic.id, name: FINGERPRINT_FIELD).delete_all
      TopicCustomField.create!(
        topic_id: @topic.id,
        name: FINGERPRINT_FIELD,
        value: fingerprint,
      )
    end
  end
end
