# frozen_string_literal: true

module DiscourseJournals
  # Static inline SVG for the journal page. Colors come from CSS classes
  # (`dj-chart__*`) so one cooked post works under every site color scheme.
  class SvgChartBuilder
    WIDTH = 360
    HEIGHT = 170
    BAR_PAD = { l: 34, r: 6, t: 8, b: 22 }.freeze
    LINE_PAD = { l: 34, r: 34, t: 14, b: 22 }.freeze
    STAR_PATH = "M8 1.2l2 4.3 4.7.6-3.5 3.2.9 4.6L8 11.6l-4.1 2.3.9-4.6L1.3 6.1 6 5.5z"

    # rows: [{ year:, total:, part: }]. `part` (e.g. open-access works) is drawn
    # solid inside the faint `total` bar.
    def self.bar_chart(rows, label:, partial_year: nil)
      return "" if rows.blank?

      max = nice_max(rows.map { |r| r[:total].to_f }.max)
      inner_w = WIDTH - BAR_PAD[:l] - BAR_PAD[:r]
      inner_h = HEIGHT - BAR_PAD[:t] - BAR_PAD[:b]
      slot = inner_w / rows.size.to_f
      bar_w = [slot * 0.62, 4].max
      every = label_step(rows.size)

      marks =
        rows.each_with_index.map do |row, i|
          x = BAR_PAD[:l] + slot * i + (slot - bar_w) / 2
          partial = row[:year] == partial_year ? " is-partial" : ""
          parts = [
            bar(x, bar_w, row[:total].to_f / max * inner_h, inner_h, "dj-chart__bar#{partial}"),
          ]
          part_h = row[:part].to_f / max * inner_h
          if part_h.positive?
            parts << bar(x, bar_w, part_h, inner_h, "dj-chart__bar dj-chart__bar--part#{partial}")
          end
          if i % every == 0 || i == rows.size - 1
            parts << x_label(x + bar_w / 2, row[:year], row[:year] == partial_year)
          end
          parts.join
        end

      svg(label) { grid(BAR_PAD, max) + marks.join }
    end

    # points: [{ year:, value: }]. A partial (still running) year is joined with
    # a dashed segment so its drop does not read as a real decline.
    def self.line_chart(points, label:, partial_year: nil, digits: 0)
      points = Array(points).reject { |p| p[:value].nil? }
      return "" if points.size < 2

      max = nice_max(points.map { |p| p[:value].to_f }.max)
      inner_w = WIDTH - LINE_PAD[:l] - LINE_PAD[:r]
      inner_h = HEIGHT - LINE_PAD[:t] - LINE_PAD[:b]
      x = ->(i) { LINE_PAD[:l] + inner_w * i / (points.size - 1).to_f }
      y = ->(v) { LINE_PAD[:t] + inner_h * (1 - v.to_f / max) }

      settled = points.reject { |p| p[:year] == partial_year }
      settled = points if settled.empty?
      path =
        settled
          .each_with_index
          .map { |p, i| "#{i.zero? ? "M" : "L"}#{r1(x.(i))},#{r1(y.(p[:value]))}" }
          .join(" ")
      baseline = LINE_PAD[:t] + inner_h

      parts = [grid(LINE_PAD, max)]
      if settled.size > 1
        parts << %(<path class="dj-chart__area" d="#{path} L#{r1(x.(settled.size - 1))},#{baseline} L#{r1(x.(0))},#{baseline} Z"/>)
      end
      parts << %(<path class="dj-chart__line" d="#{path}"/>)
      if settled.size < points.size
        j = settled.size - 1
        k = points.size - 1
        parts << %(<path class="dj-chart__line dj-chart__line--partial" d="M#{r1(x.(j))},#{r1(y.(settled[j][:value]))} L#{r1(x.(k))},#{r1(y.(points[k][:value]))}"/>)
      end

      last = settled.last
      lx = x.(settled.size - 1)
      ly = y.(last[:value])
      value = digits.positive? ? format("%.#{digits}f", last[:value].to_f) : compact(last[:value])
      parts << %(<circle class="dj-chart__dot" cx="#{r1(lx)}" cy="#{r1(ly)}" r="3.5"/>)
      parts << %(<text class="dj-chart__value" x="#{r1(lx)}" y="#{r1(ly - 9)}" text-anchor="middle">#{value}</text>)

      every = label_step(points.size)
      points.each_with_index do |p, i|
        next unless i % every == 0 || i == points.size - 1
        parts << x_label(x.(i), p[:year], p[:year] == partial_year)
      end

      svg(label) { parts.join }
    end

    def self.sparkline(values)
      values = Array(values).compact.map(&:to_f)
      return "" if values.size < 2

      w = 120
      h = 22
      min, max = values.minmax
      span = (max - min).nonzero? || 1
      pts =
        values.each_with_index.map do |v, i|
          [i * (w - 6) / (values.size - 1).to_f + 3, h - 4 - (v - min) / span * (h - 8)]
        end
      d =
        pts
          .each_with_index
          .map { |(px, py), i| "#{i.zero? ? "M" : "L"}#{r1(px)},#{r1(py)}" }
          .join(" ")
      lx, ly = pts.last

      %(<svg class="dj-key__spark" viewBox="0 0 #{w} #{h}" aria-hidden="true"><path d="#{d}"/><circle cx="#{r1(lx)}" cy="#{r1(ly)}" r="2.4"/></svg>)
    end

    # Two identical rows of stars; the colored one is clipped by width, which
    # needs no gradient ids and so stays valid when several render on a page.
    def self.star_rating(value, label:)
      pct = (value.to_f.clamp(0, 5) / 5 * 100).round(1)
      stars = (0..4).map { |i| %(<path transform="translate(#{i * 16} 0)" d="#{STAR_PATH}"/>) }.join
      row = %(<svg viewBox="0 0 80 16" aria-hidden="true">#{stars}</svg>)

      %(<span class="dj-stars" role="img" aria-label="#{ERB::Util.html_escape(label)}"><span class="dj-stars__base">#{row}</span><span class="dj-stars__fill" style="width: #{pct}%">#{row}</span></span>)
    end

    def self.compact(value)
      v = value.to_f
      if v.abs >= 1_000_000
        "#{trim(v / 1_000_000.0, 1)}M"
      elsif v.abs >= 10_000
        "#{(v / 1_000.0).round}K"
      elsif v.abs >= 1_000
        "#{trim(v / 1_000.0, 1)}K"
      else
        trim(v, 1).to_s
      end
    end

    class << self
      private

      def svg(label)
        %(<svg viewBox="0 0 #{WIDTH} #{HEIGHT}" role="img" aria-label="#{ERB::Util.html_escape(label)}">#{yield}</svg>)
      end

      def grid(pad, max)
        inner_h = HEIGHT - pad[:t] - pad[:b]
        [0, 0.5, 1].map do |f|
            y = r1(pad[:t] + inner_h * (1 - f))
            %(<line class="dj-chart__grid" x1="#{pad[:l]}" x2="#{WIDTH - pad[:r]}" y1="#{y}" y2="#{y}"/>) +
              %(<text class="dj-chart__axis" x="#{pad[:l] - 6}" y="#{r1(y + 3)}" text-anchor="end">#{compact(max * f)}</text>)
          end
          .join
      end

      def bar(x, width, height, inner_h, css)
        %(<rect class="#{css}" x="#{r1(x)}" y="#{r1(BAR_PAD[:t] + inner_h - height)}" width="#{r1(width)}" height="#{r1(height)}" rx="2"/>)
      end

      def x_label(x, year, partial)
        %(<text class="dj-chart__axis" x="#{r1(x)}" y="#{HEIGHT - 6}" text-anchor="middle">#{year.to_i}#{"*" if partial}</text>)
      end

      def label_step(count)
        if count > 10
          3
        elsif count > 6
          2
        else
          1
        end
      end

      def nice_max(value)
        value = value.to_f
        return 1 if value <= 0

        magnitude = 10**Math.log10(value).floor
        normalized = value / magnitude
        step =
          if normalized <= 1
            1
          elsif normalized <= 2
            2
          elsif normalized <= 2.5
            2.5
          elsif normalized <= 5
            5
          else
            10
          end
        step * magnitude
      end

      def trim(value, digits)
        rounded = value.round(digits)
        rounded == rounded.to_i ? rounded.to_i : rounded
      end

      def r1(value)
        value.to_f.round(1)
      end
    end
  end
end
