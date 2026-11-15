# frozen_string_literal: true

module DiscourseJournals
  # Turns one upstream comment into the raw Markdown and timestamp of its reply,
  # with the original text kept verbatim. Where and when it was first published
  # goes into the post's custom field, so the note can be switched off without
  # rewriting posts (see CommentSourceNote).
  class CommentPostBuilder
    TIME_ZONE = CommentSourceNote::TIME_ZONE
    PRECISIONS = CommentSourceNote::PRECISIONS
    STATUSES = %w[
      accepted
      accepted_after_revision
      rejected
      desk_rejected
      under_review
      revision
      submitted
      withdrawn
    ].freeze
    TIME_METRICS = %w[
      first_review_days
      total_handling_days
      review_rounds
      publication_delay_days
    ].freeze
    RATINGS = {
      "overall_rating_0_5" => "overall",
      "speed_rating_0_5" => "speed",
      "communication_rating_0_5" => "communication",
      "review_quality_rating_0_5" => "review_quality",
      "cost_rating_0_5" => "cost",
    }.freeze

    attr_reader :comment

    def initialize(comment, now: Time.current)
      @comment = comment
      @now = now
    end

    def record_id
      comment["record_id"].to_s
    end

    def source
      comment["source_name"].to_s.strip
    end

    def code
      CommentAuthor.code_for(record_id)
    end

    # A comment with neither text nor facts would be a reply holding only its note.
    def postable?
      record_id.present? && (body.present? || facts.present?)
    end

    def raw
      @raw ||= [facts, body, translation].compact_blank.join("\n\n")
    end

    def custom_fields
      {
        "source" => source,
        "code" => code,
        "source_url" => source_url,
        "published_at" => published_at&.iso8601,
        "precision" => published_at && precision,
      }.compact
    end

    def digest
      Digest::SHA1.hexdigest("#{raw}\n#{custom_fields.to_json}")
    end

    # Undated comments take the time they are collected, so they sort last.
    def created_at
      return @now if published_at.nil?

      [published_at, @now].min
    end

    def sort_key
      [created_at.to_f, record_id]
    end

    private

    def t(key, **params)
      I18n.t("discourse_journals.comment_post.#{key}", **params)
    end

    def precision
      precision = comment["published_at_precision"].to_s
      PRECISIONS.include?(precision) ? precision : nil
    end

    def published_at
      return @published_at if defined?(@published_at)

      @published_at = parse_published_at
    end

    def parse_published_at
      return nil if precision.nil?

      match =
        comment["published_at_iso"].to_s.match(
          /\A(\d{4})(?:-(\d{1,2}))?(?:-(\d{1,2}))?(?:[T ](\d{1,2}):(\d{2})(?::(\d{2}))?)?/,
        )
      return nil if match.nil?

      year, month, day, hour, minute, second = match.captures.map { |part| part&.to_i }
      zone = ActiveSupport::TimeZone[TIME_ZONE]

      case precision
      when "datetime"
        zone.local(year, month || 1, day || 1, hour || 0, minute || 0, second || 0)
      when "date"
        zone.local(year, month || 1, day || 1)
      when "month"
        zone.local(year, month || 1, 1)
      when "year"
        zone.local(year, 1, 1)
      end
    rescue ArgumentError
      nil
    end

    def source_url
      url = comment["source_url"].to_s.strip
      url.match?(%r{\Ahttps?://\S+\z}i) ? url : nil
    end

    def body
      @body ||= escape(normalize(comment["comment_text"].presence || comment["comment_text_zh"]))
    end

    # Only English originals get the Chinese text, folded and labelled as a translation.
    def translation
      return nil if comment["original_language"] != "en"

      translated = normalize(comment["comment_text_zh"])
      return nil if translated.blank? || translated == normalize(comment["comment_text"])

      "[details=\"#{t("translation")}\"]\n#{escape(translated)}\n[/details]"
    end

    # Upstream infers some of these from the text; only what it marks as high
    # confidence is shown, so an estimate never reads as the author's own rating.
    def facts
      @facts ||= [status_fact, *time_facts, *rating_facts, *fee_facts].compact.join(" · ").presence
    end

    def confidence(key)
      confidence = comment["confidence"]
      confidence.is_a?(Hash) ? confidence[key].to_s : ""
    end

    def status_fact
      status = comment["paper_status"].to_s
      return nil if confidence("status") != "high" || STATUSES.exclude?(status)

      "**#{t("status.#{status}")}**"
    end

    def time_facts
      return [] if confidence("time_metrics") != "high"

      TIME_METRICS.filter_map do |key|
        value = number(comment[key])
        t("metrics.#{key}", count: value.round) if value&.positive?
      end
    end

    def rating_facts
      return [] if confidence("rating_metrics") != "high"

      RATINGS.filter_map do |field, key|
        value = number(comment[field])
        t("ratings.#{key}", value: format("%.1f", value)) if value
      end
    end

    def fee_facts
      currency = comment["fee_currency"].to_s.strip
      %w[fee_page fee_review].filter_map do |key|
        value = number(comment[key])
        next if value.nil? || !value.positive?

        amount = value == value.round ? value.round.to_s : value.to_s
        t("fees.#{key}", value: [amount, escape(currency)].compact_blank.join(" "))
      end
    end

    def number(value)
      Float(value)
    rescue ArgumentError, TypeError
      nil
    end

    def normalize(text)
      text.to_s.gsub(/\r\n?/, "\n").gsub(/^[ \t]+|[ \t]+$/, "").gsub(/\n{3,}/, "\n\n").strip
    end

    # Comments are plain text: escape anything Markdown or Discourse would turn
    # into formatting, links, mentions or hashtags. (Emoji codes are converted
    # after escapes are resolved, so escaping cannot keep them.)
    def escape(text)
      text
        .to_s
        .gsub(/[\\`*_\[\]{}<>#|~@&!]/) { |char| "\\#{char}" }
        .gsub(/^([-+=])/) { "\\#{$1}" }
        .gsub(/^(\d+)([.)])/) { "#{$1}\\#{$2}" }
    end
  end
end
