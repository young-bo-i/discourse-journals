# frozen_string_literal: true

module DiscourseJournals
  class AdminCoversController < ::Admin::AdminController
    requires_plugin DiscourseJournals::PLUGIN_NAME

    # POST /admin/journals/covers/sync
    def sync
      if CoverSync.running?
        return render_json_error(I18n.t("discourse_journals.cover_sync.errors.already_running"))
      end
      if apply_running?
        return render_json_error(I18n.t("discourse_journals.cover_sync.errors.apply_running"))
      end

      begin
        ApiClient.ensure_configured!
      rescue ApiClient::AuthError => e
        return render_json_error(e.message)
      end

      CoverSync.delete_all
      cover_sync = CoverSync.create!(user_id: current_user.id, status: :pending)
      Jobs.enqueue(Jobs::DiscourseJournals::SyncCovers, cover_sync_id: cover_sync.id)

      render_json_dump({ cover_sync: cover_sync.summary }, status: :created)
    end

    # POST /admin/journals/covers/pause
    def pause
      cover_sync = CoverSync.current
      if !cover_sync&.running?
        return render_json_error(I18n.t("discourse_journals.cover_sync.errors.not_running"))
      end

      cover_sync.update!(status: :paused)
      head :no_content
    end

    # POST /admin/journals/covers/resume
    def resume
      cover_sync = CoverSync.current
      if !cover_sync&.can_resume?
        return render_json_error(I18n.t("discourse_journals.cover_sync.errors.cannot_resume"))
      end
      if apply_running?
        return render_json_error(I18n.t("discourse_journals.cover_sync.errors.apply_running"))
      end

      # Back to pending with a fresh heartbeat: the job claims pending rows only,
      # and an old heartbeat would make the row look stale straight away.
      # Progress is pushed to the admin who resumed, not the one who started.
      cover_sync.update!(
        status: :pending,
        user_id: current_user.id,
        error_message: nil,
        checkpoint: (cover_sync.checkpoint || {}).merge("heartbeat" => Time.current.to_i),
      )
      Jobs.enqueue(Jobs::DiscourseJournals::SyncCovers, cover_sync_id: cover_sync.id)

      render_json_dump({ cover_sync: cover_sync.summary })
    end

    # GET /admin/journals/covers/status
    def status
      render_json_dump({ cover_sync: CoverSync.current&.summary })
    end

    private

    def apply_running?
      analysis = MappingAnalysis.current_light
      analysis.present? && analysis.sync_processing? && !analysis.stale_sync_processing?
    end
  end
end
