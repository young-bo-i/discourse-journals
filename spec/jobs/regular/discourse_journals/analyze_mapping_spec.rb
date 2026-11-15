# frozen_string_literal: true

describe Jobs::DiscourseJournals::AnalyzeMapping do
  # With its About topic, which analysis must never plan to flag outdated.
  fab!(:category, :category_with_definition)

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

    it "lists a record matched by id under its normalized upstream title" do
      topic = Fabricate(:topic, category: category, title: "Old Name of a Journal")
      topic.upsert_custom_fields(discourse_journals_api_id: "42")
      stub_request(:get, %r{\Ahttps://journal\.example\.com/api/open/journals}).to_return(
        body: {
          success: true,
          data: {
            rows: [{ unified: { id: 42, canonical_name: "Journal of Renamed Things" } }],
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

      expect(analysis.reload.details_data["exact_1to1"]).to contain_exactly(
        include(
          "normalized_title" => "journal of renamed things",
          "forum" => [{ "topic_id" => topic.id, "title" => topic.title }],
        ),
      )
    end

    it "asks upstream where stale ids went before planning to flag topics outdated" do
      journal = ->(title, api_id) do
        Fabricate(:topic, category: category, title: title).tap do |topic|
          topic.upsert_custom_fields(discourse_journals_api_id: api_id)
        end
      end
      kept = journal.call("Journal of Kept Pages", "200")
      copy = journal.call("Journal of Old Copies", "100")
      renamed = journal.call("Journal Before Rename", "101")
      closed = journal.call("Journal That Closed Down", "102")

      stub_request(:get, %r{\Ahttps://journal\.example\.com/api/open/journals}).with(
        query: hash_including("pageSize" => "2000"),
      ).to_return(
        body: {
          success: true,
          data: {
            rows: [
              { unified: { id: 200, canonical_name: "Journal of Kept Pages" } },
              { unified: { id: 300, canonical_name: "Journal After Rename" } },
            ],
            hasMore: false,
          },
        }.to_json,
      )
      stub_request(:get, %r{\Ahttps://journal\.example\.com/api/open/journals}).with(
        query: hash_including("resolveIds" => "follow", "fields" => "id"),
      ).to_return(
        body: {
          success: true,
          data: {
            rows: [{ unified: { id: 200 } }, { unified: { id: 300 } }],
            redirects: {
              "100" => 200,
              "101" => 300,
              "102" => nil,
            },
          },
        }.to_json,
      )
      analysis =
        DiscourseJournals::MappingAnalysis.create!(
          user_id: Discourse.system_user.id,
          status: :pending,
        )

      described_class.new.execute(analysis_id: analysis.id)

      plan = analysis.reload.details_data["_action_plan"]
      expect(plan["updates"]).to eq("200" => kept.id, "300" => renamed.id)
      expect(plan["creates"]).to be_empty
      expect(plan["merges"]).to eq(copy.id.to_s => kept.id)
      expect(plan["deletes"]).to eq([closed.id])
      expect(analysis).to have_attributes(
        status: "completed",
        duplicate_topics_count: 1,
        forum_only_count: 1,
        api_only_count: 0,
      )
    end
  end
end
