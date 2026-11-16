# frozen_string_literal: true

describe DiscourseJournals::AdminTopicsController do
  fab!(:admin)
  fab!(:user)
  fab!(:category)

  before do
    enable_current_plugin
    SiteSetting.discourse_journals_enabled = true
    SiteSetting.discourse_journals_category_id = category.id
  end

  describe "GET /admin/journals/topics/status" do
    it "counts the journal topics still closed to replies" do
      sign_in(admin)
      Fabricate(:topic, category: category, closed: true)
      Fabricate(:topic, category: category)
      Fabricate(:topic, closed: true)

      get "/admin/journals/topics/status.json"

      expect(response.parsed_body["topics"]).to eq(
        "total" => 2,
        "closed" => 1,
        "close_setting" => false,
      )
    end
  end

  describe "POST /admin/journals/topics/open_all" do
    it "opens them in the background and stops later syncs from closing them again" do
      sign_in(admin)
      SiteSetting.discourse_journals_close_topics = true

      expect_enqueued_with(job: Jobs::DiscourseJournals::OpenJournalTopics) do
        post "/admin/journals/topics/open_all.json"
      end

      expect(response.status).to eq(200)
      expect(SiteSetting.discourse_journals_close_topics).to eq(false)
      expect(
        UserHistory.exists?(
          action: UserHistory.actions[:change_site_setting],
          subject: "discourse_journals_close_topics",
          acting_user_id: admin.id,
        ),
      ).to eq(true)
    end

    it "is only available to admins" do
      sign_in(user)

      post "/admin/journals/topics/open_all.json"

      expect(response.status).to eq(404)
    end
  end
end
