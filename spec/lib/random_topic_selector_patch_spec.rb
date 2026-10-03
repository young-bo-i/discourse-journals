# frozen_string_literal: true

describe RandomTopicSelector do
  fab!(:category)

  before do
    enable_current_plugin
    SiteSetting.discourse_journals_enabled = true
    SiteSetting.discourse_journals_category_id = category.id
    Discourse.redis.del(described_class.cache_key(category))
  end

  describe ".next for the journal category" do
    it "skips the random pool query while journal topics are kept closed" do
      SiteSetting.discourse_journals_close_topics = true
      Fabricate(:topic, category: category, closed: true)

      queries = track_sql_queries { expect(described_class.next(5, category)).to eq([]) }

      expect(queries.grep(/RANDOM\(\)/i)).to be_empty
    end

    it "keeps core random suggestions when journal topics are left open" do
      SiteSetting.discourse_journals_close_topics = false
      topic = Fabricate(:topic, category: category)

      expect(described_class.next(5, category)).to include(topic.id)
    end
  end
end
