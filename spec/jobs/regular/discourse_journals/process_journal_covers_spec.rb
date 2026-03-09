# frozen_string_literal: true

describe Jobs::DiscourseJournals::ProcessJournalCovers do
  before do
    enable_current_plugin
    SiteSetting.discourse_journals_enabled = true
    SiteSetting.discourse_journals_category_id = category.id
    SiteSetting.discourse_journals_download_covers = true
    allow(Theme).to receive_message_chain(:user_selectable, :pluck).and_return([])
    allow(Jobs).to receive(:enqueue_in)
    allow(DiscourseJournals::TopicCoverManager).to receive(:process!)
  end

  fab!(:category)
  fab!(:topic) do
    create_topic(
      category: category,
      user: Discourse.system_user,
      title: "Journal of Applied Testing",
      raw: "topic content",
    )
  end

  it "reuses TopicCoverManager with stored topic metadata" do
    topic.custom_fields["discourse_journals_cover_url"] = "/covers/123.png"
    topic.custom_fields["discourse_journals_issn_l"] = "1234-5678"
    topic.custom_fields["discourse_journals_country"] = "CN"
    topic.custom_fields["discourse_journals_publisher"] = "Testing Press"
    topic.save_custom_fields

    described_class.new.execute(topic_ids: [topic.id], force: true)

    expect(DiscourseJournals::TopicCoverManager).to have_received(:process!).with(
      topic: topic,
      cover_url: "/covers/123.png",
      issn: "1234-5678",
      country: "CN",
      publisher: "Testing Press",
      force: true,
      thumbnail_sizes: [],
    )
  end

  it "re-enqueues deferred topics" do
    allow(DiscourseJournals::TopicCoverManager).to receive(:process!).and_return(:deferred)

    described_class.new.execute(topic_ids: [topic.id], force: false)

    expect(Jobs).to have_received(:enqueue_in).with(
      1.minute,
      described_class,
      topic_ids: [topic.id],
      force: false,
    )
  end
end
