# frozen_string_literal: true

describe DiscourseJournals::CookedRerenderer do
  fab!(:category)

  before do
    enable_current_plugin
    SiteSetting.discourse_journals_category_id = category.id
  end

  def journal_topic(title, outdated: false)
    topic =
      create_post(
        user: Discourse.system_user,
        title: title,
        raw: "journal body text",
        category: category.id,
      ).topic
    topic.upsert_custom_fields(
      discourse_journals_data: {
        identity: {
          title: title,
        },
        metrics: {
          works_count: 1234,
        },
      }.to_json,
    )
    topic.upsert_custom_fields(discourse_journals_outdated: Time.current.iso8601) if outdated
    topic
  end

  describe "#rerender_all!" do
    it "rewrites first posts from the stored JSON without touching updated_at" do
      live = journal_topic("Journal of Testing")
      outdated = journal_topic("Journal of Old Tests", outdated: true)
      bare =
        create_post(
          user: Discourse.system_user,
          title: "Topic without data",
          raw: "plain text body",
          category: category.id,
        ).topic
      updated_at = live.first_post.updated_at

      result = described_class.new.rerender_all!

      expect(result.to_h).to include(rendered: 2, failed: 0)
      expect(live.first_post.reload.cooked).to include(%(<article class="dj-journal">), "1,234")
      expect(live.first_post.updated_at).to eq_time(updated_at)
      expect(outdated.first_post.reload.cooked).to include("dj-outdated-notice")
      expect(bare.first_post.reload.cooked).not_to include("dj-journal")
    end

    it "leaves a page alone when a sync rewrote its data after the batch was read" do
      topic = journal_topic("Journal of Races")
      allow(DiscourseJournals::MasterRecordRenderer).to receive(
        :new,
      ).and_wrap_original do |original, *args, **kwargs|
        # What a concurrent mapping apply does to the same topic meanwhile.
        topic.upsert_custom_fields(
          discourse_journals_data: { identity: { title: "Journal of Races" } }.to_json,
        )
        topic.first_post.update_columns(cooked: "<p>newer page</p>")
        original.call(*args, **kwargs)
      end

      result = described_class.new.rerender_all!

      expect(result.rendered).to eq(0)
      expect(topic.first_post.reload.cooked).to eq("<p>newer page</p>")
    end

    it "resumes after a topic id and stops at the limit" do
      first = journal_topic("Journal One")
      second = journal_topic("Journal Two")
      third = journal_topic("Journal Three")

      result = described_class.new.rerender_all!(after_id: first.id, limit: 1)

      expect(result.to_h).to include(rendered: 1, last_topic_id: second.id)
      expect(third.first_post.reload.cooked).not_to include("dj-journal")
    end
  end
end
