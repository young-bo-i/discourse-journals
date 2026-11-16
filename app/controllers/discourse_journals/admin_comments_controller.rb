# frozen_string_literal: true

module DiscourseJournals
  class AdminCommentsController < ::Admin::AdminController
    requires_plugin DiscourseJournals::PLUGIN_NAME

    MUTEX_KEY = "discourse_journals_comment_sync_control"

    # POST /admin/journals/comments/sync
    # mode=full syncs every journal that has comments. Anything else is a test
    # run: the listed topic ids, or up to `limit` journals with comments and
    # none synced yet.
    def sync
      mode = params[:mode] == "full" ? "full" : "test"
      topic_ids = []
      limit = nil

      if mode == "test"
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
      end

      begin
        ApiClient.ensure_configured!
      rescue ApiClient::AuthError => e
        return render_json_error(e.message)
      end

      DistributedMutex.synchronize(MUTEX_KEY) do
        return render_error(:already_running) if CommentSyncState.running?
        return render_error(:apply_running) if apply_running?

        state =
          CommentSyncState.start!(
            user_id: current_user.id,
            mode: mode,
            topic_ids: topic_ids,
            limit: limit,
          )
        Jobs.enqueue(Jobs::DiscourseJournals::SyncComments, run_id: state["id"])
      end

      render_json_dump({ comment_sync: CommentSyncState.summary }, status: :created)
    end

    # POST /admin/journals/comments/pause
    # The job stops after the journal it is writing.
    def pause
      DistributedMutex.synchronize(MUTEX_KEY) do
        return render_error(:not_running) if !CommentSyncState.running?

        CommentSyncState.update(status: "paused")
      end

      render_json_dump({ comment_sync: CommentSyncState.summary })
    end

    # POST /admin/journals/comments/resume
    def resume
      DistributedMutex.synchronize(MUTEX_KEY) do
        return render_error(:cannot_resume) if !CommentSyncState.resumable?
        return render_error(:apply_running) if apply_running?

        state = CommentSyncState.resume!(user_id: current_user.id)
        Jobs.enqueue(Jobs::DiscourseJournals::SyncComments, run_id: state["id"])
      end

      render_json_dump({ comment_sync: CommentSyncState.summary })
    end

    # GET /admin/journals/comments/status
    def status
      render_json_dump({ comment_sync: CommentSyncState.summary })
    end

    private

    def render_error(key)
      render_json_error(I18n.t("discourse_journals.comment_sync.errors.#{key}"))
    end

    def apply_running?
      analysis = MappingAnalysis.current_light
      analysis.present? && analysis.sync_processing? && !analysis.stale_sync_processing?
    end
  end
end
