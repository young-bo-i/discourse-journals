# frozen_string_literal: true

module DiscourseJournals
  class SvgChartBuilder
    VIEWBOX_W = 340
    VIEWBOX_H = 160
    WIDE_W = 700
    WIDE_H = 200
    PAD_LEFT = 45
    PAD_RIGHT = 10
    PAD_TOP = 10
    PAD_BOTTOM = 25
    Y_TICKS = 5
    FONT_SIZE = 11

    def self.line_chart(points, color: "#7ac36a", width: VIEWBOX_W, height: VIEWBOX_H, years: nil)
      return "" if points.nil? || points.size < 2
      min_val, max_val = value_range(points)
      coords = chart_coords(points, min_val, max_val, width, height)
      path = coords.map { |x, y| "#{x.round(1)},#{y.round(1)}" }.join(" ")

      svg_tag(width, height) do
        parts = []
        parts << grid_and_y_labels(min_val, max_val, width, height)
        parts << x_labels(years, width, height) if years
        parts << %(<polyline points="#{path}" fill="none" stroke="#{color}" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round" />)
        parts.join("\n    ")
      end
    end

    def self.area_chart(series_a, series_b, color_a: "rgba(122,195,106,0.5)", color_b: "rgba(56,133,200,0.35)", width: VIEWBOX_W, height: VIEWBOX_H, years: nil)
      return "" if (series_a.nil? || series_a.size < 2) && (series_b.nil? || series_b.size < 2)

      all_values = (series_a || []) + (series_b || [])
      min_val = all_values.min || 0
      max_val = all_values.max || 1
      max_val = min_val + 1 if max_val == min_val

      svg_tag(width, height) do
        parts = []
        parts << grid_and_y_labels(min_val, max_val, width, height)
        parts << x_labels(years, width, height) if years

        [
          [series_a, color_a],
          [series_b, color_b],
        ].each do |series, color|
          next if series.nil? || series.size < 2
          coords = chart_coords(series, min_val, max_val, width, height)
          top_path = coords.map { |x, y| "#{x.round(1)} #{y.round(1)}" }.join(" L")
          baseline_y = height - PAD_BOTTOM
          parts << %(<path d="M#{coords.first[0].round(1)} #{baseline_y} L#{top_path} L#{coords.last[0].round(1)} #{baseline_y} Z" fill="#{color}" stroke="none" />)
        end

        parts.join("\n    ")
      end
    end

    def self.from_time_series(data, value_key:, **opts)
      return "" if data.nil? || data.size < 2
      values = data.map { |d| d[value_key].to_f }
      years = data.map { |d| d[:year] }.compact
      line_chart(values, years: years.size == values.size ? years : nil, **opts)
    end

    def self.dual_from_time_series(data, key_a:, key_b:, **opts)
      return "" if data.nil? || data.size < 2
      series_a = data.map { |d| d[key_a].to_f }
      series_b = data.map { |d| d[key_b].to_f }
      years = data.map { |d| d[:year] }.compact
      all_values = series_a + series_b
      min_val = all_values.min || 0
      max_val = all_values.max || 1
      max_val = min_val + 1 if max_val == min_val
      width = opts.delete(:width) || VIEWBOX_W
      height = opts.delete(:height) || VIEWBOX_H

      svg_tag(width, height) do
        parts = []
        parts << grid_and_y_labels(min_val, max_val, width, height)
        parts << x_labels(years.size == series_a.size ? years : nil, width, height)

        coords_a = chart_coords(series_a, min_val, max_val, width, height)
        path_a = coords_a.map { |x, y| "#{x.round(1)},#{y.round(1)}" }.join(" ")
        color_a = opts[:color_a] || "#7ac36a"
        parts << %(<polyline points="#{path_a}" fill="none" stroke="#{color_a}" stroke-width="2.5" stroke-linecap="round" />)

        coords_b = chart_coords(series_b, min_val, max_val, width, height)
        path_b = coords_b.map { |x, y| "#{x.round(1)},#{y.round(1)}" }.join(" ")
        color_b = opts[:color_b] || "#3885c8"
        parts << %(<polyline points="#{path_b}" fill="none" stroke="#{color_b}" stroke-width="2.5" stroke-linecap="round" />)

        parts.join("\n    ")
      end
    end

    def self.area_from_time_series(data, key_a:, key_b:, **opts)
      return "" if data.nil? || data.size < 2
      series_a = data.map { |d| d[key_a].to_f }
      series_b = data.map { |d| d[key_b].to_f }
      years = data.map { |d| d[:year] }.compact
      area_chart(series_a, series_b, years: years.size == series_a.size ? years : nil, **opts)
    end

    DONUT_COLORS = %w[#e77642 #3885c8 #7ac36a #9b59b6 #f1c40f #1abc9c #e74c3c #34495e].freeze

    def self.donut(segments, size: 150, thickness: 28)
      return "" if segments.nil? || segments.empty?

      total = segments.sum { |s| s[:value].to_f }
      return "" if total <= 0

      r = (size / 2.0) - 2
      inner_r = r - thickness
      cx = cy = size / 2.0
      circumference = 2 * Math::PI * r

      parts = []
      offset = 0.0

      segments.each_with_index do |seg, i|
        pct = seg[:value].to_f / total
        dash = pct * circumference
        gap = circumference - dash
        color = DONUT_COLORS[i % DONUT_COLORS.size]

        parts << %(<circle cx="#{cx}" cy="#{cx}" r="#{r.round(1)}" fill="none" stroke="#{color}" stroke-width="#{thickness}" ) +
          %(stroke-dasharray="#{dash.round(2)} #{gap.round(2)}" stroke-dashoffset="#{(-offset).round(2)}" ) +
          %(transform="rotate(-90 #{cx} #{cy})" />)
        offset += dash
      end

      parts << %(<circle cx="#{cx}" cy="#{cy}" r="#{inner_r.round(1)}" fill="var(--secondary, #fff)" />)

      %(<svg viewBox="0 0 #{size} #{size}" width="#{size}" height="#{size}" role="img" xmlns="http://www.w3.org/2000/svg">\n    #{parts.join("\n    ")}\n  </svg>)
    end

    def self.progress_bar(percent, color: "#3885c8", width: 200, height: 18)
      pct = percent.to_f.clamp(0, 100)
      fill_w = (pct / 100.0 * width).round(1)
      r = (height / 2.0).round(1)

      %(<svg viewBox="0 0 #{width} #{height}" width="100%" height="#{height}" role="img" xmlns="http://www.w3.org/2000/svg" style="font-family:system-ui,sans-serif">) +
        %(<rect x="0" y="0" width="#{width}" height="#{height}" rx="#{r}" fill="currentColor" opacity="0.08" />) +
        %(<rect x="0" y="0" width="#{fill_w}" height="#{height}" rx="#{r}" fill="#{color}" opacity="0.85" />) +
        %(</svg>)
    end

    def self.star_rating(value, max: 5, size: 16)
      val = value.to_f.clamp(0, max)
      stars = (0...max).map { |i|
        fill = if val >= i + 1
          "currentColor"
        elsif val > i
          "url(#dj-star-half-#{i})"
        else
          "none"
        end
        stroke = "currentColor"
        half_pct = ((val - i).clamp(0, 1) * 100).round(0)

        defs = if val > i && val < i + 1
          %(<defs><linearGradient id="dj-star-half-#{i}"><stop offset="#{half_pct}%" stop-color="currentColor"/><stop offset="#{half_pct}%" stop-color="transparent"/></linearGradient></defs>)
        else
          ""
        end

        x_offset = i * (size + 3)
        %(<svg x="#{x_offset}" y="0" width="#{size}" height="#{size}" viewBox="0 0 24 24">#{defs}<path d="M12 2l3.09 6.26L22 9.27l-5 4.87 1.18 6.88L12 17.77l-6.18 3.25L7 14.14 2 9.27l6.91-1.01L12 2z" fill="#{fill}" stroke="#{stroke}" stroke-width="1.5" opacity="0.8"/></svg>)
      }.join

      total_w = max * (size + 3) - 3
      %(<svg viewBox="0 0 #{total_w} #{size}" width="#{total_w}" height="#{size}" role="img" xmlns="http://www.w3.org/2000/svg">#{stars}</svg>)
    end

    class << self
      private

      def svg_tag(width, height, &block)
        content = block.call
        %(<svg viewBox="0 0 #{width} #{height}" role="img" xmlns="http://www.w3.org/2000/svg" style="font-family:system-ui,sans-serif">\n    #{content}\n  </svg>)
      end

      def value_range(values)
        min_val = values.min
        max_val = values.max
        max_val = min_val + 1 if max_val == min_val
        [min_val, max_val]
      end

      def chart_coords(values, min_val, max_val, width, height)
        usable_w = width - PAD_LEFT - PAD_RIGHT
        usable_h = height - PAD_TOP - PAD_BOTTOM
        count = values.size

        values.each_with_index.map do |val, i|
          x = PAD_LEFT + (i.to_f / (count - 1)) * usable_w
          y = PAD_TOP + (1.0 - (val - min_val).to_f / (max_val - min_val)) * usable_h
          [x, y]
        end
      end

      def grid_and_y_labels(min_val, max_val, width, height)
        usable_h = height - PAD_TOP - PAD_BOTTOM
        x_start = PAD_LEFT
        x_end = width - PAD_RIGHT
        parts = []

        Y_TICKS.times do |i|
          frac = i.to_f / (Y_TICKS - 1)
          y = PAD_TOP + (1.0 - frac) * usable_h
          val = min_val + frac * (max_val - min_val)
          label = format_axis_value(val)

          parts << %(<line x1="#{x_start}" x2="#{x_end}" y1="#{y.round(1)}" y2="#{y.round(1)}" stroke="currentColor" opacity="0.12" stroke-dasharray="3 3" />)
          parts << %(<text x="#{x_start - 4}" y="#{(y + 4).round(1)}" text-anchor="end" fill="currentColor" opacity="0.5" font-size="#{FONT_SIZE}">#{label}</text>)
        end

        parts.join("\n    ")
      end

      def x_labels(years, width, height)
        return "" if years.nil? || years.empty?
        usable_w = width - PAD_LEFT - PAD_RIGHT
        count = years.size
        label_y = height - 4

        step = if count <= 8
          1
        elsif count <= 15
          2
        elsif count <= 25
          3
        else
          (count / 7.0).ceil
        end

        parts = []
        years.each_with_index do |yr, i|
          next unless i % step == 0 || i == count - 1
          x = PAD_LEFT + (i.to_f / (count - 1)) * usable_w
          parts << %(<text x="#{x.round(1)}" y="#{label_y}" text-anchor="middle" fill="currentColor" opacity="0.5" font-size="#{FONT_SIZE}">#{yr}</text>)
        end

        parts.join("\n    ")
      end

      def format_axis_value(val)
        if val.abs >= 1_000_000
          "#{(val / 1_000_000.0).round(1)}M"
        elsif val.abs >= 10_000
          "#{(val / 1_000.0).round(0)}K"
        elsif val.abs >= 1_000
          "#{(val / 1_000.0).round(1)}K"
        elsif val == val.to_i.to_f
          val.to_i.to_s
        else
          format("%.1f", val)
        end
      end
    end
  end
end
