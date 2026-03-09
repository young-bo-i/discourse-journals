# frozen_string_literal: true

describe DiscourseJournals::JournalUpserter do
  before do
    enable_current_plugin
    SiteSetting.discourse_journals_enabled = true
    SiteSetting.discourse_journals_category_id = category.id
    SiteSetting.discourse_journals_close_topics = false

    allow(DiscourseJournals::JournalTagManager).to receive(:apply_tags!)
    allow(DiscourseJournals::TopicCoverManager).to receive(:process!)
    allow(SearchIndexer).to receive(:queue_post_reindex)
  end

  fab!(:category)
  fab!(:existing_topic) do
    create_topic(
      category: category,
      user: Discourse.system_user,
      title: "Journal: Testing & Review",
      raw: "old content",
    )
  end

  describe "#upsert_prepared!" do
    it "updates an existing topic when normalized titles match" do
      existing_topic

      prepared = {
        title: "Journal Testing Review",
        html: "<p>new content</p>",
        raw_text: "new content",
        normalized: {
          identity: {
            title: "Journal Testing Review",
          },
        },
        normalized_json: { identity: { title: "Journal Testing Review" } }.to_json,
        normalized_title_key: DiscourseJournals::TitleMatcher.normalized_title_key("Journal Testing Review"),
        issn_l: nil,
        publisher: "Test Publisher",
        cover_url: nil,
        country: "CN",
      }

      expect(
        DiscourseJournals::TitleMatcher.normalize(existing_topic.title)
      ).to eq(DiscourseJournals::TitleMatcher.normalize(prepared[:title]))

      expect do
        result = described_class.new.upsert_prepared!(prepared)
        expect(result).to eq(:updated)
      end.not_to change { Topic.where(category_id: category.id).count }

      existing_topic.reload
      expect(existing_topic.title).to eq("Journal Testing Review")
      expect(existing_topic.first_post.raw).to eq("new content")
      expect(existing_topic.custom_fields["discourse_journals_publisher"]).to eq("Test Publisher")
      expect(existing_topic.custom_fields["discourse_journals_country"]).to eq("CN")
      expect(existing_topic.custom_fields["discourse_journals_normalized_title_key"]).to eq(
        DiscourseJournals::TitleMatcher.normalized_title_key("Journal Testing Review"),
      )
    end
  end

  describe "#find_existing_topic_by_title" do
    it "matches an existing topic by normalized title key" do
      existing_topic.custom_fields["discourse_journals_normalized_title_key"] =
        DiscourseJournals::TitleMatcher.normalized_title_key("Journal Testing Review")
      existing_topic.save_custom_fields

      upserter = described_class.new

      expect(
        upserter.send(
          :find_existing_topic_by_title,
          "Journal Testing Review",
          DiscourseJournals::TitleMatcher.normalized_title_key("Journal Testing Review"),
          category,
        ),
      ).to eq(existing_topic)
    end

    it "refuses ambiguous normalized matches" do
      existing_topic
      existing_topic.custom_fields["discourse_journals_normalized_title_key"] =
        DiscourseJournals::TitleMatcher.normalized_title_key("Journal Testing Review")
      existing_topic.save_custom_fields
      duplicate_topic = create_topic(
        category: category,
        user: Discourse.system_user,
        title: "Journal Testing - Review",
        raw: "other content",
      )
      duplicate_topic.custom_fields["discourse_journals_normalized_title_key"] =
        DiscourseJournals::TitleMatcher.normalized_title_key("Journal Testing Review")
      duplicate_topic.save_custom_fields

      upserter = described_class.new

      expect(
        upserter.send(
          :find_existing_topic_by_title,
          "Journal Testing Review",
          DiscourseJournals::TitleMatcher.normalized_title_key("Journal Testing Review"),
          category,
        ),
      ).to eq(nil)
    end

    it "keeps a compatibility fallback for old topics without title key backfill" do
      upserter = described_class.new

      expect(
        upserter.send(
          :find_existing_topic_by_title,
          "Journal Testing Review",
          DiscourseJournals::TitleMatcher.normalized_title_key("Journal Testing Review"),
          category,
        ),
      ).to eq(existing_topic)
    end
  end

  describe "#store_custom_fields!" do
    it "stores cover urls as absolute remote urls" do
      prepared = {
        title: existing_topic.title,
        html: "<p>same content</p>",
        raw_text: "same content",
        normalized: {
          identity: {
            title: existing_topic.title,
          },
        },
        normalized_json: { identity: { title: existing_topic.title } }.to_json,
        normalized_title_key: DiscourseJournals::TitleMatcher.normalized_title_key(existing_topic.title),
        issn_l: nil,
        publisher: nil,
        cover_url: "/covers/test.png",
        country: nil,
      }

      described_class.new.upsert_prepared!(prepared, existing_topic_id: existing_topic.id)

      existing_topic.reload
      expect(existing_topic.custom_fields["discourse_journals_cover_url"]).to eq(
        "https://journal.scholay.com/covers/test.png",
      )
    end

    it "removes stale cover metadata when the latest payload has no cover data" do
      existing_topic.custom_fields["discourse_journals_cover_url"] = "/old-cover.png"
      existing_topic.custom_fields["discourse_journals_country"] = "US"
      existing_topic.custom_fields["discourse_journals_publisher"] = "Old Publisher"
      existing_topic.save_custom_fields

      prepared = {
        title: existing_topic.title,
        html: "<p>same content</p>",
        raw_text: "same content",
        normalized: {
          identity: {
            title: existing_topic.title,
          },
        },
        normalized_json: { identity: { title: existing_topic.title } }.to_json,
        normalized_title_key: DiscourseJournals::TitleMatcher.normalized_title_key(existing_topic.title),
        issn_l: nil,
        publisher: nil,
        cover_url: nil,
        country: nil,
      }

      described_class.new.upsert_prepared!(prepared, existing_topic_id: existing_topic.id)

      existing_topic.reload
      expect(existing_topic.custom_fields["discourse_journals_cover_url"]).to eq(nil)
      expect(existing_topic.custom_fields["discourse_journals_country"]).to eq(nil)
      expect(existing_topic.custom_fields["discourse_journals_publisher"]).to eq(nil)
    end
  end
end
