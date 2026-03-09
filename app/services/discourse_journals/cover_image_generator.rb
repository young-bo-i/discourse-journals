# frozen_string_literal: true

require "cgi"

module DiscourseJournals
  class CoverImageGenerator
    WIDTH = 900
    HEIGHT = 1200
    COVER_VERSION = "academic_clean_v1"
    PALETTES = [
      {
        background: "#F5F1E8",
        panel: "#FCFBF7",
        border: "#1F3A5F",
        accent: "#B7791F",
        text: "#10233A",
        muted: "#425466",
      },
      {
        background: "#F3F5F7",
        panel: "#FFFFFF",
        border: "#1E2A38",
        accent: "#0F766E",
        text: "#16202A",
        muted: "#52606D",
      },
      {
        background: "#F8F4F0",
        panel: "#FFFDFB",
        border: "#3B3054",
        accent: "#A34A28",
        text: "#21182F",
        muted: "#5E526E",
      },
      {
        background: "#EEF2F4",
        panel: "#FBFCFD",
        border: "#213547",
        accent: "#8A5A44",
        text: "#10202F",
        muted: "#4C6272",
      },
    ].freeze

    class << self
      def generate(title:, issn: nil, country: nil, publisher: nil)
        new(title: title, issn: issn, country: country, publisher: publisher).generate
      end

      def cjk_font
        return @cjk_font if defined?(@cjk_font)

        @cjk_font =
          begin
            output = `magick -list font 2>/dev/null`
            candidates = %w[
              Noto-Sans-CJK-SC
              WenQuanYi-Micro-Hei
              Noto-Sans-SC
              WenQuanYi-Zen-Hei
            ]
            candidates.find { |font| output.include?(font) }
          rescue StandardError
            nil
          end
      end

      def text_font
        cjk_font || "NimbusSans-Regular"
      end
    end

    def initialize(title:, issn: nil, country: nil, publisher: nil)
      @title = title.presence || I18n.t("discourse_journals.render.unknown_journal")
      @issn = issn.presence
      @country = country.presence
      @publisher = publisher.presence
    end

    def generate
      svg_file = Tempfile.new(["journal_cover_", ".svg"])
      output_file = Tempfile.new(["journal_cover_", ".png"])

      svg_file.write(build_svg)
      svg_file.flush

      Discourse::Utils.execute_command("magick", svg_file.path, output_file.path)
      output_file.rewind
      output_file
    ensure
      svg_file&.close!
    end

    private

    def build_svg
      palette = select_palette
      title_lines = wrap_title(@title)
      meta_lines = build_meta_lines
      font = self.class.text_font

      <<~SVG
        <svg xmlns="http://www.w3.org/2000/svg" width="#{WIDTH}" height="#{HEIGHT}" viewBox="0 0 #{WIDTH} #{HEIGHT}">
          <rect width="#{WIDTH}" height="#{HEIGHT}" fill="#{palette[:background]}"/>
          <rect x="38" y="38" width="#{WIDTH - 76}" height="#{HEIGHT - 76}" rx="18" fill="#{palette[:panel]}" stroke="#{palette[:border]}" stroke-width="4"/>
          <rect x="38" y="38" width="#{WIDTH - 76}" height="20" fill="#{palette[:accent]}"/>
          <rect x="72" y="90" width="#{WIDTH - 144}" height="120" rx="12" fill="none" stroke="#{palette[:border]}" stroke-opacity="0.12" stroke-width="2"/>
          <rect x="72" y="250" width="110" height="#{HEIGHT - 392}" rx="12" fill="#{palette[:border]}" fill-opacity="0.06"/>
          <rect x="738" y="250" width="90" height="#{HEIGHT - 392}" rx="12" fill="#{palette[:accent]}" fill-opacity="0.08"/>
          #{build_decorative_lines(palette)}
          <text x="92" y="142" font-family="#{xml_escape(font)}" font-size="28" font-weight="700" letter-spacing="6" fill="#{palette[:border]}">JOURNAL</text>
          <text x="92" y="178" font-family="#{xml_escape(font)}" font-size="20" font-weight="400" letter-spacing="2" fill="#{palette[:muted]}">ACADEMIC EDITION</text>
          <rect x="92" y="220" width="716" height="4" fill="#{palette[:accent]}"/>
          #{build_issue_badge(palette, font)}
          #{build_title_block(title_lines, palette, font)}
          #{build_meta_block(meta_lines, palette, font)}
          #{build_footer_block(palette, font)}
        </svg>
      SVG
    end

    def select_palette
      seed = Digest::SHA256.digest([@title, @publisher].compact.join("|")).bytes.first
      PALETTES[seed % PALETTES.length]
    end

    def build_issue_badge(palette, font)
      label = xml_escape([@country, @issn].compact.join("  ·  ").presence || "Indexed Journal")

      <<~SVG
        <rect x="560" y="102" width="248" height="72" rx="16" fill="#{palette[:border]}"/>
        <text x="684" y="147" text-anchor="middle" font-family="#{xml_escape(font)}" font-size="24" font-weight="600" fill="#{palette[:panel]}">#{label}</text>
      SVG
    end

    def build_title_block(lines, palette, font)
      y = 380
      rendered_lines = lines.each_with_index.map do |line, index|
        line_y = y + index * 72
        %(<text x="240" y="#{line_y}" font-family="#{xml_escape(font)}" font-size="54" font-weight="700" fill="#{palette[:text]}">#{xml_escape(line)}</text>)
      end.join("\n")

      <<~SVG
        <rect x="214" y="304" width="540" height="404" rx="24" fill="#{palette[:panel]}" stroke="#{palette[:border]}" stroke-opacity="0.12" stroke-width="2"/>
        #{rendered_lines}
      SVG
    end

    def build_meta_block(lines, palette, font)
      return "" if lines.empty?

      base_y = 792
      rows = lines.each_with_index.map do |line, index|
        row_y = base_y + index * 44
        %(<text x="240" y="#{row_y}" font-family="#{xml_escape(font)}" font-size="24" font-weight="500" fill="#{palette[:muted]}">#{xml_escape(line)}</text>)
      end.join("\n")

      <<~SVG
        <rect x="214" y="736" width="540" height="#{[lines.length * 44 + 52, 120].max}" rx="18" fill="#{palette[:border]}" fill-opacity="0.04"/>
        #{rows}
      SVG
    end

    def build_footer_block(palette, font)
      <<~SVG
        <rect x="92" y="1060" width="716" height="2" fill="#{palette[:border]}" fill-opacity="0.18"/>
        <text x="92" y="1108" font-family="#{xml_escape(font)}" font-size="22" font-weight="600" fill="#{palette[:border]}">#{xml_escape(truncate(@publisher || @title, 48))}</text>
        <text x="92" y="1144" font-family="#{xml_escape(font)}" font-size="18" font-weight="400" fill="#{palette[:muted]}">#{xml_escape(COVER_VERSION.tr("_", " ").upcase)}</text>
      SVG
    end

    def build_decorative_lines(palette)
      seed = Digest::SHA256.digest([@title, @issn, @country].compact.join("|")).bytes

      circles = 4.times.map do |index|
        radius = 120 + seed[index].to_i
        x = 730 + (seed[index + 4].to_i % 50)
        y = 420 + (index * 110)

        %(<circle cx="#{x}" cy="#{y}" r="#{radius}" fill="none" stroke="#{palette[:accent]}" stroke-opacity="0.12" stroke-width="2"/>)
      end

      lines = 5.times.map do |index|
        offset = 300 + index * 120 + (seed[index + 8].to_i % 30)
        %(<line x1="110" y1="#{offset}" x2="790" y2="#{offset - 40}" stroke="#{palette[:border]}" stroke-opacity="0.06" stroke-width="2"/>)
      end

      (circles + lines).join("\n")
    end

    def wrap_title(text)
      words = text.split(/\s+/)
      return [truncate(text, 28)] if words.length <= 1

      lines = [String.new]

      words.each do |word|
        current = lines.last
        candidate = current.blank? ? word : "#{current} #{word}"

        if candidate.length <= 18 || current.blank?
          lines[-1] = candidate
        elsif lines.length < 4
          lines << word
        else
          lines[-1] = truncate("#{lines[-1]} #{word}", 24)
        end
      end

      lines.map { |line| truncate(line, 24) }.first(4)
    end

    def build_meta_lines
      lines = []
      lines << "#{I18n.t("discourse_journals.render.issn")}: #{@issn}" if @issn.present?
      lines << @country if @country.present?
      lines << truncate(@publisher, 40) if @publisher.present?
      lines.first(3)
    end

    def truncate(text, max_chars)
      return text if text.length <= max_chars

      "#{text[0...max_chars]}\u2026"
    end

    def xml_escape(text)
      CGI.escapeHTML(text.to_s)
    end
  end
end
