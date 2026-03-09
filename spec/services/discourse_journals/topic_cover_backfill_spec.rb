# frozen_string_literal: true

describe DiscourseJournals::TopicCoverBackfill do
  before do
    enable_current_plugin
    SiteSetting.discourse_journals_enabled = true
    SiteSetting.discourse_journals_category_id = category.id
    allow(Jobs).to receive(:enqueue_in)
  end

  fab!(:category)
  fab!(:topic_without_cover_1) { create_topic(category: category, user: Discourse.system_user, raw: "a") }
  fab!(:topic_without_cover_2) { create_topic(category: category, user: Discourse.system_user, raw: "b") }
  fab!(:topic_with_cover) do
    topic = create_topic(category: category, user: Discourse.system_user, raw: "c")
    topic.update_column(:image_upload_id, 99)
    topic
  end

  it "enqueues only missing covers when requested" do
    batches = described_class.new(only_missing: true, force: false).enqueue!

    expect(batches).to eq(1)
    expect(Jobs).to have_received(:enqueue_in).with(
      0,
      Jobs::DiscourseJournals::ProcessJournalCovers,
      topic_ids: match_array([topic_without_cover_1.id, topic_without_cover_2.id]),
      force: false,
    )
  end

  it "can enqueue all topics for fingerprint-based refresh" do
    described_class.new(only_missing: false, force: true).enqueue!

    expect(Jobs).to have_received(:enqueue_in).with(
      0,
      Jobs::DiscourseJournals::ProcessJournalCovers,
      topic_ids: match_array([topic_without_cover_1.id, topic_without_cover_2.id, topic_with_cover.id]),
      force: true,
    )
  end
end
