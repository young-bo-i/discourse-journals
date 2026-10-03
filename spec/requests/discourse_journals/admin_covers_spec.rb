# frozen_string_literal: true

describe DiscourseJournals::AdminCoversController do
  fab!(:admin)

  before do
    enable_current_plugin
    SiteSetting.discourse_journals_enabled = true
    SiteSetting.discourse_journals_api_key = "jk_test_key"
  end

  def running_sync
    DiscourseJournals::CoverSync.create!(
      user_id: admin.id,
      status: :processing,
      checkpoint: {
        "heartbeat" => Time.current.to_i,
      },
    )
  end

  def error_for(key)
    [I18n.t("discourse_journals.cover_sync.errors.#{key}")]
  end

  describe "POST /admin/journals/covers/sync" do
    it "replaces the previous run with a fresh one and enqueues it" do
      sign_in(admin)
      previous = DiscourseJournals::CoverSync.create!(user_id: admin.id, status: :completed)

      expect_enqueued_with(job: Jobs::DiscourseJournals::SyncCovers) do
        post "/admin/journals/covers/sync.json"
      end

      expect(response.status).to eq(201)
      expect(response.parsed_body.dig("cover_sync", "status")).to eq("pending")
      expect(DiscourseJournals::CoverSync.exists?(previous.id)).to eq(false)
    end

    it "refuses while another cover sync is running" do
      sign_in(admin)
      running_sync

      post "/admin/journals/covers/sync.json"

      expect(response.status).to eq(422)
      expect(response.parsed_body["errors"]).to eq(error_for(:already_running))
    end

    it "refuses while a mapping apply is running" do
      sign_in(admin)
      DiscourseJournals::MappingAnalysis.create!(
        user_id: admin.id,
        status: :completed,
        apply_status: :sync_processing,
        apply_started_at: Time.current,
      )

      post "/admin/journals/covers/sync.json"

      expect(response.status).to eq(422)
      expect(response.parsed_body["errors"]).to eq(error_for(:apply_running))
    end

    it "is not available to moderators" do
      sign_in(Fabricate(:moderator))

      post "/admin/journals/covers/sync.json"

      expect(response.status).to eq(404)
    end
  end

  describe "POST /admin/journals/covers/pause" do
    it "pauses the running sync" do
      sign_in(admin)
      sync = running_sync

      post "/admin/journals/covers/pause.json"

      expect(response.status).to eq(204)
      expect(sync.reload.status).to eq("paused")
    end
  end

  describe "POST /admin/journals/covers/resume" do
    it "requeues a paused run so it continues from its checkpoint for the admin who resumed it" do
      sign_in(admin)
      sync =
        DiscourseJournals::CoverSync.create!(
          user_id: Fabricate(:admin).id,
          status: :paused,
          checkpoint: {
            "last_topic_id" => 42,
            "heartbeat" => 1.hour.ago.to_i,
          },
        )

      expect_enqueued_with(
        job: Jobs::DiscourseJournals::SyncCovers,
        args: {
          cover_sync_id: sync.id,
        },
      ) { post "/admin/journals/covers/resume.json" }

      expect(response.status).to eq(200)
      sync.reload
      expect(sync.checkpoint["last_topic_id"]).to eq(42)
      expect(sync.running?).to eq(true)
      expect(sync.user_id).to eq(admin.id)
    end

    it "refuses when there is nothing to resume" do
      sign_in(admin)

      post "/admin/journals/covers/resume.json"

      expect(response.status).to eq(422)
      expect(response.parsed_body["errors"]).to eq(error_for(:cannot_resume))
    end
  end

  describe "GET /admin/journals/covers/status" do
    it "returns the latest run" do
      sign_in(admin)
      DiscourseJournals::CoverSync.create!(
        user_id: admin.id,
        status: :completed,
        stats: {
          "updated" => 3,
        },
      )

      get "/admin/journals/covers/status.json"

      expect(response.status).to eq(200)
      expect(response.parsed_body["cover_sync"]).to include(
        "status" => "completed",
        "stats" => {
          "updated" => 3,
        },
      )
    end
  end
end
