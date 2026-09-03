# frozen_string_literal: true

describe "DiscourseJournals promo stats" do
  before { enable_current_plugin }

  describe "POST /journals/promo/track" do
    it "records an impression for an anonymous visitor" do
      expect {
        post "/journals/promo/track.json", params: { slide: "banner", event: "impression" }
      }.to change { DiscourseJournals::PromoStat.sum(:impressions) }.by(1)

      expect(response.status).to eq(200)
    end

    it "records a click" do
      post "/journals/promo/track.json", params: { slide: "banner", event: "click" }

      expect(response.status).to eq(200)
      expect(DiscourseJournals::PromoStat.find_by(slide: "banner").clicks).to eq(1)
    end

    it "rejects an unknown slide or event without recording" do
      post "/journals/promo/track.json", params: { slide: "bogus", event: "click" }
      expect(response.status).to eq(400)

      post "/journals/promo/track.json", params: { slide: "banner", event: "hover" }
      expect(response.status).to eq(400)

      expect(DiscourseJournals::PromoStat.count).to eq(0)
    end

    it "rejects the retired topic-navigation carousel slides" do
      post "/journals/promo/track.json", params: { slide: "claw", event: "impression" }

      expect(response.status).to eq(400)
      expect(DiscourseJournals::PromoStat.count).to eq(0)
    end

    it "is not found when the plugin is disabled" do
      SiteSetting.discourse_journals_enabled = false

      post "/journals/promo/track.json", params: { slide: "banner", event: "impression" }

      expect(response.status).to eq(404)
    end
  end

  describe "GET /admin/journals/promo_stats" do
    fab!(:admin)

    it "returns the daily report for admins" do
      DiscourseJournals::PromoStat.track!(slide: "banner", event: "impression")
      sign_in(admin)

      get "/admin/journals/promo_stats.json", params: { days: 7 }

      expect(response.status).to eq(200)
      json = response.parsed_body
      expect(json["range_days"]).to eq(7)
      expect(json["days"].size).to eq(7)
      expect(json["totals"]["total"]["impressions"]).to eq(1)
    end

    it "is not reachable by non-admins" do
      sign_in(Fabricate(:user))

      get "/admin/journals/promo_stats.json"

      expect(response.status).to eq(404)
    end
  end
end
