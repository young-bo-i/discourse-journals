# frozen_string_literal: true

module DiscourseJournals
  class SvgChartBuilder
    VIEWBOX_W = 340
    VIEWBOX_H = 120
    WIDE_W = 700
    WIDE_H = 160
    PADDING = 10

    def self.line_chart(points, color: "#7ac36a", width: VIEWBOX_W, height: VIEWBOX_H)
      return "" if points.nil? || points.size < 2
      coords = map_coords(points, width, height)
      path = coords.map { |x, y| "#{x.round(1)},#{y.round(1)}" }.join(" ")

      svg_tag(width, height) do
        %(<polyline points="#{path}" fill="none" stroke="#{color}" stroke-width="3" stroke-linecap="round" />)
      end
    end

    def self.dual_line_chart(series_a, series_b, color_a: "#7ac36a", color_b: "#3885c8", width: VIEWBOX_W, height: VIEWBOX_H)
      return "" if (series_a.nil? || series_a.size < 2) && (series_b.nil? || series_b.size < 2)

      all_values = (series_a || []) + (series_b || [])
      min_val = all_values.min || 0
      max_val = all_values.max || 1
      max_val = min_val + 1 if max_val == min_val

      lines = []
      if series_a && series_a.size >= 2
        coords_a = map_coords_with_range(series_a, min_val, max_val, width, height)
        path_a = coords_a.map { |x, y| "#{x.round(1)},#{y.round(1)}" }.join(" ")
        lines << %(<polyline points="#{path_a}" fill="none" stroke="#{color_a}" stroke-width="3" stroke-linecap="round" />)
      end
      if series_b && series_b.size >= 2
        coords_b = map_coords_with_range(series_b, min_val, max_val, width, height)
        path_b = coords_b.map { |x, y| "#{x.round(1)},#{y.round(1)}" }.join(" ")
        lines << %(<polyline points="#{path_b}" fill="none" stroke="#{color_b}" stroke-width="3" stroke-linecap="round" />)
      end

      svg_tag(width, height) { lines.join("\n    ") }
    end

    def self.area_chart(series_a, series_b, color_a: "rgba(122,195,106,0.6)", color_b: "rgba(237,125,115,0.6)", width: VIEWBOX_W, height: VIEWBOX_H)
      return "" if (series_a.nil? || series_a.size < 2) && (series_b.nil? || series_b.size < 2)

      all_values = (series_a || []) + (series_b || [])
      min_val = all_values.min || 0
      max_val = all_values.max || 1
      max_val = min_val + 1 if max_val == min_val

      areas = []
      [
        [series_a, color_a],
        [series_b, color_b],
      ].each do |series, color|
        next if series.nil? || series.size < 2
        coords = map_coords_with_range(series, min_val, max_val, width, height)
        top_path = coords.map { |x, y| "#{x.round(1)} #{y.round(1)}" }.join(" L")
        baseline_y = height - PADDING
        areas << %(<path d="M#{coords.first[0].round(1)} #{baseline_y} L#{top_path} L#{coords.last[0].round(1)} #{baseline_y} Z" fill="#{color}" stroke="none" />)
      end

      svg_tag(width, height) { areas.join("\n    ") }
    end

    def self.from_time_series(data, value_key:, **opts)
      return "" if data.nil? || data.size < 2
      values = data.map { |d| d[value_key].to_f }
      line_chart(values, **opts)
    end

    def self.dual_from_time_series(data, key_a:, key_b:, **opts)
      return "" if data.nil? || data.size < 2
      series_a = data.map { |d| d[key_a].to_f }
      series_b = data.map { |d| d[key_b].to_f }
      dual_line_chart(series_a, series_b, **opts)
    end

    def self.area_from_time_series(data, key_a:, key_b:, **opts)
      return "" if data.nil? || data.size < 2
      series_a = data.map { |d| d[key_a].to_f }
      series_b = data.map { |d| d[key_b].to_f }
      area_chart(series_a, series_b, **opts)
    end

    class << self
      private

      def svg_tag(width, height, &block)
        content = block.call
        %(<svg viewBox="0 0 #{width} #{height}" role="img" xmlns="http://www.w3.org/2000/svg">\n    #{content}\n  </svg>)
      end

      def map_coords(values, width, height)
        return [] if values.empty?
        min_val = values.min
        max_val = values.max
        max_val = min_val + 1 if max_val == min_val
        map_coords_with_range(values, min_val, max_val, width, height)
      end

      def map_coords_with_range(values, min_val, max_val, width, height)
        usable_w = width - 2 * PADDING
        usable_h = height - 2 * PADDING
        count = values.size

        values.each_with_index.map do |val, i|
          x = PADDING + (i.to_f / (count - 1)) * usable_w
          y = PADDING + (1.0 - (val - min_val).to_f / (max_val - min_val)) * usable_h
          [x, y]
        end
      end
    end
  end
end
