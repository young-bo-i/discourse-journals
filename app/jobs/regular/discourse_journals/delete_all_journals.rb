# frozen_string_literal: true

module Jobs
  module DiscourseJournals
    class DeleteAllJournals < ::Jobs::Base
      def execute(args)
        user_id = args[:user_id]
        user = User.find_by(id: user_id)
        return unless user

        Rails.logger.warn("[DiscourseJournals::DeleteAll] Starting bulk delete by user #{user_id}")

        # 查找所有期刊话题
        topic_ids = TopicCustomField
          .where(name: ::DiscourseJournals::CUSTOM_FIELD_ISSN)
          .pluck(:topic_id)
          .uniq

        total = topic_ids.size
        deleted_count = 0
        error_count = 0

        if total == 0
          publish_progress(user_id, 100, 0, 0, 0, "没有找到期刊话题")
          return
        end

        publish_progress(user_id, 0, 0, total, 0, "开始删除 #{total} 个期刊...")

        topic_ids.each_with_index do |topic_id, index|
          begin
            topic = Topic.with_deleted.find_by(id: topic_id)
            if topic
              # 先删除关联的自定义字段
              TopicCustomField.where(topic_id: topic_id).delete_all

              # 永久删除话题
              if topic.first_post
                PostDestroyer.new(user, topic.first_post, force_destroy: true).destroy
              end
              topic.destroy!
              
              deleted_count += 1
            end
          rescue StandardError => e
            error_count += 1
            Rails.logger.error("[DiscourseJournals::DeleteAll] Failed to delete topic #{topic_id}: #{e.message}")
          end

          # 每删除 100 个报告一次进度
          if ((index + 1) % 100).zero? || index == total - 1
            progress = ((index + 1).to_f / total * 100).round
            publish_progress(
              user_id,
              progress,
              deleted_count,
              total,
              error_count,
              "已删除 #{deleted_count}/#{total}..."
            )
          end
        end

        # 更新分类统计
        category_id = SiteSetting.discourse_journals_category_id
        if category_id.present?
          Category.update_stats
          Rails.logger.info("[DiscourseJournals::DeleteAll] Updated category stats")
        end

        # 完成
        message = "删除完成：已删除 #{deleted_count} 个期刊"
        message += "，#{error_count} 个失败" if error_count > 0

        publish_progress(user_id, 100, deleted_count, total, error_count, message, completed: true)

        Rails.logger.info("[DiscourseJournals::DeleteAll] Completed: #{deleted_count} deleted, #{error_count} errors")
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
            completed: completed
          },
          user_ids: [user_id]
        )
      end
    end
  end
end
