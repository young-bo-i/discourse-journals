# frozen_string_literal: true

describe DiscourseJournals::CommentAuthor do
  fab!(:topic)
  fab!(:first_post) { Fabricate(:post, topic: topic) }

  before do
    enable_current_plugin
    SiteSetting.discourse_journals_comment_author_modifiers = "安静的|Lazy"
    SiteSetting.discourse_journals_comment_author_nouns = "熊猫|Fox"
    SiteSetting.discourse_journals_comment_author_suffixes = ""
  end

  def collected_reply(code)
    Fabricate(:post, topic: topic).tap do |post|
      post.custom_fields[described_class::FIELD] = { "source" => "LetPub", "code" => code }
      post.save_custom_fields
    end
  end

  def name_of(post)
    described_class.fields(
      PostCustomField.find_by(post_id: post.id, name: described_class::FIELD).value,
    )[
      "name"
    ]
  end

  it "combines one modifier with one noun, picked by the code" do
    expect(described_class.base_name("000000")).to eq("安静的熊猫")
    expect(described_class.base_name("000001")).to eq("Lazy熊猫")
    expect(described_class.base_name("000002")).to eq("安静的Fox")
  end

  it "appends a suffix, or none, picked by what is left of the code" do
    SiteSetting.discourse_journals_comment_author_suffixes = "同学|_Lab"

    expect(described_class.base_name("000000")).to eq("安静的熊猫")
    expect(described_class.base_name("000004")).to eq("安静的熊猫同学")
    expect(described_class.base_name("000008")).to eq("安静的熊猫_Lab")
  end

  it "keeps the plain name for the earliest reply and adds letters to later repeats" do
    first = collected_reply("000000")
    second = collected_reply("000004")
    third = collected_reply("000008")

    described_class.assign!(topic.id)

    names = [first, second, third].map { |post| name_of(post) }
    expect(names.first).to eq("安静的熊猫")
    expect(names[1]).to match(/\A安静的熊猫[A-Z]+\z/)
    expect(names[2]).to match(/\A安静的熊猫[A-Z]+\z/)
    expect(names.uniq.size).to eq(3)

    expect { described_class.assign!(topic.id) }.not_to change {
      [first, second, third].map { |post| name_of(post) }
    }
  end

  it "renames every collected reply in the background when a word list changes" do
    expect_enqueued_with(job: Jobs::DiscourseJournals::RenameCommentAuthors) do
      SiteSetting.discourse_journals_comment_author_nouns = "海豚"
    end
  end
end
