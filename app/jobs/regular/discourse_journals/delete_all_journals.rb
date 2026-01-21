# frozen_string_literal: true

module Jobs
  module DiscourseJournals
    class DeleteAllJournals < ::Jobs::Base
      def execute(args)
        user_id = args[:user_id]
        user = User.find_by(id: user_id)
        return unless user

        category_id = SiteSetting.discourse_journals_category_id.to_i
        
        if category_id.zero?
          publish_progress(user_id, 100, 0, 0, 0, "错误：未配置期刊分类", completed: true)
          return
        end

        Rails.logger.warn("[DiscourseJournals::DeleteAll] Starting bulk delete by user #{user_id}, category_id=#{category_id}")

        # ============ 第一步：删除插件产生的中间数据 ============
        publish_progress(user_id, 0, 0, 0, 0, "正在清理插件数据...")

        # 1.1 删除导入日志
        import_log_count = ::DiscourseJournals::ImportLog.count
        ::DiscourseJournals::ImportLog.delete_all
        Rails.logger.info("[DiscourseJournals::DeleteAll] Deleted #{import_log_count} import logs")

        # 1.2 删除所有期刊相关的 TopicCustomField（以 discourse_journals_ 开头的）
        custom_field_count = TopicCustomField
          .where("name LIKE ?", "discourse_journals_%")
          .delete_all
        Rails.logger.info("[DiscourseJournals::DeleteAll] Deleted #{custom_field_count} custom fields")

        publish_progress(user_id, 5, 0, 0, 0, "已清理插件数据，正在统计话题...")

        # ============ 第二步：删除分类下的所有话题 ============
        
        # 获取分类下所有话题（包括已删除的）
        topic_ids = Topic.with_deleted.where(category_id: category_id).pluck(:id)
        total = topic_ids.size
        deleted_count = 0
        error_count = 0

        if total == 0
          publish_progress(user_id, 100, 0, 0, 0, "清理完成：没有找到话题", completed: true)
          return
        end

        publish_progress(user_id, 10, 0, total, 0, "开始删除 #{total} 个话题...")

        topic_ids.each_with_index do |topic_id, index|
          begin
            topic = Topic.with_deleted.find_by(id: topic_id)
            next unless topic

            # 使用 PostDestroyer 正确删除话题（会处理缓存、通知等）
            first_post = topic.first_post
            if first_post
              # force_destroy: true 会永久删除，不进回收站
              PostDestroyer.new(user, first_post, force_destroy: true).destroy
            else
              # 如果没有 first_post，直接删除话题
              topic.destroy!
            end
            
            deleted_count += 1
          rescue StandardError => e
            error_count += 1
            Rails.logger.error("[DiscourseJournals::DeleteAll] Failed to delete topic #{topic_id}: #{e.message}")
          end

          # 每删除 50 个报告一次进度
          if ((index + 1) % 50).zero? || index == total - 1
            # 进度从 10% 到 95%
            progress = 10 + ((index + 1).to_f / total * 85).round
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

        # ============ 第三步：更新缓存和统计 ============
        publish_progress(user_id, 95, deleted_count, total, error_count, "正在更新缓存...")

        # 更新分类统计
        category = Category.find_by(id: category_id)
        if category
          Category.update_stats
          # 重新计算分类的话题数
          category.update_column(:topic_count, 
            Topic.where(category_id: category_id).where(visible: true).count
          )
        end

        # 清理搜索索引中的孤立数据
        begin
          # 触发搜索索引重建（可选，比较耗时）
          # SearchIndexer.rebuild_posts
          Rails.logger.info("[DiscourseJournals::DeleteAll] Category stats updated")
        rescue StandardError => e
          Rails.logger.warn("[DiscourseJournals::DeleteAll] Failed to update search index: #{e.message}")
        end

        # ============ 完成 ============
        message = "删除完成：已删除 #{deleted_count} 个话题"
        message += "，#{error_count} 个失败" if error_count > 0
        message += "，已清理 #{custom_field_count} 条关联数据"

        publish_progress(user_id, 100, deleted_count, total, error_count, message, completed: true)

        Rails.logger.info("[DiscourseJournals::DeleteAll] Completed: #{deleted_count} topics deleted, #{error_count} errors, #{custom_field_count} custom fields cleaned")
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
