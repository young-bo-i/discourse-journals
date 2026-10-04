# frozen_string_literal: true

module Jobs
  module DiscourseJournals
    class ApplyMapping < ::Jobs::Base
      sidekiq_options retry: 0

      def execute(args)
        analysis_id = args[:analysis_id]
        ran =
          ::DiscourseJournals::ApplyLock.synchronize(
            on_renew: -> { refresh_heartbeat(analysis_id) },
          ) { apply(args) }
        return if ran

        Rails.logger.warn(
          "[DiscourseJournals::ApplyMapping] Job skipped: another apply is still running (analysis #{analysis_id})",
        )
      end

      private

      def apply(args)
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
          unless analysis.resumable_by_lock_holder?
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
          # A fresh heartbeat makes the admin UI show the run as live from the
          # start instead of as interrupted.
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

      # Touches only the heartbeat key, so it never races the applier's own
      # checkpoint writes on the same column.
      def refresh_heartbeat(analysis_id)
        ::DiscourseJournals::MappingAnalysis.where(id: analysis_id).update_all(
          [
            "apply_checkpoint = jsonb_set(COALESCE(apply_checkpoint, '{}'::jsonb), '{heartbeat}', to_jsonb(?::bigint))",
            Time.current.to_i,
          ],
        )
      end

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
