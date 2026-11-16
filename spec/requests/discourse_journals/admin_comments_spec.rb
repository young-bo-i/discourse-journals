# frozen_string_literal: true

describe DiscourseJournals::AdminCommentsController do
  fab!(:admin)
  fab!(:user)

  before do
    enable_current_plugin
    SiteSetting.discourse_journals_enabled = true
    SiteSetting.discourse_journals_api_key = "jk_test_key"
  end

  def start_run(mode: "full")
    DiscourseJournals::CommentSyncState.start!(user_id: admin.id, mode: mode)
  end

  def error_for(key)
    [I18n.t("discourse_journals.comment_sync.errors.#{key}")]
  end

  describe "POST /admin/journals/comments/sync" do
    it "starts a full run and enqueues it" do
      sign_in(admin)

      expect_enqueued_with(job: Jobs::DiscourseJournals::SyncComments) do
        post "/admin/journals/comments/sync.json", params: { mode: "full" }
      end

      expect(response.status).to eq(201)
      expect(response.parsed_body["comment_sync"]).to include(
        "mode" => "full",
        "status" => "pending",
        "topic_ids" => [],
      )
    end

    it "starts a test run for the listed journal topics" do
      sign_in(admin)

      expect_enqueued_with(job: Jobs::DiscourseJournals::SyncComments) do
        post "/admin/journals/comments/sync.json", params: { topic_ids: "12, 34 12", limit: 5 }
      end

      expect(response.status).to eq(201)
      expect(response.parsed_body["comment_sync"]).to include(
        "mode" => "test",
        "status" => "pending",
        "topic_ids" => [12, 34],
      )
    end

    it "refuses while another comment sync is running" do
      sign_in(admin)
      start_run

      post "/admin/journals/comments/sync.json", params: { mode: "full" }

      expect(response.status).to eq(422)
      expect(response.parsed_body["errors"]).to eq(error_for(:already_running))
    end

    it "is only available to admins" do
      sign_in(user)

      post "/admin/journals/comments/sync.json", params: { mode: "full" }

      expect(response.status).to eq(404)
    end
  end

  describe "POST /admin/journals/comments/pause" do
    it "marks a running sync paused so the job stops after its current journal" do
      sign_in(admin)
      start_run

      post "/admin/journals/comments/pause.json"

      expect(response.status).to eq(200)
      expect(response.parsed_body.dig("comment_sync", "status")).to eq("paused")
    end
  end

  describe "POST /admin/journals/comments/resume" do
    it "requeues a paused sync from its checkpoint" do
      sign_in(admin)
      start_run
      DiscourseJournals::CommentSyncState.update(status: "paused", checkpoint: 120, processed: 7)

      expect_enqueued_with(job: Jobs::DiscourseJournals::SyncComments) do
        post "/admin/journals/comments/resume.json"
      end

      expect(response.parsed_body["comment_sync"]).to include(
        "status" => "pending",
        "processed" => 7,
      )
      expect(DiscourseJournals::CommentSyncState.current["checkpoint"]).to eq(120)
    end

    it "refuses while the sync is still running" do
      sign_in(admin)
      start_run

      post "/admin/journals/comments/resume.json"

      expect(response.status).to eq(422)
      expect(response.parsed_body["errors"]).to eq(error_for(:cannot_resume))
    end
  end

  describe "GET /admin/journals/comments/status" do
    it "reports a run whose job stopped reporting as failed" do
      sign_in(admin)
      start_run
      DiscourseJournals::CommentSyncState.update(heartbeat_at: 1.hour.ago.to_i)

      get "/admin/journals/comments/status.json"

      expect(response.parsed_body["comment_sync"]).to include(
        "status" => "failed",
        "error_message" => I18n.t("discourse_journals.comment_sync.errors.interrupted"),
      )
    end
  end
end
