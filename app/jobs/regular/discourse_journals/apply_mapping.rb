# frozen_string_literal: true

module Jobs
  module DiscourseJournals
    class ApplyMapping < ::Jobs::Base
      sidekiq_options retry: 0

      def execute(args)
        user_id = args[:user_id]
        analysis_id = args[:analysis_id]
        resume = args[:resume] == true

        # `lightweight` omits details_data (6.4 MB of jsonb): nothing in this job
        # reads it, and MappingApplier#build_action_plan re-queries the column by
        # id anyway. Loading it here pinned the whole string for the job's life.
        analysis = ::DiscourseJournals::MappingAnalysis.lightweight.find_by(id: analysis_id)
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

        if resume
          Rails.logger.info(
            "[DiscourseJournals::ApplyMapping] RESUME: checkpoint=#{resume_checkpoint.inspect}, stats=#{resume_stats.inspect}",
          )
        else
          Rails.logger.info("[DiscourseJournals::ApplyMapping] FRESH START: no checkpoint")
        end

        analysis.update!(
          apply_status: :sync_processing,
          apply_started_at: resume ? analysis.apply_started_at || Time.current : Time.current,
          apply_error_message: nil,
          # Claim the row with a fresh heartbeat. Without this the row stays
          # stale through build_action_plan and the first batch, so the admin UI
          # would offer Resume again and a second applier could start — there is
          # no lock anywhere in this plugin.
          apply_checkpoint: resume_checkpoint.merge("heartbeat" => Time.current.to_i),
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
            publish_progress(user_id, analysis, "processing", percent, message, stats)
          },
          cancel_check: -> {
            ::DiscourseJournals::MappingAnalysis
              .where(id: analysis.id, apply_status: %i[sync_paused not_applied])
              .exists?
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
        reconcile_tag_counts_safely
        if analysis
          stats = ::DiscourseJournals::MappingAnalysis.where(id: analysis.id).pick(:apply_stats) || {}
          publish_progress(user_id, analysis, "paused", 0, "应用已暂停", stats)
        end
      rescue StandardError => e
        Rails.logger.error("[DiscourseJournals::ApplyMapping] Failed: #{e.message}\n#{e.backtrace&.first(10)&.join("\n")}")
        reconcile_tag_counts_safely

        if analysis
          analysis.update!(
            apply_status: :sync_failed,
            apply_error_message: e.message,
            apply_completed_at: Time.current,
          )
          stats = ::DiscourseJournals::MappingAnalysis.where(id: analysis.id).pick(:apply_stats) || {}
          publish_progress(user_id, analysis, "failed", 0, "应用失败: #{e.message}", stats)
        end
      end

      private

      # Tag/category-tag counts are maintained by reconcile_counts! on the success
      # path. On pause/abort the delta writes (and BulkTopicDeleter) have already
      # skipped the per-row counter callbacks, so reconcile here too — otherwise
      # counts stay drifted until the 12h EnsureDbConsistency job. Self-guarded so
      # a reconcile failure never masks the original pause/error.
      def reconcile_tag_counts_safely
        ::DiscourseJournals::JournalTagManager.reconcile_counts!
        ::DiscourseJournals::JournalTagManager.reset_cache!
      rescue StandardError => e
        Rails.logger.warn("[DiscourseJournals::ApplyMapping] reconcile_counts! failed: #{e.message}")
      end

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
