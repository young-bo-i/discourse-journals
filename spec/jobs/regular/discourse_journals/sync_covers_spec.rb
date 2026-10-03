# frozen_string_literal: true

describe Jobs::DiscourseJournals::SyncCovers do
  fab!(:admin)
  fab!(:category)

  before do
    enable_current_plugin
    SiteSetting.discourse_journals_enabled = true
    SiteSetting.discourse_journals_category_id = category.id
    SiteSetting.discourse_journals_api_base_url = "https://journal.example.com"
    SiteSetting.discourse_journals_api_key = "jk_test_key"
  end

  def pending_sync
    DiscourseJournals::CoverSync.create!(user_id: admin.id, status: :pending)
  end

  describe "#execute" do
    it "runs a pending sync to completion and reports progress to the admin who started it" do
      create_post(user: Discourse.system_user, category: category)
      sync = pending_sync

      messages =
        MessageBus.track_publish("/journals/cover-sync") do
          described_class.new.execute(cover_sync_id: sync.id)
        end

      sync.reload
      expect(sync).to have_attributes(status: "completed", total: 1)
      expect(sync.stats["scanned"]).to eq(1)
      expect(messages.map { |message| message.data[:status] }).to eq(
        %w[processing processing completed],
      )
      expect(messages.map(&:user_ids).uniq).to eq([[admin.id]])
    end

    it "does nothing for a run another job already claimed" do
      sync = pending_sync
      sync.update!(status: :processing, checkpoint: { "heartbeat" => Time.current.to_i })

      described_class.new.execute(cover_sync_id: sync.id)

      expect(sync.reload.started_at).to be_nil
    end

    it "fails the run instead of syncing while a mapping apply is running" do
      DiscourseJournals::MappingAnalysis.create!(
        user_id: admin.id,
        status: :completed,
        apply_status: :sync_processing,
        apply_started_at: Time.current,
      )
      sync = pending_sync

      described_class.new.execute(cover_sync_id: sync.id)

      expect(sync.reload).to have_attributes(
        status: "failed",
        error_message: I18n.t("discourse_journals.cover_sync.errors.apply_running"),
      )
    end

    it "records an aborted run as failed so it can be resumed" do
      SiteSetting.discourse_journals_api_key = ""
      sync = pending_sync

      described_class.new.execute(cover_sync_id: sync.id)

      sync.reload
      expect(sync).to have_attributes(
        status: "failed",
        error_message: I18n.t("discourse_journals.errors.missing_api_key"),
      )
      expect(sync.can_resume?).to eq(true)
    end
  end
end
