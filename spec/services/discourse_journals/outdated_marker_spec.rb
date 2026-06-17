# frozen_string_literal: true

describe DiscourseJournals::OutdatedMarker do
  before { enable_current_plugin }

  fab!(:topic) do
    create_post(
      user: Discourse.system_user,
      title: "Outdated Journal",
      raw: "journal body content",
    ).topic
  end

  def set_journal_data(target)
    target.upsert_custom_fields(
      discourse_journals_data: { identity: { title: target.title }, metrics: {} }.to_json,
    )
  end

  describe ".mark!" do
    it "flags the topic, closes it, and renders the outdated banner into the post" do
      set_journal_data(topic)

      expect(described_class.mark!(topic)).to eq(true)

      topic.reload
      expect(described_class.outdated?(topic)).to eq(true)
      expect(topic.closed).to eq(true)
      expect(topic.first_post.reload.cooked).to include("dj-outdated-notice")
    end

    it "is idempotent: a second call is a no-op and never adds a second flag" do
      set_journal_data(topic)
      described_class.mark!(topic)

      expect(described_class.mark!(topic.reload)).to eq(false)
      expect(TopicCustomField.where(topic_id: topic.id, name: described_class::FIELD).count).to eq(1)
    end

    it "still flags and closes a topic that has no stored journal data" do
      expect(described_class.mark!(topic)).to eq(true)

      topic.reload
      expect(described_class.outdated?(topic)).to eq(true)
      expect(topic.closed).to eq(true)
      expect(topic.first_post.reload.cooked).to include("dj-outdated-notice")
    end
  end

  describe ".mark_batch" do
    it "marks every topic and returns how many were newly marked" do
      other =
        create_post(
          user: Discourse.system_user,
          title: "Another Journal",
          raw: "another body",
        ).topic

      expect(described_class.mark_batch([topic.id, other.id])).to eq(2)
      expect(described_class.outdated?(topic.reload)).to eq(true)
      expect(described_class.outdated?(other.reload)).to eq(true)
    end
  end
end
