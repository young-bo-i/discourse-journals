# frozen_string_literal: true

module Jobs
  module DiscourseJournals
    class AnalyzeMapping < ::Jobs::Base
      def execute(args)
        user_id = args[:user_id]
        analysis_id = args[:analysis_id]

        analysis = ::DiscourseJournals::MappingAnalysis.find_by(id: analysis_id)
        unless analysis
          Rails.logger.warn("[DiscourseJournals::Mapping] Job skipped: analysis #{analysis_id} not found")
          return
        end

        if analysis.completed? || analysis.failed?
          Rails.logger.warn("[DiscourseJournals::Mapping] Job skipped: analysis #{analysis_id} status=#{analysis.status}")
          return
        end

        latest = ::DiscourseJournals::MappingAnalysis.current
        if latest && latest.id != analysis.id
          Rails.logger.warn("[DiscourseJournals::Mapping] Job skipped: analysis #{analysis_id} is not the latest (latest=#{latest.id})")
          return
        end

        analysis.update!(status: :processing, started_at: Time.current)
        publish_progress(user_id, analysis, "processing", 0, "开始映射分析...")

        matcher = ::DiscourseJournals::TitleMatcher.new(
          progress_callback: ->(phase, current, total, message) {
            progress = calculate_progress(phase, current, total)
            publish_progress(user_id, analysis, "processing", progress, message)
          }
        )

        results = matcher.run!

        analysis.update!(
          status: :completed,
          total_forum_topics: matcher.forum_index.values.sum(&:size),
          total_api_records: matcher.api_index.values.sum(&:size),
          exact_1to1_count: results[:exact_1to1].size,
          forum_1_to_api_n_count: results[:forum_1_to_api_n].size,
          forum_n_to_api_1_count: results[:forum_n_to_api_1].size,
          forum_n_to_api_m_count: results[:forum_n_to_api_m].size,
          forum_only_count: results[:forum_only].size,
          api_only_count: results[:api_only].size,
          details_data: build_details(results),
          completed_at: Time.current,
        )

        publish_progress(user_id, analysis, "completed", 100, "映射分析完成！")

        Rails.logger.info(
          "[DiscourseJournals::Mapping] Completed: " \
          "1:1=#{results[:exact_1to1].size}, " \
          "1:N=#{results[:forum_1_to_api_n].size}, " \
          "N:1=#{results[:forum_n_to_api_1].size}, " \
          "N:M=#{results[:forum_n_to_api_m].size}, " \
          "forum_only=#{results[:forum_only].size}, " \
          "api_only=#{results[:api_only].size}"
        )
      rescue StandardError => e
        Rails.logger.error("[DiscourseJournals::Mapping] Failed: #{e.message}\n#{e.backtrace&.first(10)&.join("\n")}")

        if analysis
          analysis.update!(
            status: :failed,
            error_message: e.message,
            completed_at: Time.current,
          )
          publish_progress(user_id, analysis, "failed", 0, "分析失败: #{e.message}")
        end
      end

      private

      def calculate_progress(phase, current, total)
        return 0 if total.zero?
        base = case phase
               when :forum then 0
               when :api then 20
               when :match then 90
               else 0
               end
        weight = case phase
                 when :forum then 20
                 when :api then 70
                 when :match then 10
                 else 0
                 end
        (base + (current.to_f / total * weight)).round(1)
      end

      def publish_progress(user_id, analysis, status, progress, message)
        return unless user_id && analysis

        MessageBus.publish(
          "/journals/mapping",
          {
            analysis_id: analysis.id,
            status: status,
            progress: progress,
            message: message,
          },
          user_ids: [user_id]
        )
      end

      def build_details(results)
        details = {}

        results.each do |category, entries|
          details[category.to_s] = entries.map do |entry|
            detail = { normalized_title: entry[:normalized_title] }

            if entry[:forum]
              detail[:forum] = entry[:forum].map do |f|
                { topic_id: f[:topic_id], title: f[:title] }
              end
            end

            if entry[:api]
              detail[:api] = entry[:api].map do |a|
                { api_id: a[:api_id], canonical_name: a[:canonical_name], issn_l: a[:issn_l] }
              end
            end

            detail
          end
        end

        details
      end
    end
  end
end
