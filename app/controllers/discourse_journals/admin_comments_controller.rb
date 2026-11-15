# frozen_string_literal: true

module DiscourseJournals
  class AdminCommentsController < ::Admin::AdminController
    requires_plugin DiscourseJournals::PLUGIN_NAME

    # POST /admin/journals/comments/sync
    # Either the given journal topic ids, or up to `limit` journals that have
    # comments and none synced yet.
    def sync
      topic_ids = params[:topic_ids].to_s.scan(/\d+/).map(&:to_i).uniq
      if topic_ids.size > CommentSyncState::MAX_JOURNALS
        return(
          render_json_error(
            I18n.t(
              "discourse_journals.comment_sync.errors.too_many",
              count: CommentSyncState::MAX_JOURNALS,
            ),
          )
        )
      end
      limit = params[:limit].to_i.clamp(1, CommentSyncState::MAX_JOURNALS)

      begin
        ApiClient.ensure_configured!
      rescue ApiClient::AuthError => e
        return render_json_error(e.message)
      end

      DistributedMutex.synchronize("discourse_journals_comment_sync_start") do
        if CommentSyncState.running?
          return render_json_error(I18n.t("discourse_journals.comment_sync.errors.already_running"))
        end
        if apply_running?
          return render_json_error(I18n.t("discourse_journals.comment_sync.errors.apply_running"))
        end

        state =
          CommentSyncState.start!(user_id: current_user.id, topic_ids: topic_ids, limit: limit)
        Jobs.enqueue(Jobs::DiscourseJournals::SyncComments, run_id: state["id"])
      end

      render_json_dump({ comment_sync: CommentSyncState.summary }, status: :created)
    end

    # GET /admin/journals/comments/status
    def status
      render_json_dump({ comment_sync: CommentSyncState.summary })
    end

    private

    def apply_running?
      analysis = MappingAnalysis.current_light
      analysis.present? && analysis.sync_processing? && !analysis.stale_sync_processing?
    end
  end
end
