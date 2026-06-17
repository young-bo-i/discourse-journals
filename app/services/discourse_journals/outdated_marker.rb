# frozen_string_literal: true

module DiscourseJournals
  # Soft-delete for forum-only journals: instead of hard-deleting a topic whose
  # journal is gone from the API (which would 404 and lose its SEO), mark it
  # "outdated" — keep the topic, render an outdated banner at the top, and close
  # it. The banner is rendered FROM this flag (never appended), so re-rendering
  # can't duplicate it; and TitleMatcher drops outdated topics from the title
  # index so they are not re-flagged on the next sync. If the journal later
  # returns to the API it is matched by ISSN/api_id and the update path clears
  # the flag (revival).
  class OutdatedMarker
    FIELD = "discourse_journals_outdated"

    def self.mark_batch(topic_ids)
      marked = 0
      Topic.where(id: topic_ids).find_each { |topic| marked += 1 if mark!(topic) }
      marked
    end

    def self.mark!(topic)
      return false if outdated?(topic)

      # Flag first, inside a transaction: if the re-render or close fails, the flag
      # is rolled back too — so we never leave a banner persisted without the flag
      # (which would let the topic be re-flagged and stack banners next sync).
      Topic.transaction do
        TopicCustomField.create!(topic_id: topic.id, name: FIELD, value: Time.current.iso8601)
        post = topic.first_post
        rerender_post(post) if post
        topic.update_columns(closed: true) unless topic.closed?
      end
      true
    rescue StandardError => e
      Rails.logger.warn("[DiscourseJournals::OutdatedMarker] Failed for topic #{topic.id}: #{e.message}")
      false
    end

    def self.outdated?(topic)
      TopicCustomField.exists?(topic_id: topic.id, name: FIELD)
    end

    def self.rerender_post(post)
      data_json =
        TopicCustomField.where(topic_id: post.topic_id, name: "discourse_journals_data").pick(:value)

      cooked =
        if data_json.present?
          normalized = JSON.parse(data_json).deep_symbolize_keys
          I18n.with_locale(SiteSetting.default_locale) do
            MasterRecordRenderer.new(normalized).render(outdated: true)
          end
        else
          # No stored journal data to re-render — prepend a standalone banner, but
          # never stack: skip if one is already present.
          return if post.cooked.to_s.include?("dj-outdated-notice")

          notice =
            I18n.with_locale(SiteSetting.default_locale) do
              ERB::Util.html_escape(I18n.t("discourse_journals.render.outdated_notice"))
            end
          %(<div class="dj-outdated-notice" role="alert"><span class="dj-outdated-notice__text">#{notice}</span></div>\n#{post.cooked})
        end

      post.update_columns(cooked: cooked, baked_version: Post::BAKED_VERSION)
    end

    private_class_method :rerender_post
  end
end
