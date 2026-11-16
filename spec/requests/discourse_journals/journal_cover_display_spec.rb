# frozen_string_literal: true

describe "Journal cover display" do
  fab!(:category)
  fab!(:topic) { create_post(user: Discourse.system_user, category: category).topic }

  let(:upstream_cover) do
    "https://journal.example.com/api/covers/preview/1.webp?v=a855e4f0a5126ab1"
  end

  before do
    enable_current_plugin
    SiteSetting.discourse_journals_enabled = true
    SiteSetting.discourse_journals_category_id = category.id
  end

  it "shares a journal topic with its upstream cover as the og:image" do
    topic.upsert_custom_fields(discourse_journals_cover_url: upstream_cover)

    get "/t/#{topic.slug}/#{topic.id}"

    expect(response.status).to eq(200)
    expect(response.body).to include(%(<meta property="og:image" content="#{upstream_cover}"))
  end

  it "never shares a dead name-addressed cover" do
    legacy_cover = "https://journal.example.com/api/covers/image/Annals%20of%20Neurology"
    topic.upsert_custom_fields(discourse_journals_cover_url: legacy_cover)

    get "/t/#{topic.slug}/#{topic.id}"

    expect(response.body).not_to include(legacy_cover)
  end
end
