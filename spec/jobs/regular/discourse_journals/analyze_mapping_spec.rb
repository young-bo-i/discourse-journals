# frozen_string_literal: true

describe Jobs::DiscourseJournals::AnalyzeMapping do
  fab!(:category)

  before do
    enable_current_plugin
    SiteSetting.discourse_journals_enabled = true
    SiteSetting.discourse_journals_category_id = category.id
    SiteSetting.discourse_journals_api_base_url = "https://journal.example.com"
    SiteSetting.discourse_journals_api_key = "jk_test"
    SiteSetting.duplicate_topic_titles = "allowed"
  end

  describe "#execute" do
    it "plans to merge topics that track the same upstream record into the oldest one" do
      oldest, *copies =
        Array.new(3) { Fabricate(:topic, category: category, title: "Environmental Epigenetics") }
      [oldest, *copies].each do |topic|
        topic.upsert_custom_fields(discourse_journals_api_id: "365186")
      end
      stub_request(:get, %r{\Ahttps://journal\.example\.com/api/open/journals}).to_return(
        body: {
          success: true,
          data: {
            rows: [
              {
                unified: {
                  id: 365_186,
                  canonical_name: "Environmental Epigenetics",
                  issn_l: nil,
                },
              },
            ],
            hasMore: false,
          },
        }.to_json,
      )
      analysis =
        DiscourseJournals::MappingAnalysis.create!(
          user_id: Discourse.system_user.id,
          status: :pending,
        )

      described_class.new.execute(analysis_id: analysis.id)

      analysis.reload
      plan = analysis.details_data["_action_plan"]
      expect(analysis.duplicate_topics_count).to eq(2)
      expect(plan["merges"]).to eq(copies.to_h { |copy| [copy.id.to_s, oldest.id] })
      expect(plan["updates"]).to eq("365186" => oldest.id)
      expect(plan["deletes"]).to be_empty
    end
  end
end
