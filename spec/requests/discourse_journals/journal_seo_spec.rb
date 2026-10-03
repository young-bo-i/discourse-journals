# frozen_string_literal: true

describe "Journal page SEO" do
  fab!(:category) { Fabricate(:category, name: "Journals") }
  fab!(:journal) { Fabricate(:topic, category: category, title: "Nature Neuroscience Journal") }
  fab!(:journal_post) { Fabricate(:post, topic: journal) }
  fab!(:related) { Fabricate(:topic, category: category, title: "Neuron Research Letters") }

  before do
    enable_current_plugin
    SiteSetting.discourse_journals_enabled = true
    SiteSetting.discourse_journals_category_id = category.id
    SiteSetting.discourse_journals_title_suffix = "Impact factor & ISSN"
    journal.upsert_custom_fields(
      discourse_journals_issn_l: "1097-6256",
      discourse_journals_publisher: "Springer Nature",
      discourse_journals_data: {
        jcr: {
          data: [{ year: 2025, impact_factor: 21.2, quartile: "Q1" }],
        },
      }.to_json,
    )
    related.upsert_custom_fields(discourse_journals_publisher: "Springer Nature")
  end

  it "puts the title suffix right after the journal name" do
    get journal.relative_url

    expect(response.body).to include(
      "<title>Nature Neuroscience Journal - Impact factor &amp; ISSN - Journals - #{SiteSetting.title}</title>",
    )
  end

  it "describes the journal from its synced record" do
    SiteSetting.discourse_journals_meta_description = "{{summary}}"

    get journal.relative_url

    expect(response.body).to include(
      %(<meta name="description" content="Nature Neuroscience Journal: 2025 impact factor 21.2, JCR Q1. ISSN 1097-6256, published by Springer Nature.">),
    )
  end

  it "links crawlers to related journals" do
    get journal.relative_url, headers: { "User-Agent" => "Googlebot" }

    expect(response.body).to include(
      %(<a href="#{related.relative_url}">Neuron Research Letters</a>),
    )
  end

  it "keeps every crawler group away from page view beacons" do
    get "/robots.txt"

    groups =
      response.body.split("User-agent:").select { |group| group.include?("Disallow: /admin/") }
    expect(groups).to all(include("Disallow: /srv/pv", "Disallow: /pageview"))
    expect(groups.size).to be >= 2
  end
end
