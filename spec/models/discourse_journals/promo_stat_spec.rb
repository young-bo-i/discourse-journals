# frozen_string_literal: true

describe DiscourseJournals::PromoStat do
  describe ".track!" do
    it "creates and then increments the daily row for a slide" do
      described_class.track!(slide: "banner", event: "impression")
      described_class.track!(slide: "banner", event: "impression")

      row = described_class.find_by(day: Time.zone.today, slide: "banner")
      expect(row.impressions).to eq(2)
      expect(row.clicks).to eq(0)
    end

    it "counts clicks separately from impressions on the same row" do
      described_class.track!(slide: "banner", event: "impression")
      described_class.track!(slide: "banner", event: "click")

      row = described_class.find_by(day: Time.zone.today, slide: "banner")
      expect(row.impressions).to eq(1)
      expect(row.clicks).to eq(1)
    end

    it "ignores unknown slides and events without writing a row" do
      expect(described_class.track!(slide: "bogus", event: "click")).to eq(false)
      expect(described_class.track!(slide: "banner", event: "hover")).to eq(false)
      expect(described_class.count).to eq(0)
    end

    it "rejects the retired topic-navigation carousel slides" do
      %w[peer_review prism claw].each do |retired|
        expect(described_class.track!(slide: retired, event: "impression")).to eq(false)
      end

      expect(described_class.count).to eq(0)
    end
  end

  describe ".report" do
    it "returns a zero-filled daily series for an empty range" do
      report = described_class.report(7)

      expect(report[:range_days]).to eq(7)
      expect(report[:days].size).to eq(7)
      expect(report[:days].last).to eq(Time.zone.today.to_s)
      expect(report[:series]["total"][:impressions]).to eq(Array.new(7, 0))
      expect(report[:totals]["total"]).to eq(impressions: 0, clicks: 0, ctr: 0.0)
    end

    it "aggregates per-slide and total counts with CTR" do
      today = Time.zone.today
      described_class.create!(day: today, slide: "banner", impressions: 100, clicks: 10)
      described_class.create!(day: today - 1, slide: "banner", impressions: 100, clicks: 0)

      report = described_class.report(7)

      expect(report[:totals]["banner"]).to eq(impressions: 200, clicks: 10, ctr: 5.0)
      expect(report[:totals]["total"]).to eq(impressions: 200, clicks: 10, ctr: 5.0)
      expect(report[:series]["banner"][:impressions].last).to eq(100)
      expect(report[:series]["total"][:clicks].last).to eq(10)
    end

    it "ignores leftover rows from the retired carousel slides" do
      today = Time.zone.today
      described_class.create!(day: today, slide: "banner", impressions: 10, clicks: 1)
      described_class.create!(day: today, slide: "claw", impressions: 999, clicks: 99)

      report = described_class.report(7)

      # The historical rows stay in the table but must not leak into "total",
      # which would otherwise show counts no per-slide series can explain.
      expect(report[:totals]["total"]).to eq(impressions: 10, clicks: 1, ctr: 10.0)
      expect(report[:series]).not_to have_key("claw")
    end

    it "excludes rows older than the requested range" do
      described_class.create!(
        day: Time.zone.today - 10,
        slide: "banner",
        impressions: 999,
        clicks: 99,
      )

      report = described_class.report(7)

      expect(report[:totals]["total"][:impressions]).to eq(0)
    end

    it "clamps an out-of-bounds range to the maximum" do
      report = described_class.report(10_000)

      expect(report[:range_days]).to eq(described_class::MAX_RANGE_DAYS)
    end
  end
end
