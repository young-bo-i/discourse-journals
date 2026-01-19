# frozen_string_literal: true

module DiscourseJournals
  # 字段使用追踪服务：记录哪些字段被使用，哪些未被使用
  # 用于帮助开发者发现未展示的数据，便于后续迭代
  class FieldUsageTracker
    attr_reader :unused_fields

    def initialize(normalized_data)
      @normalized_data = normalized_data
      @used_fields = Set.new
      @unused_fields = []
      @logged = false
    end

    # 标记字段为已使用
    def mark_used(*field_paths)
      field_paths.each { |path| @used_fields << path.to_s }
    end

    # 检查并记录未使用的字段
    def log_unused_fields
      return if @logged
      @logged = true

      check_unused_fields(@normalized_data, "")

      if @unused_fields.any?
        Rails.logger.info("[DiscourseJournals::FieldUsageTracker] ========== 字段使用报告 ==========")
        Rails.logger.info("[DiscourseJournals::FieldUsageTracker] 已使用字段数: #{@used_fields.size}")
        Rails.logger.info("[DiscourseJournals::FieldUsageTracker] 未使用字段数: #{@unused_fields.size}")
        Rails.logger.warn("[DiscourseJournals::FieldUsageTracker] 以下字段有数据但未被渲染:")
        
        @unused_fields.each do |field|
          value_preview = truncate_value(field[:value])
          Rails.logger.warn("[DiscourseJournals::FieldUsageTracker]   - #{field[:path]}: #{value_preview}")
        end
        
        Rails.logger.info("[DiscourseJournals::FieldUsageTracker] ===================================")
      else
        Rails.logger.debug("[DiscourseJournals::FieldUsageTracker] 所有字段均已使用")
      end

      @unused_fields
    end

    # 获取使用统计
    def stats
      {
        used_count: @used_fields.size,
        unused_count: @unused_fields.size,
        used_fields: @used_fields.to_a,
        unused_fields: @unused_fields
      }
    end

    private

    def check_unused_fields(data, prefix)
      return unless data.is_a?(Hash)

      data.each do |key, value|
        path = prefix.empty? ? key.to_s : "#{prefix}.#{key}"

        if value.is_a?(Hash)
          # 递归检查嵌套 Hash
          check_unused_fields(value, path)
        elsif value_present?(value) && !@used_fields.include?(path)
          # 值存在但未被标记为已使用
          @unused_fields << { path: path, value: value, type: value.class.name }
        end
      end
    end

    def value_present?(value)
      return false if value.nil?
      return false if value.respond_to?(:empty?) && value.empty?
      return false if value == "—"
      true
    end

    def truncate_value(value)
      str = case value
            when Array
              "[#{value.first(3).map(&:to_s).join(', ')}#{value.size > 3 ? '...' : ''}] (#{value.size} items)"
            when Hash
              "{#{value.keys.first(3).join(', ')}#{value.size > 3 ? '...' : ''}} (#{value.size} keys)"
            when String
              value.length > 100 ? "#{value[0..100]}..." : value
            else
              value.to_s
            end
      
      str.length > 150 ? "#{str[0..150]}..." : str
    end
  end
end
