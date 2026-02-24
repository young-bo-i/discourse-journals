# frozen_string_literal: true

module Jobs
  module DiscourseJournals
    class ApplyMapping < ::Jobs::Base
      sidekiq_options retry: 0

      def execute(args)
        user_id = args[:user_id]
        analysis_id = args[:analysis_id]
        resume = args[:resume] == true

        analysis = ::DiscourseJournals::MappingAnalysis.find_by(id: analysis_id)
        unless analysis
          Rails.logger.warn("[DiscourseJournals::ApplyMapping] Job skipped: analysis #{analysis_id} not found")
          return
        end

        if resume
          unless analysis.can_resume_apply?
            Rails.logger.warn("[DiscourseJournals::ApplyMapping] Job skipped: analysis #{analysis_id} cannot resume (apply_status=#{analysis.apply_status})")
            return
          end
        else
          unless analysis.can_apply?
            Rails.logger.warn("[DiscourseJournals::ApplyMapping] Job skipped: analysis #{analysis_id} cannot apply (status=#{analysis.status}, apply_status=#{analysis.apply_status})")
            return
          end
        end

        resume_checkpoint = resume ? (analysis.apply_checkpoint || {}) : {}
        resume_stats = resume ? (analysis.apply_stats || {}) : {}

        analysis.update!(
          apply_status: :sync_processing,
          apply_started_at: resume ? analysis.apply_started_at || Time.current : Time.current,
          apply_error_message: nil,
        )
        analysis.update_columns(apply_stats: resume_stats) if resume

        publish_progress(
          user_id,
          analysis,
          "processing",
          0,
          resume ? "从断点继续应用映射..." : "开始应用映射...",
          resume_stats,
        )

        applier = ::DiscourseJournals::MappingApplier.new(
          analysis: analysis,
          resume_checkpoint: resume_checkpoint,
          resume_stats: resume ? resume_stats : nil,
          progress_callback: ->(percent, message, stats) {
            analysis.update_columns(apply_stats: stats.transform_keys(&:to_s))
            publish_progress(user_id, analysis, "processing", percent, message, stats)
          },
          cancel_check: -> {
            analysis.reload.sync_paused?
          },
        )

        final_stats = applier.run!

        analysis.update!(
          apply_status: :sync_completed,
          apply_completed_at: Time.current,
          apply_stats: final_stats.transform_keys(&:to_s),
          apply_checkpoint: {},
        )

        publish_progress(user_id, analysis, "completed", 100, "映射应用完成！", final_stats)

        Rails.logger.info(
          "[DiscourseJournals::ApplyMapping] Completed: " \
          "deleted=#{final_stats[:deleted]}, updated=#{final_stats[:updated]}, " \
          "created=#{final_stats[:created]}, errors=#{final_stats[:errors]}",
        )
      rescue ::DiscourseJournals::MappingApplier::PausedError
        Rails.logger.info("[DiscourseJournals::ApplyMapping] Paused by user: analysis #{analysis_id}")
        if analysis
          stats = analysis.reload.apply_stats || {}
          publish_progress(user_id, analysis, "paused", 0, "应用已暂停", stats)
        end
      rescue StandardError => e
        Rails.logger.error("[DiscourseJournals::ApplyMapping] Failed: #{e.message}\n#{e.backtrace&.first(10)&.join("\n")}")

        if analysis
          analysis.update!(
            apply_status: :sync_failed,
            apply_error_message: e.message,
            apply_completed_at: Time.current,
          )
          stats = analysis.reload.apply_stats || {}
          publish_progress(user_id, analysis, "failed", 0, "应用失败: #{e.message}", stats)
        end
      end

      private

      def publish_progress(user_id, analysis, status, progress, message, stats)
        return unless user_id && analysis

        MessageBus.publish(
          "/journals/mapping-apply",
          {
            analysis_id: analysis.id,
            status: status,
            progress: progress,
            message: message,
            stats: stats,
          },
          user_ids: [user_id],
        )
      end
    end
  end
end
