# frozen_string_literal: true

module DiscourseJournals
  class BulkTopicDeleter
    BATCH_SIZE = 200

    def self.delete_batch(topic_ids)
      return 0 if topic_ids.empty?

      existing_ids = DB.query_single("SELECT id FROM topics WHERE id IN (:ids)", ids: topic_ids)
      return 0 if existing_ids.empty?

      post_ids = DB.query_single(
        "SELECT id FROM posts WHERE topic_id IN (:ids)",
        ids: existing_ids,
      )

      Topic.transaction do
        if post_ids.present?
          DB.exec(
            "DELETE FROM post_replies WHERE post_id IN (:ids) OR reply_post_id IN (:ids)",
            ids: post_ids,
          )
          DB.exec("DELETE FROM post_actions WHERE post_id IN (:ids)", ids: post_ids)
          DB.exec("DELETE FROM post_revisions WHERE post_id IN (:ids)", ids: post_ids)
          DB.exec("DELETE FROM post_search_data WHERE post_id IN (:ids)", ids: post_ids)
          DB.exec("DELETE FROM post_custom_fields WHERE post_id IN (:ids)", ids: post_ids)
          DB.exec(
            "DELETE FROM quoted_posts WHERE post_id IN (:ids) OR quoted_post_id IN (:ids)",
            ids: post_ids,
          )
          DB.exec(
            "DELETE FROM upload_references WHERE target_type = 'Post' AND target_id IN (:ids)",
            ids: post_ids,
          )
          DB.exec(
            "DELETE FROM bookmarks WHERE bookmarkable_type = 'Post' AND bookmarkable_id IN (:ids)",
            ids: post_ids,
          )
        end

        DB.exec("DELETE FROM topic_custom_fields WHERE topic_id IN (:ids)", ids: existing_ids)
        DB.exec("DELETE FROM topic_users WHERE topic_id IN (:ids)", ids: existing_ids)
        DB.exec("DELETE FROM topic_links WHERE topic_id IN (:ids)", ids: existing_ids)
        DB.exec("DELETE FROM topic_search_data WHERE topic_id IN (:ids)", ids: existing_ids)
        DB.exec("DELETE FROM topic_timers WHERE topic_id IN (:ids)", ids: existing_ids)
        DB.exec("DELETE FROM topic_tags WHERE topic_id IN (:ids)", ids: existing_ids)
        DB.exec("DELETE FROM notifications WHERE topic_id IN (:ids)", ids: existing_ids)
        DB.exec("DELETE FROM user_actions WHERE target_topic_id IN (:ids)", ids: existing_ids)
        DB.exec(
          "DELETE FROM bookmarks WHERE bookmarkable_type = 'Topic' AND bookmarkable_id IN (:ids)",
          ids: existing_ids,
        )
        DB.exec(
          "DELETE FROM upload_references WHERE target_type = 'Topic' AND target_id IN (:ids)",
          ids: existing_ids,
        )

        DB.exec("DELETE FROM posts WHERE topic_id IN (:ids)", ids: existing_ids)
        DB.exec("DELETE FROM topics WHERE id IN (:ids)", ids: existing_ids)
      end

      existing_ids.size
    end

    def self.update_category_stats(category_id)
      return if category_id.to_i.zero?

      category = Category.find_by(id: category_id)
      return unless category

      Category.update_stats
      category.update_column(
        :topic_count,
        Topic.where(category_id: category_id, visible: true).count,
      )
    rescue StandardError => e
      Rails.logger.warn(
        "[DiscourseJournals::BulkTopicDeleter] Category stats update failed: #{e.message}",
      )
    end
  end
end
