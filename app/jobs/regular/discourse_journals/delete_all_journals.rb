# frozen_string_literal: true

module Jobs
  module DiscourseJournals
    class DeleteAllJournals < ::Jobs::Base
      BATCH_SIZE = ::DiscourseJournals::BulkTopicDeleter::BATCH_SIZE

      def execute(args)
        user_id = args[:user_id]
        return unless User.exists?(id: user_id)

        category_id = SiteSetting.discourse_journals_category_id.to_i

        if category_id.zero?
          publish_progress(user_id, 100, 0, 0, 0, "错误：未配置期刊分类", completed: true)
          return
        end

        Rails.logger.warn(
          "[DiscourseJournals::DeleteAll] Starting bulk delete by user #{user_id}, category_id=#{category_id}",
        )

        publish_progress(user_id, 0, 0, 0, 0, "正在清理插件数据...")

        mapping_count = ::DiscourseJournals::MappingAnalysis.count
        ::DiscourseJournals::MappingAnalysis.delete_all
        Rails.logger.info("[DiscourseJournals::DeleteAll] Deleted #{mapping_count} mapping analyses")

        custom_field_count =
          TopicCustomField.where("name LIKE ?", "discourse_journals_%").delete_all
        Rails.logger.info(
          "[DiscourseJournals::DeleteAll] Deleted #{custom_field_count} custom fields",
        )

        publish_progress(user_id, 5, 0, 0, 0, "已清理插件数据，正在统计话题...")

        category = Category.find_by(id: category_id)
        topic_ids = Topic.with_deleted.where(category_id: category_id).pluck(:id)
        topic_ids -= [category.topic_id] if category&.topic_id

        total = topic_ids.size
        deleted_count = 0
        error_count = 0

        if total == 0
          publish_progress(user_id, 100, 0, 0, 0, "清理完成：没有找到话题", completed: true)
          return
        end

        publish_progress(user_id, 10, 0, total, 0, "开始删除 #{total} 个话题...")

        topic_ids.each_slice(BATCH_SIZE).with_index do |batch_ids, batch_idx|
          begin
            count = ::DiscourseJournals::BulkTopicDeleter.delete_batch(batch_ids)
            deleted_count += count
          rescue StandardError => e
            error_count += batch_ids.size
            Rails.logger.error(
              "[DiscourseJournals::DeleteAll] Batch #{batch_idx} failed: #{e.message}",
            )
          end

          processed = [(batch_idx + 1) * BATCH_SIZE, total].min
          progress = 10 + (processed.to_f / total * 85).round
          publish_progress(
            user_id,
            progress,
            deleted_count,
            total,
            error_count,
            "已删除 #{deleted_count}/#{total}...",
          )
        end

        publish_progress(user_id, 95, deleted_count, total, error_count, "正在更新缓存...")
        ::DiscourseJournals::BulkTopicDeleter.update_category_stats(category_id)

        message = "删除完成：已删除 #{deleted_count} 个话题"
        message += "，#{error_count} 个失败" if error_count > 0
        message += "，已清理 #{custom_field_count} 条关联数据"

        publish_progress(user_id, 100, deleted_count, total, error_count, message, completed: true)

        Rails.logger.info(
          "[DiscourseJournals::DeleteAll] Completed: #{deleted_count} topics deleted, #{error_count} errors, #{custom_field_count} custom fields cleaned",
        )
      end

      private

      def publish_progress(user_id, progress, deleted, total, errors, message, completed: false)
        MessageBus.publish(
          "/journals/delete",
          {
            progress: progress,
            deleted: deleted,
            total: total,
            errors: errors,
            message: message,
            completed: completed,
          },
          user_ids: [user_id],
        )
      end
    end
  end
end
