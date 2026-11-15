# frozen_string_literal: true

describe DiscourseJournals::CommentPostBuilder do
  let(:now) { Time.zone.parse("2026-11-15 10:00:00 UTC") }
  let(:beijing) { ActiveSupport::TimeZone["Asia/Shanghai"] }

  def build(attributes = {})
    described_class.new(
      {
        "record_id" => "letpub-comment-1",
        "source_name" => "LetPub",
        "source_url" => "https://www.letpub.com.cn/index.php?journalid=2950",
        "comment_text" => "审稿很快",
        "published_at_iso" => "2026-10-07T19:53:18",
        "published_at_precision" => "datetime",
        "original_language" => "zh",
      }.merge(attributes),
      now: now,
    )
  end

  def cooked_paragraphs(builder)
    Nokogiri::HTML5.fragment(PrettyText.cook(builder.raw)).css("p").map(&:text)
  end

  before { enable_current_plugin }

  def note(builder)
    DiscourseJournals::CommentSourceNote.display(builder.custom_fields)
  end

  it "keeps the source out of the text and notes where and when it was first published" do
    builder = build

    expect(builder.raw).to eq("审稿很快")
    expect(note(builder)).to eq(
      text: "Source: LetPub · Originally published 2026-10-07 19:53",
      url: "https://www.letpub.com.cn/index.php?journalid=2950",
    )
    expect(builder.created_at).to eq_time(beijing.local(2026, 10, 7, 19, 53, 18))
  end

  it "dates a year-only comment by its year and an undated one by when it is collected" do
    year_only = build("published_at_iso" => "2016", "published_at_precision" => "year")
    undated = build("published_at_iso" => nil, "published_at_precision" => "unknown")

    expect(note(year_only)[:text]).to eq("Source: LetPub · Originally published 2016")
    expect(year_only.created_at).to eq_time(beijing.local(2016, 1, 1))
    expect(note(undated)[:text]).to eq("Source: LetPub · Original publication date unknown")
    expect(undated.created_at).to eq_time(now)
  end

  it "drops a source link that is not a web address" do
    expect(note(build("source_url" => "javascript:alert(1)"))[:url]).to be_nil
  end

  it "changes its digest when only the source details change" do
    expect(build.digest).not_to eq(build("source_url" => "https://example.com/other").digest)
  end

  it "shows the comment text as written, without Markdown, mentions or HTML" do
    text = "1. 不是列表 **快** @admin <b>x</b> #tag"
    builder = build("comment_text" => text)

    cooked = PrettyText.cook(builder.raw)

    expect(cooked_paragraphs(builder).first).to eq(text)
    expect(
      Nokogiri::HTML5.fragment(cooked).css("strong, b, a.mention, a.hashtag-cooked, ol"),
    ).to be_empty
  end

  it "folds the Chinese text of an English original in as a translation" do
    english =
      build(
        "comment_text" => "Fast review",
        "comment_text_zh" => "审稿很快",
        "original_language" => "en",
      )
    chinese = build("comment_text_en" => "Fast review")

    expect(english.raw).to include("[details=\"Chinese translation\"]\n审稿很快\n[/details]")
    expect(chinese.raw).not_to include("[details")
  end

  it "shows only the facts upstream marks as high confidence" do
    builder =
      build(
        "paper_status" => "accepted",
        "first_review_days" => 30,
        "overall_rating_0_5" => 4,
        "confidence" => {
          "status" => "high",
          "time_metrics" => "low",
          "rating_metrics" => "high",
        },
      )

    expect(builder.raw.lines.first.strip).to eq("**Accepted** · Overall 4.0/5")
  end
end
