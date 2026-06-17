# frozen_string_literal: true

describe DiscourseJournals::JournalTagManager do
  before do
    enable_current_plugin
    described_class.reset_cache!
  end

  after { described_class.reset_cache! }

  describe ".build_tag_assignments emerging-tier (新锐分区) tags" do
    it "derives the emerging-tier zone tag from the major quartile" do
      normalized = { xinrui_partition: { data: [{ major_quartile: "3 区", top: "—" }] } }

      assignments = described_class.build_tag_assignments(normalized)

      expect(assignments[:xinrui_zone]).to eq(["新锐:3区"])
      expect(assignments[:xinrui_top]).to be_nil
    end

    it "adds the emerging-tier top tag when top is 是" do
      normalized = { xinrui_partition: { data: [{ major_quartile: "1 区", top: "是" }] } }

      assignments = described_class.build_tag_assignments(normalized)

      expect(assignments[:xinrui_zone]).to eq(["新锐:1区"])
      expect(assignments[:xinrui_top]).to eq(["新锐:top"])
    end

    it "does not assign emerging-tier tags when the partition is absent" do
      assignments = described_class.build_tag_assignments({})

      expect(assignments[:xinrui_zone]).to be_nil
      expect(assignments[:xinrui_top]).to be_nil
    end
  end

  describe ".apply_tags! delta write + reconcile_counts!" do
    fab!(:category)
    fab!(:topic) { Fabricate(:topic, category: category) }

    before { SiteSetting.tagging_enabled = true }

    it "writes tags as join-row deltas and full-replaces them on re-apply" do
      described_class.apply_tags!(topic, { jcr: { data: [{ quartile: "Q1" }] } })
      expect(topic.reload.tags.count).to eq(1)
      first_name = topic.tags.first.name

      described_class.apply_tags!(topic, { jcr: { data: [{ quartile: "Q2" }] } })
      topic.reload
      expect(topic.tags.count).to eq(1)
      expect(topic.tags.first.name).not_to eq(first_name)
    end

    it "reconcile_counts! makes tag and category-tag counts match the delta-written rows" do
      described_class.apply_tags!(topic, { jcr: { data: [{ quartile: "Q1" }] } })
      tag = topic.reload.tags.first

      described_class.reconcile_counts!

      expect(tag.reload.public_topic_count).to eq(1)
      expect(
        CategoryTagStat.find_by(tag_id: tag.id, category_id: category.id)&.topic_count,
      ).to eq(1)
    end
  end
end
