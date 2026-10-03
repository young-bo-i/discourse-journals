# frozen_string_literal: true

module DiscourseJournals
  # Upstream serves one WebP per journal, addressed by the stable unified id and
  # versioned by the cover's content hash. Stored paths are relative to
  # discourse_journals_api_base_url; the cover custom field holds the absolute URL.
  module CoverUrl
    PREVIEW_PATH = %r{\A/api/covers/preview/(\d+)\.webp\?v=([0-9a-f]{16})\z}
    CONTENT_HASH = /\A[0-9a-f]{16}\z/
    # The retired name-addressed covers, on any host. Upstream answers 401 for every one.
    LEGACY_URL = %r{\A(?:[a-z][a-z0-9+.-]*://[^/]+)?/api/covers/image/}i

    def self.from_api(cover)
      return if !cover.is_a?(Hash)

      cover[:preview_url].presence || cover["preview_url"].presence
    end

    # The preview ETag is the cover's content_hash, which is also the `v` of
    # upstream's own preview_url — so this rebuilds that URL exactly.
    def self.preview_path(api_id, content_hash)
      "/api/covers/preview/#{api_id.to_i}.webp?v=#{content_hash}"
    end

    def self.version(path)
      path.to_s.match(PREVIEW_PATH)&.[](2)
    end

    def self.legacy?(url)
      LEGACY_URL.match?(url.to_s.strip)
    end

    # Display code must not hand out a legacy URL: it renders as a broken image
    # until cover sync reaches the topic.
    def self.displayable(url)
      url.presence if !legacy?(url)
    end

    def self.absolute(path)
      path = path.to_s.strip
      return if path.blank?

      path.start_with?("http") ? path : "#{base_url}#{path}"
    end

    def self.relative(url)
      url = url.to_s.strip
      return if url.blank?

      base = base_url
      base.present? && url.start_with?(base) ? url.delete_prefix(base) : url
    end

    def self.base_url
      SiteSetting.discourse_journals_api_base_url.to_s.strip.chomp("/")
    end
    private_class_method :base_url
  end
end
