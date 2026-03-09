# frozen_string_literal: true

describe DiscourseJournals::TopicCoverManager do
  before do
    enable_current_plugin
    SiteSetting.discourse_journals_enabled = true
    SiteSetting.discourse_journals_category_id = category.id
    SiteSetting.discourse_journals_download_covers = true

    allow(described_class).to receive(:with_global_slot).and_yield
    allow_any_instance_of(described_class).to receive(:with_topic_lock).and_yield
    allow(Theme).to receive_message_chain(:user_selectable, :pluck).and_return([])
    allow(topic).to receive(:generate_thumbnails!)
  end

  fab!(:category)
  fab!(:topic) do
    create_topic(
      category: category,
      user: Discourse.system_user,
      title: "Journal of Applied Testing",
      raw: "topic content",
    )
  end

  fab!(:upload) { Fabricate(:upload, width: 900, height: 1200, extension: "png") }

  def build_tempfile
    tempfile = Tempfile.new(["journal-cover", ".png"])
    tempfile.write("cover")
    tempfile.rewind
    tempfile
  end

  def stub_upload_creator(upload_record)
    uploader = instance_double(UploadCreator, create_for: upload_record)
    allow(UploadCreator).to receive(:new).and_return(uploader)
  end

  describe ".process!" do
    it "downloads a remote cover and writes topic and first post image ids" do
      tempfile = build_tempfile
      allow(FileHelper).to receive(:download).and_return(tempfile)
      stub_upload_creator(upload)

      result =
        described_class.process!(
          topic: topic,
          cover_url: "/covers/123.png",
          issn: "1234-5678",
          country: "CN",
          publisher: "Testing Press",
        )

      expect(result).to eq(:downloaded)
      expect(topic.reload.image_upload_id).to eq(upload.id)
      expect(topic.first_post.reload.image_upload_id).to eq(upload.id)
      expect(UploadReference.where(upload: upload, target: topic.first_post).exists?).to eq(true)
      expect(topic).to have_received(:generate_thumbnails!).with(extra_sizes: [])

      fingerprint =
        TopicCustomField.where(
          topic_id: topic.id,
          name: described_class::FINGERPRINT_FIELD,
        ).pick(:value)
      expect(fingerprint).to be_present
    end

    it "generates a new academic cover when no remote cover exists" do
      tempfile = build_tempfile
      allow(DiscourseJournals::CoverImageGenerator).to receive(:generate).and_return(tempfile)
      stub_upload_creator(upload)

      result =
        described_class.process!(
          topic: topic,
          cover_url: nil,
          issn: "1234-5678",
          country: "CN",
          publisher: "Testing Press",
        )

      expect(result).to eq(:generated)
      expect(DiscourseJournals::CoverImageGenerator).to have_received(:generate).with(
        title: topic.title,
        issn: "1234-5678",
        country: "CN",
        publisher: "Testing Press",
      )
    end

    it "falls back to a generated cover when remote download fails" do
      tempfile = build_tempfile
      allow(FileHelper).to receive(:download).and_return(nil)
      allow(DiscourseJournals::CoverImageGenerator).to receive(:generate).and_return(tempfile)
      stub_upload_creator(upload)

      result =
        described_class.process!(
          topic: topic,
          cover_url: "/covers/123.png",
          issn: "1234-5678",
          country: "CN",
          publisher: "Testing Press",
        )

      expect(result).to eq(:generated)
      expect(DiscourseJournals::CoverImageGenerator).to have_received(:generate)
    end

    it "treats a stored remote fallback as unchanged on the next pass" do
      topic.update_column(:image_upload_id, upload.id)

      fallback_fingerprint =
        described_class
          .new(
            topic: topic,
            cover_url: "/covers/123.png",
            issn: "1234-5678",
            country: "CN",
            publisher: "Testing Press",
          )
          .send(:build_fingerprint, :remote_fallback)

      TopicCustomField.create!(
        topic_id: topic.id,
        name: described_class::FINGERPRINT_FIELD,
        value: fallback_fingerprint,
      )

      expect(FileHelper).not_to receive(:download)
      expect(DiscourseJournals::CoverImageGenerator).not_to receive(:generate)

      result =
        described_class.process!(
          topic: topic,
          cover_url: "/covers/123.png",
          issn: "1234-5678",
          country: "CN",
          publisher: "Testing Press",
        )

      expect(result).to eq(:unchanged)
    end

    it "skips work when the fingerprint matches and topic image already exists" do
      topic.update_column(:image_upload_id, upload.id)

      fingerprint =
        described_class
          .new(
            topic: topic,
            cover_url: "/covers/123.png",
            issn: "1234-5678",
            country: "CN",
            publisher: "Testing Press",
          )
          .send(:build_fingerprint)

      TopicCustomField.create!(
        topic_id: topic.id,
        name: described_class::FINGERPRINT_FIELD,
        value: fingerprint,
      )

      expect(FileHelper).not_to receive(:download)
      expect(DiscourseJournals::CoverImageGenerator).not_to receive(:generate)

      result =
        described_class.process!(
          topic: topic,
          cover_url: "/covers/123.png",
          issn: "1234-5678",
          country: "CN",
          publisher: "Testing Press",
        )

      expect(result).to eq(:unchanged)
    end
  end
end
