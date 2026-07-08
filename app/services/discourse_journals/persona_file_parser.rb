# frozen_string_literal: true

require "csv"
require "json"

module DiscourseJournals
  # Parses an uploaded persona list (CSV or JSON) into normalized row hashes.
  class PersonaFileParser
    class ParseError < StandardError
    end

    ALLOWED_KEYS = %w[username name field bio location].freeze
    MAX_ROWS = 100_000

    def self.parse(content, filename = nil)
      content = content.to_s
      raise ParseError, "文件为空" if content.strip.blank?

      rows = json?(content, filename) ? parse_json(content) : parse_csv(content)
      rows = rows.first(MAX_ROWS)
      raise ParseError, "文件中没有可用的记录（每条至少要有 username）" if rows.empty?
      rows
    end

    def self.json?(content, filename)
      return true if filename.to_s.downcase.end_with?(".json")
      stripped = content.strip
      stripped.start_with?("[") || stripped.start_with?("{")
    end

    def self.parse_json(content)
      data = JSON.parse(content)
      data = data["personas"] || data["rows"] if data.is_a?(Hash)
      raise ParseError, "JSON 根必须是数组，或含 personas/rows 数组的对象" unless data.is_a?(Array)
      data.filter_map { |item| normalize_row(item) }
    rescue JSON::ParserError => e
      raise ParseError, "JSON 解析失败: #{e.message}"
    end

    def self.parse_csv(content)
      table = CSV.parse(content, headers: true)
      headers = (table.headers || []).compact.map { |h| h.to_s.strip.downcase }
      raise ParseError, "CSV 需要表头行（至少包含 username 列）" if headers.blank?
      raise ParseError, "CSV 表头缺少 username 列" unless headers.include?("username")
      table.filter_map { |csv_row| normalize_row(csv_row.to_h) }
    rescue CSV::MalformedCSVError => e
      raise ParseError, "CSV 解析失败: #{e.message}"
    end

    def self.normalize_row(item)
      return nil unless item.is_a?(Hash)

      row = {}
      item.each do |k, v|
        key = k.to_s.strip.downcase
        next unless ALLOWED_KEYS.include?(key)
        row[key] = v.to_s.strip
      end

      return nil if row["username"].blank?
      row
    end
  end
end
