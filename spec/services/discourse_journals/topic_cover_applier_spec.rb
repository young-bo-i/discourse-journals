# frozen_string_literal: true

describe DiscourseJournals::TopicCoverApplier do
  before do
    enable_current_plugin
    SiteSetting.discourse_journals_api_base_url = "https://journal.example.com"
  end

  fab!(:topic) do
    create_post(user: Discourse.system_user, title: "Annals of Neurology", raw: "journal").topic
  end

  let(:preview_path) { "/api/covers/preview/2.webp?v=74314c293b4df29b" }
  let(:legacy_path) { "/api/covers/image/Annals%20of%20Neurology" }

  def store_journal(cover_url:, cover_original_url: nil)
    data = {
      identity: {
        title: topic.title,
        cover_url: cover_url,
        cover_original_url: cover_original_url,
      },
      metrics: {
      },
    }
    fields = { discourse_journals_data: data.to_json }
    fields[:discourse_journals_cover_url] = "https://journal.example.com#{cover_url}" if cover_url
    topic.upsert_custom_fields(fields)
  end

  def stored_identity
    JSON.parse(topic.reload.custom_fields["discourse_journals_data"])["identity"]
  end

  describe ".apply!" do
    it "replaces a legacy cover everywhere it is shown and advances updated_at" do
      store_journal(cover_url: legacy_path, cover_original_url: "https://syndetics.example/x.jpg")
      topic.update_columns(updated_at: 1.day.ago)

      expect(described_class.apply!(topic, preview_path)).to eq(:updated)

      expect(stored_identity).to include("cover_url" => preview_path, "cover_original_url" => nil)
      expect(topic.custom_fields["discourse_journals_cover_url"]).to eq(
        "https://journal.example.com#{preview_path}",
      )
      expect(topic.first_post.cooked).to include("https://journal.example.com#{preview_path}")
      expect(topic.updated_at).to be > 1.minute.ago
    end

    it "leaves a topic that already shows the cover untouched" do
      store_journal(cover_url: preview_path)
      topic.update_columns(updated_at: 1.day.ago)

      expect(described_class.apply!(topic, preview_path)).to eq(:unchanged)
      expect(topic.reload.updated_at).to be < 1.hour.ago
    end

    it "clears the stored cover so the topic falls back to the default" do
      store_journal(cover_url: legacy_path)

      expect(described_class.apply!(topic, nil)).to eq(:cleared)

      expect(stored_identity["cover_url"]).to be_nil
      expect(topic.custom_fields["discourse_journals_cover_url"]).to be_nil
      expect(topic.first_post.cooked).not_to include(legacy_path)
    end

    it "keeps the outdated banner when re-rendering an outdated topic" do
      store_journal(cover_url: nil)
      topic.upsert_custom_fields(discourse_journals_outdated: Time.current.iso8601)

      described_class.apply!(topic, preview_path)

      expect(topic.first_post.reload.cooked).to include("dj-outdated-notice")
    end

    it "skips a topic without stored journal data" do
      expect(described_class.apply!(topic, preview_path)).to eq(:skipped)
      expect(topic.reload.custom_fields["discourse_journals_cover_url"]).to be_nil
    end
  end
end
