# frozen_string_literal: true

module DiscourseJournals
  # The note under a collected comment saying where and when it was first
  # published. Built from the post's custom field when it is served, so the
  # setting can switch it on and off without touching the posts.
  module CommentSourceNote
    # Every comment timed to the minute comes from a Chinese site, and those
    # show Beijing time; the rest only carry a date, a year or nothing.
    TIME_ZONE = "Asia/Shanghai"

    PRECISIONS = %w[datetime date month year].freeze

    def self.enabled?
      SiteSetting.discourse_journals_comment_source_note_enabled
    end

    # `value` is the post's custom field (see CommentAuthor.fields).
    def self.display(value)
      fields = CommentAuthor.fields(value)
      return nil if fields.nil?

      source = fields["source"].to_s.strip.presence || t("unknown_source")
      url = fields["source_url"].to_s
      {
        text: t("note", source: source, published: published_text(fields)),
        url: url.match?(%r{\Ahttps?://\S+\z}i) ? url : nil,
      }
    end

    def self.published_text(fields)
      precision = fields["precision"].to_s
      time = parse_time(fields["published_at"])
      return t("published.unknown") if time.nil? || PRECISIONS.exclude?(precision)

      case precision
      when "datetime"
        t("published.at", date: time.strftime("%Y-%m-%d %H:%M"))
      when "date"
        t("published.at", date: time.strftime("%Y-%m-%d"))
      when "month"
        t("published.month", year: time.year, month: time.month)
      else
        t("published.year", year: time.year)
      end
    end

    def self.parse_time(value)
      return nil if value.blank?

      Time.iso8601(value.to_s).in_time_zone(TIME_ZONE)
    rescue ArgumentError
      nil
    end

    def self.t(key, **params)
      I18n.t("discourse_journals.comment_post.#{key}", **params)
    end

    private_class_method :parse_time, :t
  end
end
