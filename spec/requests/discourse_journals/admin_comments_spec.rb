# frozen_string_literal: true

describe DiscourseJournals::AdminCommentsController do
  fab!(:admin)
  fab!(:user)

  before do
    enable_current_plugin
    SiteSetting.discourse_journals_enabled = true
    SiteSetting.discourse_journals_api_key = "jk_test_key"
  end

  describe "POST /admin/journals/comments/sync" do
    it "starts a run for the listed journal topics and enqueues it" do
      sign_in(admin)

      expect_enqueued_with(job: Jobs::DiscourseJournals::SyncComments) do
        post "/admin/journals/comments/sync.json", params: { topic_ids: "12, 34 12", limit: 5 }
      end

      expect(response.status).to eq(201)
      expect(response.parsed_body["comment_sync"]).to include(
        "status" => "pending",
        "topic_ids" => [12, 34],
      )
    end

    it "refuses while another comment sync is running" do
      sign_in(admin)
      DiscourseJournals::CommentSyncState.start!(user_id: admin.id, topic_ids: [], limit: 1)

      post "/admin/journals/comments/sync.json", params: { limit: 1 }

      expect(response.status).to eq(422)
      expect(response.parsed_body["errors"]).to eq(
        [I18n.t("discourse_journals.comment_sync.errors.already_running")],
      )
    end

    it "is only available to admins" do
      sign_in(user)

      post "/admin/journals/comments/sync.json", params: { limit: 1 }

      expect(response.status).to eq(404)
    end
  end

  describe "GET /admin/journals/comments/status" do
    it "reports a run whose job stopped reporting as failed" do
      sign_in(admin)
      DiscourseJournals::CommentSyncState.start!(user_id: admin.id, topic_ids: [], limit: 1)
      DiscourseJournals::CommentSyncState.update(heartbeat_at: 1.hour.ago.to_i)

      get "/admin/journals/comments/status.json"

      expect(response.parsed_body["comment_sync"]).to include(
        "status" => "failed",
        "error_message" => I18n.t("discourse_journals.comment_sync.errors.interrupted"),
      )
    end
  end
end
