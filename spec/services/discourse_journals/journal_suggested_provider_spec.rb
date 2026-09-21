# frozen_string_literal: true

describe DiscourseJournals::JournalSuggestedProvider do
  fab!(:category)
  fab!(:other_category, :category)

  before do
    enable_current_plugin
    SiteSetting.tagging_enabled = true
    SiteSetting.discourse_journals_enabled = true
    SiteSetting.discourse_journals_category_id = category.id
    SiteSetting.discourse_journals_suggested_mode = "custom_only"
    SiteSetting.discourse_journals_suggested_count = 3
  end

  describe ".call" do
    it "ranks candidates by selective tags, publisher, and country" do
      SiteSetting.discourse_journals_suggested_criteria = "tags|publisher|country"
      first_tag = Fabricate(:tag, name: "journal-systems")
      second_tag = Fabricate(:tag, name: "journal-methods")
      topic = Fabricate(:topic, category: category)
      strongest_match = Fabricate(:topic, category: category, bumped_at: 3.days.ago)
      tag_match = Fabricate(:topic, category: category, bumped_at: 2.days.ago)
      field_match = Fabricate(:topic, category: category, bumped_at: 1.day.ago)
      other_category_match = Fabricate(:topic, category: other_category)

      set_traits(topic, tags: [first_tag, second_tag], publisher: "Testing Press", country: "CN")
      set_traits(
        strongest_match,
        tags: [first_tag, second_tag],
        publisher: "Testing Press",
        country: "CN",
      )
      set_traits(tag_match, tags: [first_tag, second_tag])
      set_traits(field_match, publisher: "Testing Press", country: "CN")
      set_traits(
        other_category_match,
        tags: [first_tag, second_tag],
        publisher: "Testing Press",
        country: "CN",
      )

      result = described_class.call(topic, nil, nil)

      expect(result.fetch(:result).pluck(:id)).to eq(
        [strongest_match.id, tag_match.id, field_match.id],
      )
    end

    it "ignores high-cardinality tags when building candidates" do
      SiteSetting.discourse_journals_suggested_criteria = "tags"
      topic = Fabricate(:topic, category: category)
      broad_tag = Fabricate(:tag, name: "journal-broad")
      selective_tag = Fabricate(:tag, name: "journal-selective")
      broad_match = Fabricate(:topic, category: category)
      another_broad_match = Fabricate(:topic, category: category)
      selective_match = Fabricate(:topic, category: category)

      set_traits(topic, tags: [broad_tag, selective_tag])
      set_traits(broad_match, tags: [broad_tag])
      set_traits(another_broad_match, tags: [broad_tag])
      set_traits(selective_match, tags: [selective_tag])

      stub_const(described_class, :MAX_TAG_TOPIC_COUNT, 2) do
        result = described_class.call(topic, nil, nil)

        expect(result.fetch(:result).pluck(:id)).to eq([selective_match.id])
      end
    end

    it "ignores high-cardinality custom fields when building candidates" do
      SiteSetting.discourse_journals_suggested_criteria = "publisher"
      topic = Fabricate(:topic, category: category)
      first_match = Fabricate(:topic, category: category)
      second_match = Fabricate(:topic, category: category)

      [topic, first_match, second_match].each do |matching_topic|
        set_traits(matching_topic, publisher: "Broad Publisher")
      end

      stub_const(described_class, :MAX_CUSTOM_FIELD_TOPIC_COUNT, 2) do
        result = described_class.call(topic, nil, nil)

        expect(result.fetch(:result)).to be_empty
      end
    end
  end

  def set_traits(topic, tags: [], publisher: nil, country: nil)
    topic.tags = tags
    if publisher
      TopicCustomField.create!(
        topic_id: topic.id,
        name: "discourse_journals_publisher",
        value: publisher,
      )
    end
    if country
      TopicCustomField.create!(
        topic_id: topic.id,
        name: "discourse_journals_country",
        value: country,
      )
    end
  end
end
