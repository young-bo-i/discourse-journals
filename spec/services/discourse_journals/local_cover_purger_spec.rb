# frozen_string_literal: true

describe DiscourseJournals::LocalCoverPurger do
  before { enable_current_plugin }

  fab!(:topic)
  fab!(:first_post) { Fabricate(:post, topic: topic) }
  fab!(:upload)

  def attach_local_cover(target, cover_upload)
    target.update_columns(image_upload_id: cover_upload.id)
    post = target.first_post
    post.update_columns(image_upload_id: cover_upload.id)
    UploadReference.ensure_exist!(upload_ids: [cover_upload.id], target: post)
    target.upsert_custom_fields(described_class::FINGERPRINT_FIELD => "fingerprint")
  end

  describe ".purge!" do
    it "detaches the local cover and deletes its upload once nothing else uses it" do
      attach_local_cover(topic, upload)

      expect(described_class.purge!(topic.reload)).to eq(true)

      expect(topic.reload.image_upload_id).to be_nil
      expect(first_post.reload.image_upload_id).to be_nil
      expect(Upload.exists?(upload.id)).to eq(false)
      expect(UploadReference.where(upload_id: upload.id)).to be_empty
      expect(topic.custom_fields[described_class::FINGERPRINT_FIELD]).to be_nil
    end

    it "keeps an upload that another topic still uses as its cover" do
      other_topic = Fabricate(:topic)
      Fabricate(:post, topic: other_topic)
      attach_local_cover(topic, upload)
      attach_local_cover(other_topic, upload)

      described_class.purge!(topic.reload)

      expect(topic.reload.image_upload_id).to be_nil
      expect(other_topic.reload.image_upload_id).to eq(upload.id)
      expect(Upload.exists?(upload.id)).to eq(true)
    end

    it "returns false when the topic has no local cover" do
      expect(described_class.purge!(topic)).to eq(false)
    end
  end

  describe ".clear_legacy!" do
    it "clears ids of uploads that no longer exist and old fingerprints, keeping real covers" do
      attach_local_cover(topic, upload)
      dangling_topic = Fabricate(:topic)
      dangling_post = Fabricate(:post, topic: dangling_topic)
      missing_upload_id = Upload.maximum(:id) + 1000
      dangling_topic.update_columns(image_upload_id: missing_upload_id)
      dangling_post.update_columns(image_upload_id: missing_upload_id)

      result = described_class.clear_legacy!([topic.id, dangling_topic.id])

      expect(result).to eq(dangling: 1, fingerprints: 1)
      expect(dangling_topic.reload.image_upload_id).to be_nil
      expect(dangling_post.reload.image_upload_id).to be_nil
      expect(topic.reload.image_upload_id).to eq(upload.id)
      expect(TopicCustomField.where(name: described_class::FINGERPRINT_FIELD)).to be_empty
    end
  end
end
