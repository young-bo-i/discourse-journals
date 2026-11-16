# frozen_string_literal: true

describe Jobs::DiscourseJournals::OpenJournalTopics do
  fab!(:category)
  fab!(:journal) { Fabricate(:topic, category: category, closed: true) }
  fab!(:other_topic) { Fabricate(:topic, closed: true) }

  before do
    enable_current_plugin
    SiteSetting.discourse_journals_category_id = category.id
  end

  describe "#execute" do
    it "opens closed journal topics quietly, leaving other categories alone" do
      updated_at = journal.updated_at

      expect { described_class.new.execute({}) }.not_to change { Post.count }

      expect(journal.reload.closed).to eq(false)
      expect(journal.updated_at).to eq_time(updated_at)
      expect(other_topic.reload.closed).to eq(true)
    end
  end
end
