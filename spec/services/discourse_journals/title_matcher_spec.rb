# frozen_string_literal: true

describe DiscourseJournals::TitleMatcher do
  before { enable_current_plugin }

  it "uses the same normalized title key for forum and api titles" do
    forum_title = "Journal: Applied Testing Review"
    api_title = "Journal Applied Testing Review"

    expect(described_class.normalized_title_key(forum_title)).to eq(
      described_class.normalized_title_key(api_title),
    )
  end
end
