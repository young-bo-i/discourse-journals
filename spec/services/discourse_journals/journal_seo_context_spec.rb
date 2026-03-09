# frozen_string_literal: true

describe DiscourseJournals::JournalSeoContext do
  before do
    enable_current_plugin
    SiteSetting.discourse_journals_enabled = true
  end

  fab!(:category)
  fab!(:topic) do
    create_topic(
      category: category,
      user: Discourse.system_user,
      title: "Journal of Test Contexts",
      raw: "topic content",
    )
  end

  it "parses seo data once and resolves templates from cached values" do
    topic.custom_fields["discourse_journals_issn_l"] = "1234-5678"
    topic.custom_fields["discourse_journals_publisher"] = "Testing Press"
    topic.custom_fields["discourse_journals_country"] = "CN"
    topic.custom_fields["discourse_journals_data"] =
      {
        identity: { abbreviation: "JTC" },
        publication: { first_publication_year: 2001 },
      }.to_json
    topic.save_custom_fields

    context = described_class.new(topic: topic)

    expect(context.resolve_template("{{title}} - {{publisher}} - {{issn}}")).to eq(
      "Journal of Test Contexts - Testing Press - 1234-5678",
    )

    first = context.parsed_data
    second = context.parsed_data
    expect(first).to equal(second)
    expect(first.dig(:identity, :abbreviation)).to eq("JTC")
  end
end
