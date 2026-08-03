# frozen_string_literal: true

module DiscourseJournals
  # Daily aggregate of promo-carousel impressions and clicks, one row per
  # (day, slide). Tracking uses an atomic upsert so concurrent hits never lose
  # increments and no per-event rows are stored (privacy + volume friendly).
  class PromoStat < ActiveRecord::Base
    self.table_name = "discourse_journals_promo_stats"

    # Slide keys mirror the frontend carousel (journal-promo.gjs) plus the
    # site-wide header banner (below-site-header/scholay-banner.gjs).
    SLIDES = %w[peer_review prism claw banner].freeze
    EVENTS = %w[impression click].freeze

    DEFAULT_RANGE_DAYS = 30
    MAX_RANGE_DAYS = 365

    def self.track!(slide:, event:)
      slide = slide.to_s
      event = event.to_s
      return false unless SLIDES.include?(slide) && EVENTS.include?(event)

      imp = event == "impression" ? 1 : 0
      clk = event == "click" ? 1 : 0

      DB.exec(<<~SQL, day: Time.zone.today, slide: slide, imp: imp, clk: clk)
        INSERT INTO discourse_journals_promo_stats (day, slide, impressions, clicks, created_at, updated_at)
        VALUES (:day, :slide, :imp, :clk, now(), now())
        ON CONFLICT (day, slide) DO UPDATE SET
          impressions = discourse_journals_promo_stats.impressions + :imp,
          clicks = discourse_journals_promo_stats.clicks + :clk,
          updated_at = now()
      SQL

      true
    end

    # Builds a daily series (zero-filled) plus per-slide and overall totals for
    # the admin chart.
    def self.report(days = DEFAULT_RANGE_DAYS)
      range_days = days.to_i.clamp(1, MAX_RANGE_DAYS)
      end_day = Time.zone.today
      start_day = end_day - (range_days - 1)

      labels = (start_day..end_day).map(&:to_s)
      keys = SLIDES + ["total"]

      impressions = {}
      clicks = {}
      keys.each do |key|
        impressions[key] = Array.new(labels.size, 0)
        clicks[key] = Array.new(labels.size, 0)
      end

      index_for = labels.each_with_index.to_h

      where("day >= ?", start_day).find_each do |row|
        i = index_for[row.day.to_s]
        next if i.nil?

        impressions[row.slide][i] += row.impressions if impressions.key?(row.slide)
        clicks[row.slide][i] += row.clicks if clicks.key?(row.slide)
        impressions["total"][i] += row.impressions
        clicks["total"][i] += row.clicks
      end

      series = {}
      totals = {}
      keys.each do |key|
        imp = impressions[key]
        clk = clicks[key]
        series[key] = {
          impressions: imp,
          clicks: clk,
          ctr: imp.each_with_index.map { |v, i| ctr(clk[i], v) },
        }
        total_imp = imp.sum
        total_clk = clk.sum
        totals[key] = {
          impressions: total_imp,
          clicks: total_clk,
          ctr: ctr(total_clk, total_imp),
        }
      end

      { days: labels, range_days: range_days, series: series, totals: totals }
    end

    def self.ctr(clicks, impressions)
      return 0.0 if impressions.to_i <= 0

      ((clicks.to_f / impressions) * 100).round(2)
    end
  end
end
