# frozen_string_literal: true

module DiscourseJournals
  class AdminSyncController < ::Admin::AdminController
    requires_plugin DiscourseJournals::PLUGIN_NAME

    # POST /admin/journals/sync
    # 触发同步（第一页或全部）
    def create
      mode = params[:mode] # "first_page" 或 "all_pages"
      api_url = params[:api_url].presence || SiteSetting.discourse_journals_api_url
      
      # 提取并清理 filters 参数
      filters = extract_filters

      if api_url.blank?
        return render_json_error("请在设置中配置 API URL")
      end

      unless %w[first_page all_pages].include?(mode)
        return render_json_error("无效的模式，必须是 first_page 或 all_pages")
      end

      Rails.logger.info("[DiscourseJournals::Sync] Starting sync: mode=#{mode}, api_url=#{api_url}, filters=#{filters}")

      # 创建导入日志
      import_log = ImportLog.create!(
        upload_id: 0, # API 同步不需要 upload
        user_id: current_user.id,
        status: :pending,
        started_at: Time.current
      )

      # 后台任务
      Jobs.enqueue(
        Jobs::DiscourseJournals::SyncFromApi,
        import_log_id: import_log.id,
        user_id: current_user.id,
        api_url: api_url,
        mode: mode,
        filters: filters
      )

      filter_desc = build_filter_description(filters)
      message = mode == "first_page" ? "开始导入第一页数据..." : "开始导入所有数据..."
      message += filter_desc if filter_desc.present?

      render_json_dump(
        {
          status: "started",
          import_log_id: import_log.id,
          mode: mode,
          message: message
        }
      )
    rescue StandardError => e
      Rails.logger.error("[DiscourseJournals::Sync] Failed to start: #{e.message}\n#{e.backtrace.join("\n")}")
      render_json_error("启动同步失败: #{e.message}")
    end

    # DELETE /admin/journals/delete_all
    # 删除所有期刊话题（真删除）
    def delete_all
      category_id = SiteSetting.discourse_journals_category_id

      if category_id.blank?
        return render_json_error("请先在设置中配置期刊分类")
      end

      # 查找所有期刊话题（通过自定义字段）
      topic_ids = TopicCustomField
        .where(name: DiscourseJournals::CUSTOM_FIELD_ISSN)
        .pluck(:topic_id)
        .uniq

      if topic_ids.empty?
        return render_json_dump({ success: true, deleted: 0, message: "没有找到期刊话题" })
      end

      Rails.logger.warn("[DiscourseJournals::DeleteAll] User #{current_user.id} is deleting #{topic_ids.count} journal topics")

      deleted_count = 0
      errors = []

      topic_ids.each do |topic_id|
        begin
          topic = Topic.with_deleted.find_by(id: topic_id)
          next unless topic

          # 先删除关联的自定义字段
          TopicCustomField.where(topic_id: topic_id).delete_all

          # 永久删除话题（包括所有帖子）
          PostDestroyer.new(current_user, topic.first_post, force_destroy: true).destroy if topic.first_post
          topic.destroy!
          
          deleted_count += 1
        rescue StandardError => e
          errors << "Topic #{topic_id}: #{e.message}"
          Rails.logger.error("[DiscourseJournals::DeleteAll] Failed to delete topic #{topic_id}: #{e.message}")
        end
      end

      message = "已删除 #{deleted_count} 个期刊话题"
      message += "，#{errors.count} 个删除失败" if errors.any?

      Rails.logger.info("[DiscourseJournals::DeleteAll] Deleted #{deleted_count} topics, #{errors.count} errors")

      render_json_dump({
        success: true,
        deleted: deleted_count,
        errors: errors.first(10),
        message: message
      })
    rescue StandardError => e
      Rails.logger.error("[DiscourseJournals::DeleteAll] Fatal error: #{e.message}\n#{e.backtrace.join("\n")}")
      render_json_error("删除失败: #{e.message}")
    end

    # POST /admin/journals/sync/test
    # 测试 API 连接
    def test_connection
      api_url = params[:api_url].presence || SiteSetting.discourse_journals_api_url

      if api_url.blank?
        return render_json_error("请提供 API URL")
      end

      client = ApiSync::Client.new(api_url)
      result = client.fetch_page(page: 1, page_size: 1)

      render_json_dump(
        {
          success: true,
          total: result.dig(:pagination, "total"),
          total_pages: result.dig(:pagination, "totalPages"),
          message: "API 连接成功！共 #{result.dig(:pagination, 'total')} 个期刊"
        }
      )
    rescue StandardError => e
      Rails.logger.error("[DiscourseJournals::Sync] Test failed: #{e.message}")
      render_json_error("API 连接失败: #{e.message}")
    end

    private

    def extract_filters
      filters = {}
      
      if params[:filters].present?
        filter_params = params[:filters]
        
        # 提取每个筛选条件
        filters[:q] = filter_params[:q] if filter_params[:q].present?
        filters[:in_doaj] = filter_params[:in_doaj] if filter_params[:in_doaj].present?
        filters[:in_nlm] = filter_params[:in_nlm] if filter_params[:in_nlm].present?
        filters[:has_wikidata] = filter_params[:has_wikidata] if filter_params[:has_wikidata].present?
        filters[:is_open_access] = filter_params[:is_open_access] if filter_params[:is_open_access].present?
        filters[:sort_by] = filter_params[:sort_by] if filter_params[:sort_by].present?
        filters[:sort_order] = filter_params[:sort_order] if filter_params[:sort_order].present?
      end
      
      filters
    end

    def build_filter_description(filters)
      return "" if filters.blank?

      parts = []
      parts << "关键词: #{filters[:q]}" if filters[:q].present?
      parts << "DOAJ期刊" if filters[:in_doaj] == true || filters[:in_doaj] == "true"
      parts << "非DOAJ期刊" if filters[:in_doaj] == false || filters[:in_doaj] == "false"
      parts << "NLM期刊" if filters[:in_nlm] == true || filters[:in_nlm] == "true"
      parts << "非NLM期刊" if filters[:in_nlm] == false || filters[:in_nlm] == "false"
      parts << "有Wikidata" if filters[:has_wikidata] == true || filters[:has_wikidata] == "true"
      parts << "开放获取" if filters[:is_open_access] == true || filters[:is_open_access] == "true"
      parts << "非开放获取" if filters[:is_open_access] == false || filters[:is_open_access] == "false"

      parts.any? ? "（筛选：#{parts.join('、')}）" : ""
    end
  end
end
