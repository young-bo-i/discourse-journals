# frozen_string_literal: true

module DiscourseJournals
  # Rewrites journal first posts from the JSON already stored on each topic.
  # Run it after a renderer or stylesheet change: it makes no upstream
  # requests and never touches updated_at, so sitemaps and search stay put.
  class CookedRerenderer
    BATCH_SIZE = 500

    Result = Struct.new(:rendered, :skipped, :failed, :last_topic_id, keyword_init: true)

    def initialize(category: nil)
      @category = category || Category.find_by(id: SiteSetting.discourse_journals_category_id.to_i)
      raise Discourse::InvalidParameters.new(:discourse_journals_category_id) if @category.nil?

      # Lets the renderer link ranking values to canonical tag URLs.
      JournalTagManager.warm_caches! if SiteSetting.tagging_enabled
    end

    # Walks the category by topic id so a stopped run can resume from
    # `after_id`. Yields the running result after every batch, then waits
    # `pause` seconds to spread the write load.
    def rerender_all!(after_id: 0, limit: nil, topic_ids: nil, pause: 0)
      result = Result.new(rendered: 0, skipped: 0, failed: 0, last_topic_id: after_id)

      loop do
        ids = next_batch(result.last_topic_id, topic_ids)
        break if ids.empty?

        ids = ids.first(limit - processed(result)) if limit
        rerender_batch!(ids, result)
        result.last_topic_id = ids.last
        yield result if block_given?
        break if limit && processed(result) >= limit
        sleep(pause) if pause.positive?
      end

      result
    end

    private

    def processed(result)
      result.rendered + result.skipped + result.failed
    end

    def next_batch(after_id, topic_ids)
      scope = Topic.where(category_id: @category.id, deleted_at: nil).where("id > ?", after_id)
      scope = scope.where(id: topic_ids) if topic_ids
      scope.order(:id).limit(BATCH_SIZE).pluck(:id)
    end

    def rerender_batch!(ids, result)
      data =
        TopicCustomField
          .where(topic_id: ids, name: "discourse_journals_data")
          .pluck(:topic_id, :value)
          .to_h
      outdated =
        TopicCustomField
          .where(topic_id: ids, name: OutdatedMarker::FIELD)
          .distinct
          .pluck(:topic_id)
          .to_set
      post_ids = Post.where(topic_id: ids, post_number: 1).pluck(:topic_id, :id).to_h

      ids.each do |topic_id|
        json = data[topic_id]
        post_id = post_ids[topic_id]
        if json.blank? || post_id.nil?
          result.skipped += 1
          next
        end

        begin
          normalized = JSON.parse(json).deep_symbolize_keys
          is_outdated = outdated.include?(topic_id)
          html =
            I18n.with_locale(SiteSetting.default_locale) do
              MasterRecordRenderer.new(normalized, category: @category).render(
                outdated: is_outdated,
              )
            end
          if write_cooked(post_id, topic_id, html, json, is_outdated)
            result.rendered += 1
          else
            result.skipped += 1
          end
        rescue StandardError => e
          result.failed += 1
          Rails.logger.warn(
            "[DiscourseJournals::CookedRerenderer] Topic #{topic_id} failed: #{e.class}: #{e.message}",
          )
        end
      end
    end

    # A mapping apply may run at the same time and write newer data and HTML.
    # Write only while the journal data and the outdated flag are still the
    # ones this HTML was rendered from, so a newer page is never replaced.
    def write_cooked(post_id, topic_id, html, json, outdated)
      DB.exec(
        <<~SQL,
          UPDATE posts SET cooked = :html, baked_version = :baked_version
          WHERE id = :post_id
            AND EXISTS (
              SELECT 1 FROM topic_custom_fields
              WHERE topic_id = :topic_id AND name = 'discourse_journals_data' AND md5(value) = :data_md5
            )
            AND EXISTS (
              SELECT 1 FROM topic_custom_fields
              WHERE topic_id = :topic_id AND name = :outdated_field
            ) = :outdated
        SQL
        html: html,
        baked_version: Post::BAKED_VERSION,
        post_id: post_id,
        topic_id: topic_id,
        data_md5: Digest::MD5.hexdigest(json),
        outdated_field: OutdatedMarker::FIELD,
        outdated: outdated,
      ).positive?
    end
  end
end
