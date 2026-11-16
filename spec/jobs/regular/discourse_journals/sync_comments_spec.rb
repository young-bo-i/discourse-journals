# frozen_string_literal: true

describe Jobs::DiscourseJournals::SyncComments do
  fab!(:admin)
  fab!(:category, :category_with_definition)
  fab!(:journal) { Fabricate(:topic, category: category, title: "Journal With Upstream Comments") }
  fab!(:second_journal) do
    Fabricate(:topic, category: category, title: "Another Journal With Comments")
  end
  fab!(:quiet_journal) do
    Fabricate(:topic, category: category, title: "Journal Without Any Comments")
  end

  before do
    enable_current_plugin
    SiteSetting.discourse_journals_enabled = true
    SiteSetting.discourse_journals_category_id = category.id
    SiteSetting.discourse_journals_api_base_url = "https://journal.example.com"
    SiteSetting.discourse_journals_api_key = "jk_test"
    SiteSetting.discourse_journals_api_rate_limit = 50

    {
      journal => [988, 1],
      second_journal => [990, 1],
      quiet_journal => [989, 0],
    }.each do |topic, (api_id, count)|
      Fabricate(:post, topic: topic)
      topic.upsert_custom_fields(
        discourse_journals_api_id: api_id.to_s,
        discourse_journals_data: { reviews: count.zero? ? nil : { count: count } }.to_json,
      )
      stub_comments(api_id, count.zero? ? [] : ["record-#{api_id}"])
    end
  end

  def stub_comments(api_id, record_ids)
    stub_request(:get, %r{/api/open/journals/#{api_id}/comments}).to_return(
      body: {
        success: true,
        data: {
          comments:
            record_ids.map do |record_id|
              {
                "record_id" => record_id,
                "source_name" => "LetPub",
                "comment_text" => "审稿很快",
                "published_at_iso" => "2026-10-07T19:53:18",
                "published_at_precision" => "datetime",
              }
            end,
          nextCursor: nil,
        },
      }.to_json,
    )
  end

  def start(mode: "full", topic_ids: [], limit: nil)
    DiscourseJournals::CommentSyncState.start!(
      user_id: admin.id,
      mode: mode,
      topic_ids: topic_ids,
      limit: limit,
    )
  end

  def synced_topic_ids
    DiscourseJournals::CommentPost.distinct.pluck(:topic_id)
  end

  describe "#execute" do
    it "syncs every journal that has comments in a full run and records where it got to" do
      state = start

      described_class.new.execute(run_id: state["id"])

      expect(synced_topic_ids).to contain_exactly(journal.id, second_journal.id)
      expect(DiscourseJournals::CommentSyncState.summary).to include(
        mode: "full",
        status: "completed",
        total: 2,
        processed: 2,
      )
      expect(DiscourseJournals::CommentSyncState.current["checkpoint"]).to eq(
        [journal.id, second_journal.id].max,
      )
    end

    it "continues after the checkpoint when a run is resumed" do
      first, last = [journal, second_journal].sort_by(&:id)
      state = start
      DiscourseJournals::CommentSyncState.update(
        checkpoint: first.id,
        processed: 1,
        total: 2,
        stats: {
          "journals" => 1,
          "created" => 1,
        },
      )

      described_class.new.execute(run_id: state["id"])

      expect(synced_topic_ids).to contain_exactly(last.id)
      expect(DiscourseJournals::CommentSyncState.summary).to include(
        status: "completed",
        processed: 2,
      )
      expect(DiscourseJournals::CommentSyncState.summary[:stats]).to include(
        "journals" => 2,
        "created" => 2,
      )
    end

    it "carries on with a run Sidekiq put back in the queue while it was processing" do
      state = start
      DiscourseJournals::CommentSyncState.update(status: "processing")

      described_class.new.execute(run_id: state["id"])

      expect(synced_topic_ids).to contain_exactly(journal.id, second_journal.id)
    end

    it "leaves a paused run alone" do
      state = start
      DiscourseJournals::CommentSyncState.update(status: "paused")

      described_class.new.execute(run_id: state["id"])

      expect(synced_topic_ids).to be_empty
      expect(DiscourseJournals::CommentSyncState.summary[:status]).to eq("paused")
    end

    it "pauses rather than fails when a mapping apply is running" do
      DiscourseJournals::MappingAnalysis.create!(
        user_id: admin.id,
        status: :completed,
        apply_status: :sync_processing,
        apply_started_at: Time.current,
      )
      state = start

      described_class.new.execute(run_id: state["id"])

      expect(synced_topic_ids).to be_empty
      expect(DiscourseJournals::CommentSyncState.summary).to include(
        status: "paused",
        error_message: I18n.t("discourse_journals.comment_sync.errors.paused_for_apply"),
      )
    end

    it "syncs only the listed journals in a test run" do
      state = start(mode: "test", topic_ids: [second_journal.id], limit: 1)

      described_class.new.execute(run_id: state["id"])

      expect(synced_topic_ids).to contain_exactly(second_journal.id)
      expect(DiscourseJournals::CommentSyncState.summary).to include(
        mode: "test",
        status: "completed",
        total: 1,
      )
    end

    it "picks journals that have comments and none synced yet when a test run lists none" do
      state = start(mode: "test", limit: 1)

      described_class.new.execute(run_id: state["id"])

      expect(synced_topic_ids).to contain_exactly([journal, second_journal].min_by(&:id).id)
    end

    it "ignores a run that is no longer the latest one" do
      stale = start
      start

      described_class.new.execute(run_id: stale["id"])

      expect(synced_topic_ids).to be_empty
    end
  end
end
