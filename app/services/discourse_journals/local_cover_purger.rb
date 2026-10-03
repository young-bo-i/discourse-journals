# frozen_string_literal: true

module DiscourseJournals
  # Removes the local cover images the retired cover subsystem attached to
  # journal topics: topics.image_upload_id, the first post's image_upload_id and
  # its upload reference, plus that subsystem's fingerprint custom field.
  class LocalCoverPurger
    FINGERPRINT_FIELD = "discourse_journals_cover_url_hash"

    # Leftovers that are garbage whatever upstream says. Core's orphan-upload
    # sweep only looks at upload_references, so it deleted many cover uploads
    # while topics.image_upload_id kept pointing at them.
    def self.clear_legacy!(topic_ids)
      return { dangling: 0, fingerprints: 0 } if topic_ids.blank?

      dangling = DB.exec(<<~SQL, topic_ids: topic_ids)
        UPDATE topics t
        SET image_upload_id = NULL
        WHERE t.id IN (:topic_ids)
          AND t.image_upload_id IS NOT NULL
          AND NOT EXISTS (SELECT 1 FROM uploads u WHERE u.id = t.image_upload_id)
      SQL

      DB.exec(<<~SQL, topic_ids: topic_ids)
        UPDATE posts p
        SET image_upload_id = NULL
        WHERE p.topic_id IN (:topic_ids)
          AND p.post_number = 1
          AND p.image_upload_id IS NOT NULL
          AND NOT EXISTS (SELECT 1 FROM uploads u WHERE u.id = p.image_upload_id)
      SQL

      fingerprints = TopicCustomField.where(topic_id: topic_ids, name: FINGERPRINT_FIELD).delete_all

      { dangling: dangling, fingerprints: fingerprints }
    end

    # Detaches the local cover once an upstream cover replaces it. Returns true
    # when a local cover was attached.
    def self.purge!(topic)
      TopicCustomField.where(topic_id: topic.id, name: FINGERPRINT_FIELD).delete_all

      upload_id = topic.image_upload_id
      return false if upload_id.nil?

      first_post_id = Post.where(topic_id: topic.id, post_number: 1).pick(:id)

      Topic.transaction do
        topic.update_columns(image_upload_id: nil)
        if first_post_id
          Post.where(id: first_post_id, image_upload_id: upload_id).update_all(image_upload_id: nil)
          UploadReference.where(
            upload_id: upload_id,
            target_type: "Post",
            target_id: first_post_id,
          ).delete_all
        end
      end

      destroy_if_unreferenced(upload_id)
      true
    end

    # Identical generated covers were de-duplicated by sha1, so one upload can
    # back several topics; it only goes once the last of them lets go.
    def self.destroy_if_unreferenced(upload_id)
      return if UploadReference.exists?(upload_id: upload_id)
      return if Topic.exists?(image_upload_id: upload_id)
      return if Post.exists?(image_upload_id: upload_id)

      upload = Upload.find_by(id: upload_id)
      return if upload.nil?

      TopicThumbnail.where(upload_id: upload_id).delete_all
      upload.destroy
    end
    private_class_method :destroy_if_unreferenced
  end
end
