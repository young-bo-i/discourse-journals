# frozen_string_literal: true

describe DiscourseJournals::JournalUpserter do
  before { enable_current_plugin }

  fab!(:category)

  before do
    SiteSetting.discourse_journals_category_id = category.id
    SiteSetting.discourse_journals_close_topics = true
    SiteSetting.discourse_journals_bypass_bump = true
  end

  let(:profile) { DiscourseJournals::ProfileStore.defaults }

  it "creates a closed journal topic with a filled year range" do
    upserter = described_class.new(profile:)

    result =
      upserter.upsert!(
        issn: "1234-5678",
        name: "Journal of Example Studies",
        impact_factors: { 2021 => "2.31", 2023 => "3.12" },
        cas: { "2025" => { "published_at" => "2025-03-20", "rows" => [] } },
        wos: { "2025" => { "published_at" => "2025-06-18", "jcr_rows" => [], "jci_rows" => [] } },
      )

    expect(result).to eq(:created)

    topic = TopicCustomField.where(name: DiscourseJournals::CUSTOM_FIELD_ISSN, value: "1234-5678").first.topic
    expect(topic.category_id).to eq(category.id)
    expect(topic.closed).to eq(true)
    expect(topic.title).to eq("Journal of Example Studies (ISSN 1234-5678)")

    raw = topic.first_post.raw
    expect(raw).to include("| 2023 | 3.12 |")
    expect(raw).to include("| 2022 | — |")
    expect(raw).to include("| 2021 | 2.31 |")
  end
end

