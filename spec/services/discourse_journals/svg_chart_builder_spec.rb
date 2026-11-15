# frozen_string_literal: true

describe DiscourseJournals::SvgChartBuilder do
  describe ".line_chart" do
    it "joins a partial year with a dashed segment and labels the last full year" do
      points = [
        { year: 2024, value: 380_000 },
        { year: 2025, value: 400_000 },
        { year: 2026, value: 2024 },
      ]

      svg = described_class.line_chart(points, label: "Citations", partial_year: 2026)

      expect(svg).to include("dj-chart__line--partial", "2026*", ">400K</text>")
    end

    it "draws nothing for fewer than two points" do
      expect(described_class.line_chart([{ year: 2025, value: 1 }], label: "x")).to eq("")
    end
  end

  describe ".bar_chart" do
    it "draws the part bar inside the total bar" do
      svg =
        described_class.bar_chart(
          [{ year: 2025, total: 100, part: 40 }, { year: 2026, total: 50, part: 0 }],
          label: "Articles",
        )

      expect(svg.scan("dj-chart__bar--part").size).to eq(1)
      expect(svg).to include(%(aria-label="Articles"))
    end
  end

  describe ".star_rating" do
    it "clips the filled stars to the rating" do
      expect(described_class.star_rating(2.5, label: "2.5 of 5")).to include("width: 50.0%")
    end
  end
end
