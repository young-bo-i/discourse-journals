# frozen_string_literal: true

describe "Merged duplicate journal topics" do
  fab!(:category)

  before do
    enable_current_plugin
    SiteSetting.discourse_journals_enabled = true
    SiteSetting.min_topic_title_length = 5
  end

  def journal_topic(title)
    Fabricate(:post, topic: Fabricate(:topic, category: category, title: title)).topic
  end

  it "sends the copy's URL to the kept topic with a 301" do
    keep = journal_topic("Environmental Epigenetics Journal")
    copy = journal_topic("Environmental Epigenetics Archive")

    DiscourseJournals::DuplicateTopicMerger.merge!(copy.id, keep.id)
    get copy.relative_url

    expect(response.status).to eq(301)
    expect(response).to redirect_to(keep.relative_url)
  end

  it "redirects copies whose slugs are stored percent-encoded" do
    SiteSetting.slug_generation_method = "encoded"
    keep = journal_topic("环境表观遗传学期刊")
    copy = journal_topic("环境表观遗传学档案")

    DiscourseJournals::DuplicateTopicMerger.merge!(copy.id, keep.id)
    get copy.relative_url

    expect(response.status).to eq(301)
    expect(response).to redirect_to(keep.relative_url)
  end
end
