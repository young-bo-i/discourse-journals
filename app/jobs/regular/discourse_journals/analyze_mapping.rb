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
          },
          cancel_check: -> {
            ::DiscourseJournals::MappingAnalysis.where(id: analysis.id, status: :paused).exists?
          }
        )

        results = matcher.run!

        publish_progress(user_id, analysis, "processing", 100, "正在整理分析结果...")

        counts = {
          exact_1to1: results[:exact_1to1].size,
          forum_1_to_api_n: results[:forum_1_to_api_n].size,
          forum_n_to_api_1: results[:forum_n_to_api_1].size,
          forum_n_to_api_m: results[:forum_n_to_api_m].size,
          forum_only: results[:forum_only].size,
          api_only: results[:api_only].size,
        }

        analysis.update!(
          status: :completed,
          total_forum_topics: matcher.total_forum_topics,
          total_api_records: matcher.total_api_records,
          exact_1to1_count: counts[:exact_1to1],
          forum_1_to_api_n_count: counts[:forum_1_to_api_n],
          forum_n_to_api_1_count: counts[:forum_n_to_api_1],
          forum_n_to_api_m_count: counts[:forum_n_to_api_m],
          forum_only_count: counts[:forum_only],
          api_only_count: counts[:api_only],
          completed_at: Time.current,
        )

        publish_progress(user_id, analysis, "processing", 100, "正在保存详细数据...")

        details = build_details(results)
        details["_action_plan"] = build_action_plan_data(results)
        results = nil
        analysis.update_column(:details_data, details)
        details = nil

        publish_progress(user_id, analysis, "completed", 100, "映射分析完成！")

        Rails.logger.info(
          "[DiscourseJournals::Mapping] Completed: " \
          "1:1=#{counts[:exact_1to1]}, " \
          "1:N=#{counts[:forum_1_to_api_n]}, " \
          "N:1=#{counts[:forum_n_to_api_1]}, " \
          "N:M=#{counts[:forum_n_to_api_m]}, " \
          "forum_only=#{counts[:forum_only]}, " \
          "api_only=#{counts[:api_only]}"
        )
      rescue ::DiscourseJournals::TitleMatcher::PausedError => e
        Rails.logger.info("[DiscourseJournals::Mapping] Paused by user: analysis #{analysis_id}")

        if analysis
          publish_progress(user_id, analysis, "paused", 0, "分析已暂停")
        end
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

      DETAILS_LIMIT = 500

      def build_action_plan_data(results)
        updates = {}
        creates = []
        deletes = []

        results[:exact_1to1].each do |e|
          forum = e[:forum]&.first
          api = e[:api]&.first
          updates[api[:api_id]] = forum[:topic_id] if forum && api
        end

        results[:forum_1_to_api_n].each do |e|
          forum = e[:forum]&.first
          apis = e[:api] || []
          next unless forum && apis.any?
          apis.each_with_index do |api, idx|
            idx == 0 ? (updates[api[:api_id]] = forum[:topic_id]) : (creates << api[:api_id])
          end
        end

        results[:forum_n_to_api_1].each do |e|
          forums = e[:forum] || []
          api = e[:api]&.first
          next unless forums.any? && api
          updates[api[:api_id]] = forums.first[:topic_id]
          forums[1..].each { |f| deletes << f[:topic_id] }
        end

        results[:forum_n_to_api_m].each do |e|
          forums = e[:forum] || []
          apis = e[:api] || []
          next if forums.empty? || apis.empty?
          pair_count = [forums.size, apis.size].min
          pair_count.times { |i| updates[apis[i][:api_id]] = forums[i][:topic_id] }
          forums[pair_count..].each { |f| deletes << f[:topic_id] } if forums.size > pair_count
          apis[pair_count..].each { |a| creates << a[:api_id] } if apis.size > pair_count
        end

        results[:forum_only].each do |e|
          (e[:forum] || []).each { |f| deletes << f[:topic_id] }
        end

        results[:api_only].each do |e|
          apis = e[:api] || []
          creates << apis.first[:api_id] if apis.any?
        end

        { "updates" => updates, "creates" => creates, "deletes" => deletes }
      end

      def build_details(results)
        details = {}

        results.each do |category, entries|
          items = entries.first(DETAILS_LIMIT).map do |entry|
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
          details[category.to_s] = items
        end

        details
      end
    end
  end
end
