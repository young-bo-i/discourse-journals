# frozen_string_literal: true

module DiscourseJournals
  # Points one journal topic at an upstream cover path (or clears it) without a
  # full re-sync: rewrites the cover inside discourse_journals_data, re-renders
  # the first post from that JSON and mirrors the absolute URL into the cover
  # custom field read by suggestions and og:image.
  class TopicCoverApplier
    DATA_FIELD = "discourse_journals_data"
    COVER_FIELD = "discourse_journals_cover_url"

    def self.apply!(topic, path)
      new(topic).apply!(path)
    end

    def initialize(topic)
      @topic = topic
    end

    # Returns :updated, :cleared, :unchanged, or :skipped when the topic has no
    # stored journal data to render from.
    def apply!(path)
      path = path.presence
      data_field = TopicCustomField.find_by(topic_id: @topic.id, name: DATA_FIELD)
      return :skipped if data_field&.value.blank?

      normalized = JSON.parse(data_field.value).deep_symbolize_keys
      identity = (normalized[:identity] ||= {})
      url = CoverUrl.absolute(path)
      stored_url = TopicCustomField.where(topic_id: @topic.id, name: COVER_FIELD).pick(:value)

      if identity[:cover_url] == path && identity[:cover_original_url].nil? && stored_url == url
        return :unchanged
      end

      # Same keys, new values: FieldNormalizer emits this shape, so a later full
      # sync of the same cover does not see a spurious content change.
      identity[:cover_url] = path
      identity[:cover_original_url] = nil
      now = Time.current

      Topic.transaction do
        data_field.update_columns(value: normalized.to_json, updated_at: now)
        write_cover_field(url, now)
        rerender_first_post(normalized, now)
        @topic.update_columns(updated_at: now)
      end

      path ? :updated : :cleared
    end

    private

    def write_cover_field(url, now)
      TopicCustomField.where(topic_id: @topic.id, name: COVER_FIELD).delete_all
      return if url.blank?

      TopicCustomField.create!(
        topic_id: @topic.id,
        name: COVER_FIELD,
        value: url,
        created_at: now,
        updated_at: now,
      )
    end

    def rerender_first_post(normalized, now)
      post = Post.find_by(topic_id: @topic.id, post_number: 1)
      return if post.nil?

      cooked =
        I18n.with_locale(SiteSetting.default_locale) do
          MasterRecordRenderer.new(normalized).render(outdated: OutdatedMarker.outdated?(@topic))
        end
      post.update_columns(cooked: cooked, baked_version: Post::BAKED_VERSION, updated_at: now)
    end
  end
end
