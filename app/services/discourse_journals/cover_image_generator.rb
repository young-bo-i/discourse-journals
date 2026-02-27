# frozen_string_literal: true

module DiscourseJournals
  class CoverImageGenerator
    WIDTH = 600
    HEIGHT = 400
    GRID_ROWS = 5
    GRID_COLS = 5
    PATTERN_AREA_HEIGHT = (HEIGHT * 0.65).to_i
    CELL_GAP = 4
    CELL_W = (WIDTH - CELL_GAP * (GRID_COLS + 1)) / GRID_COLS
    CELL_H = (PATTERN_AREA_HEIGHT - CELL_GAP * (GRID_ROWS + 1)) / GRID_ROWS

    class << self
      def generate(title:, issn: nil, country: nil)
        new(title: title, issn: issn, country: country).generate
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
            candidates.find { |f| output.include?(f) }
          rescue StandardError
            nil
          end
      end

      def text_font
        cjk_font || "NimbusSans-Regular"
      end
    end

    def initialize(title:, issn: nil, country: nil)
      @title = title.present? ? title : I18n.t("discourse_journals.render.unknown_journal")
      @issn = issn
      @country = country
    end

    def generate
      digest = Digest::SHA256.digest(@title)
      bytes = digest.bytes

      base_color = LetterAvatar::COLORS[bytes[0] % LetterAvatar::COLORS.length]
      accent_idx = (bytes[1] * 256 + bytes[2]) % LetterAvatar::COLORS.length
      accent_color = LetterAvatar::COLORS[accent_idx]
      pattern_bits = (bytes[3] << 8) | bytes[4]

      tempfile = Tempfile.new(["journal_cover_", ".png"])
      instructions = build_instructions(base_color, accent_color, pattern_bits, tempfile.path)
      Discourse::Utils.execute_command("magick", *instructions)
      tempfile
    end

    private

    def build_instructions(base_color, accent_color, pattern_bits, output_path)
      base_rgb = to_rgb(base_color)
      accent_rgb = to_rgb(accent_color)
      font = self.class.text_font

      instructions = ["-size", "#{WIDTH}x#{HEIGHT}", "xc:#{base_rgb}"]

      draws = build_pattern_draws(pattern_bits)
      if draws.any?
        instructions.push("-fill", accent_rgb)
        draws.each { |cmd| instructions.push("-draw", cmd) }
      end

      overlay_y = PATTERN_AREA_HEIGHT - 20
      instructions.push(
        "-fill",
        "rgba(0,0,0,0.55)",
        "-draw",
        "rectangle 0,#{overlay_y} #{WIDTH},#{HEIGHT}",
      )

      display_title = truncate_text(@title, 45)
      safe_title = sanitize_for_magick(display_title)
      has_meta = @issn.present? || @country.present?
      title_y = has_meta ? 78 : 55

      instructions.push(
        "-fill",
        "white",
        "-font",
        font,
        "-pointsize",
        "22",
        "-gravity",
        "SouthWest",
        "-annotate",
        "+24+#{title_y}",
        safe_title,
      )

      meta_parts = []
      meta_parts << "#{I18n.t("discourse_journals.render.issn")}: #{@issn}" if @issn.present?
      meta_parts << @country if @country.present?

      if meta_parts.any?
        meta_text = sanitize_for_magick(meta_parts.join("  \u00B7  "))
        instructions.push(
          "-fill",
          "rgba(255,255,255,0.7)",
          "-font",
          font,
          "-pointsize",
          "14",
          "-gravity",
          "SouthWest",
          "-annotate",
          "+24+30",
          meta_text,
        )
      end

      instructions.push("-depth", "8", output_path)
    end

    def build_pattern_draws(pattern_bits)
      draws = []
      bit_idx = 0

      GRID_ROWS.times do |row|
        3.times do |col|
          if pattern_bits & (1 << bit_idx) != 0
            x1 = CELL_GAP + col * (CELL_W + CELL_GAP)
            y1 = CELL_GAP + row * (CELL_H + CELL_GAP)
            draws << "rectangle #{x1},#{y1} #{x1 + CELL_W - 1},#{y1 + CELL_H - 1}"

            if col < 2
              mirror_col = GRID_COLS - 1 - col
              mx1 = CELL_GAP + mirror_col * (CELL_W + CELL_GAP)
              draws << "rectangle #{mx1},#{y1} #{mx1 + CELL_W - 1},#{y1 + CELL_H - 1}"
            end
          end
          bit_idx += 1
        end
      end

      draws
    end

    def to_rgb(color)
      "rgb(#{color[0]},#{color[1]},#{color[2]})"
    end

    def truncate_text(text, max_chars)
      return text if text.length <= max_chars
      "#{text[0...max_chars]}\u2026"
    end

    def sanitize_for_magick(text)
      text.gsub("%", "%%").gsub("@", "\\@")
    end
  end
end
