# frozen_string_literal: true

describe "Collected journal comments in the topic view" do
  fab!(:topic)
  fab!(:first_post) { Fabricate(:post, topic: topic) }

  let(:bot) { DiscourseJournals::CommentBot.user }

  before do
    enable_current_plugin
    SiteSetting.discourse_journals_enabled = true
  end

  def collected_reply(source:, code:, **fields)
    Fabricate(:post, topic: topic, user: bot).tap do |post|
      post.custom_fields[DiscourseJournals::CommentAuthor::FIELD] = {
        "source" => source,
        "code" => code,
      }.merge(fields.stringify_keys)
      post.save_custom_fields
    end
  end

  def serialized(attribute)
    get "/t/#{topic.id}.json"
    response.parsed_body.dig("post_stream", "posts").to_h { |post| [post["id"], post[attribute]] }
  end

  def authors
    serialized("dj_comment_author")
  end

  it "shows a collected reply under its stored name, or a word-pair name before one is assigned" do
    named = collected_reply(source: "LetPub", code: "000000", name: "安静的熊猫K")
    unnamed = collected_reply(source: "LetPub", code: "000001")
    SiteSetting.discourse_journals_comment_author_modifiers = "安静的|Lazy"
    SiteSetting.discourse_journals_comment_author_nouns = "熊猫"
    SiteSetting.discourse_journals_comment_author_suffixes = ""

    expect(authors).to eq(
      first_post.id => nil,
      named.id => {
        "name" => "安静的熊猫K",
        "code" => "000000",
      },
      unnamed.id => {
        "name" => "Lazy熊猫",
        "code" => "000001",
      },
    )
  end

  it "shows the source note under a collected reply only while the setting is on" do
    reply =
      collected_reply(
        source: "LetPub",
        code: "6826A9",
        source_url: "https://www.letpub.com.cn/c/1",
        published_at: "2026-10-07T19:53:18+08:00",
        precision: "datetime",
      )

    expect(serialized("dj_comment_source")).to eq(
      first_post.id => nil,
      reply.id => {
        "text" => "Source: LetPub · Originally published 2026-10-07 19:53",
        "url" => "https://www.letpub.com.cn/c/1",
      },
    )

    SiteSetting.discourse_journals_comment_source_note_enabled = false

    expect(serialized("dj_comment_source")).to eq(first_post.id => nil, reply.id => nil)
    expect(authors[reply.id]).to be_present
  end
end
