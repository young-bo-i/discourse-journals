# frozen_string_literal: true

describe DiscourseJournals::CommentSyncer do
  fab!(:category, :category_with_definition)
  fab!(:topic) { Fabricate(:topic, category: category, title: "Journal of Collected Reviews") }
  fab!(:first_post) { Fabricate(:post, topic: topic) }

  let(:bot) { DiscourseJournals::CommentBot.user }

  before do
    enable_current_plugin
    SiteSetting.discourse_journals_enabled = true
    SiteSetting.discourse_journals_category_id = category.id
    SiteSetting.discourse_journals_api_base_url = "https://journal.example.com"
    SiteSetting.discourse_journals_api_key = "jk_test"
    topic.upsert_custom_fields(discourse_journals_api_id: "988")
  end

  def comment(record_id, text, published_at)
    {
      "record_id" => record_id,
      "source_name" => "LetPub",
      "source_url" => "https://www.letpub.com.cn/c/#{record_id}",
      "comment_text" => text,
      "published_at_iso" => published_at,
      "published_at_precision" => "datetime",
    }
  end

  def stub_comments(comments, api_id: 988)
    stub_request(:get, "https://journal.example.com/api/open/journals/#{api_id}/comments").with(
      query: hash_including("pageSize" => "100"),
    ).to_return(
      body: {
        success: true,
        data: {
          comments: comments,
          nextCursor: nil,
          total: comments.size,
        },
      }.to_json,
    )
  end

  def sync
    described_class.new(topic.reload, client: DiscourseJournals::ApiClient.new, bot: bot).sync!
  end

  def replies
    topic.posts.where("post_number > 1").order(:post_number)
  end

  describe "#sync!" do
    it "posts each comment as a reply from the collection account, oldest first, without bumping" do
      stub_comments(
        [
          comment("c-2", "newer", "2026-10-07T19:53:18"),
          comment("c-1", "older", "2025-01-02T08:00:00"),
        ],
      )
      bumped_at = topic.bumped_at

      result = sync

      expect(replies.map { |post| post.raw.lines.first.strip }).to eq(%w[older newer])
      expect(replies.map(&:user_id).uniq).to contain_exactly(bot.id)
      expect(bot).to be_bot
      expect(replies.first.created_at).to eq_time(
        ActiveSupport::TimeZone["Asia/Shanghai"].local(2025, 1, 2, 8),
      )
      expect(topic.reload.bumped_at).to eq_time(bumped_at)
      expect(result.created).to eq(2)
    end

    it "keeps the topic's stats right without pushing each reply to people reading it" do
      stub_comments(
        [
          comment("c-1", "older", "2025-01-02T08:00:00"),
          comment("c-2", "newer", "2026-10-07T19:53:18"),
        ],
      )

      messages = MessageBus.track_publish("/topic/#{topic.id}") { sync }

      expect(messages).to be_empty
      expect(topic.reload).to have_attributes(posts_count: 3, highest_post_number: 3)
      expect(topic.last_posted_at).to eq_time(replies.last.created_at)
    end

    it "leaves the replies alone when nothing changed upstream" do
      stub_comments([comment("c-1", "older", "2025-01-02T08:00:00")])
      sync

      result = sync

      expect(result.to_h.slice(:created, :unchanged)).to eq(created: 0, unchanged: 1)
      expect(replies.count).to eq(1)
    end

    it "rewrites a reply whose comment changed upstream" do
      stub_comments([comment("c-1", "older", "2025-01-02T08:00:00")])
      sync
      stub_comments([comment("c-1", "older, edited", "2025-01-02T08:00:00")])

      result = sync

      expect(result.updated).to eq(1)
      expect(replies.first.raw).to start_with("older, edited")
    end

    it "removes the replies of comments upstream dropped" do
      stub_comments(
        [
          comment("c-1", "older", "2025-01-02T08:00:00"),
          comment("c-2", "newer", "2026-10-07T19:53:18"),
        ],
      )
      sync
      dropped = replies.last
      stub_comments([comment("c-1", "older", "2025-01-02T08:00:00")])

      result = sync

      expect(result.deleted).to eq(1)
      expect(Post.with_deleted.find(dropped.id).deleted_at).to be_present
      expect(DiscourseJournals::CommentPost.pluck(:record_id)).to contain_exactly("c-1")
    end

    it "holds the deletions when upstream drops more than half of the comments" do
      stub_comments((1..4).map { |n| comment("c-#{n}", "comment #{n}", "2025-01-0#{n}T08:00:00") })
      sync
      stub_request(:get, %r{/api/open/journals/988/comments}).to_return(
        status: 404,
        body: { success: false, error: "no_comments" }.to_json,
      )

      result = sync

      expect(result.to_h.slice(:deleted, :held)).to eq(deleted: 0, held: 4)
      expect(replies.count).to eq(4)
    end

    it "follows a journal that upstream merged into another one" do
      stub_request(:get, %r{/api/open/journals/988/comments}).to_return(
        status: 301,
        headers: {
          "Location" => "/api/open/journals/1200/comments?pageSize=100",
        },
      )
      stub_comments([comment("c-1", "older", "2025-01-02T08:00:00")], api_id: 1200)

      expect(sync.created).to eq(1)
    end

    it "keeps readers who had read to the end caught up after the first import" do
      caught_up = Fabricate(:user)
      behind = Fabricate(:user)
      TopicUser.change(caught_up.id, topic.id, last_read_post_number: 1)
      TopicUser.change(behind.id, topic.id, last_read_post_number: 0)
      stub_comments(
        [
          comment("c-1", "older", "2025-01-02T08:00:00"),
          comment("c-2", "newer", "2026-10-07T19:53:18"),
        ],
      )

      sync

      expect(TopicUser.get(topic, caught_up).last_read_post_number).to eq(3)
      expect(TopicUser.get(topic, behind).last_read_post_number).to eq(0)
    end
  end
end
