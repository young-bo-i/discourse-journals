# frozen_string_literal: true

describe Jobs::DiscourseJournals::SyncComments do
  fab!(:admin)
  fab!(:category, :category_with_definition)
  fab!(:journal) { Fabricate(:topic, category: category, title: "Journal With Upstream Comments") }
  fab!(:quiet_journal) do
    Fabricate(:topic, category: category, title: "Journal Without Any Comments")
  end

  before do
    enable_current_plugin
    SiteSetting.discourse_journals_enabled = true
    SiteSetting.discourse_journals_category_id = category.id
    SiteSetting.discourse_journals_api_base_url = "https://journal.example.com"
    SiteSetting.discourse_journals_api_key = "jk_test"

    { journal => [988, 3], quiet_journal => [989, 0] }.each do |topic, (api_id, count)|
      Fabricate(:post, topic: topic)
      topic.upsert_custom_fields(
        discourse_journals_api_id: api_id.to_s,
        discourse_journals_data: { reviews: count.zero? ? nil : { count: count } }.to_json,
      )
    end

    stub_request(:get, %r{/api/open/journals/988/comments}).to_return(
      body: {
        success: true,
        data: {
          comments: [
            {
              "record_id" => "letpub-comment-1",
              "source_name" => "LetPub",
              "comment_text" => "审稿很快",
              "published_at_iso" => "2026-10-07T19:53:18",
              "published_at_precision" => "datetime",
            },
          ],
          nextCursor: nil,
        },
      }.to_json,
    )
  end

  describe "#execute" do
    it "syncs the listed journals and records the result" do
      state =
        DiscourseJournals::CommentSyncState.start!(
          user_id: admin.id,
          topic_ids: [journal.id],
          limit: 1,
        )

      described_class.new.execute(run_id: state["id"])

      summary = DiscourseJournals::CommentSyncState.summary
      expect(summary).to include(status: "completed", total: 1, processed: 1)
      expect(summary[:stats]).to include("journals" => 1, "created" => 1, "errors" => 0)
    end

    it "picks journals that have comments and none synced yet when no topics are listed" do
      state = DiscourseJournals::CommentSyncState.start!(user_id: admin.id, topic_ids: [], limit: 5)

      described_class.new.execute(run_id: state["id"])

      expect(DiscourseJournals::CommentPost.distinct.pluck(:topic_id)).to contain_exactly(
        journal.id,
      )
      expect(DiscourseJournals::CommentSyncState.summary[:total]).to eq(1)
    end

    it "ignores a run that is no longer the latest one" do
      stale =
        DiscourseJournals::CommentSyncState.start!(
          user_id: admin.id,
          topic_ids: [journal.id],
          limit: 1,
        )
      DiscourseJournals::CommentSyncState.start!(
        user_id: admin.id,
        topic_ids: [journal.id],
        limit: 1,
      )

      described_class.new.execute(run_id: stale["id"])

      expect(DiscourseJournals::CommentPost.count).to eq(0)
    end
  end
end
