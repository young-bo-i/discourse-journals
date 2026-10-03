# frozen_string_literal: true

describe DiscourseJournals::SearchController do
  fab!(:category)
  fab!(:visible_tag) { Fabricate(:tag, name: "scie") }
  fab!(:hidden_tag) { Fabricate(:tag, name: "staff-only") }
  fab!(:journal) do
    Fabricate(
      :topic,
      category: category,
      title: "Nature Neuroscience Journal",
      tags: [visible_tag, hidden_tag],
    )
  end

  before do
    enable_current_plugin
    SiteSetting.discourse_journals_enabled = true
    SiteSetting.discourse_journals_category_id = category.id
    SiteSetting.tagging_enabled = true
    create_hidden_tags([hidden_tag.name])
    journal.update_columns(excerpt: "Nature Neuroscience, published by Springer Nature")
  end

  describe "GET /journals/search" do
    it "lets anonymous visitors look journals up and only exposes visible tags" do
      get "/journals/search.json", params: { q: "neuroscience" }

      expect(response.status).to eq(200)
      expect(response.parsed_body["topics"]).to eq(
        [
          {
            "id" => journal.id,
            "title" => journal.title,
            "slug" => journal.slug,
            "tags" => [visible_tag.name],
            "excerpt" => "Nature Neuroscience, published by Springer Nature",
          },
        ],
      )
    end
  end
end
