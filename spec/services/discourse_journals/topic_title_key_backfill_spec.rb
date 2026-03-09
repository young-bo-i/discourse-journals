# frozen_string_literal: true

describe DiscourseJournals::TopicTitleKeyBackfill do
  before do
    enable_current_plugin
    SiteSetting.discourse_journals_enabled = true
    SiteSetting.discourse_journals_category_id = category.id
  end

  fab!(:category)
  fab!(:journal_topic) do
    create_topic(
      category: category,
      user: Discourse.system_user,
      title: "Journal: Applied Testing Review",
      raw: "content",
    )
  end

  it "backfills normalized title keys for current journal topics" do
    updated = described_class.backfill_current_category!

    expect(updated).to eq(1)
    expect(journal_topic.reload.custom_fields["discourse_journals_normalized_title_key"]).to eq(
      DiscourseJournals::TitleMatcher.normalized_title_key(journal_topic.title),
    )
  end
end
