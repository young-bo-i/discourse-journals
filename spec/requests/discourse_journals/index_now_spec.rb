# frozen_string_literal: true

describe DiscourseJournals::IndexNowController do
  let(:key) { DiscourseJournals::IndexNow.key }

  before do
    enable_current_plugin
    SiteSetting.discourse_journals_enabled = true
  end

  describe "GET /<key>.txt" do
    it "serves the ownership key only while IndexNow is enabled" do
      get "/#{key}.txt"
      expect(response.status).to eq(404)

      SiteSetting.discourse_journals_indexnow_enabled = true
      get "/#{key}.txt"

      expect(response.status).to eq(200)
      expect(response.body).to eq(key)
    end

    it "does not answer for other keys" do
      SiteSetting.discourse_journals_indexnow_enabled = true

      get "/#{"0" * 32}.txt"

      expect(response.status).to eq(404)
    end
  end
end
