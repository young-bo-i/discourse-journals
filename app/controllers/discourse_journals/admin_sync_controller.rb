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

      # 创建导入日志（包含 api_url 和 filters，以支持恢复）
      import_log = ImportLog.create!(
        upload_id: 0, # API 同步不需要 upload
        user_id: current_user.id,
        status: :pending,
        started_at: Time.current,
        api_url: api_url,
        filters: filters,
        import_mode: mode
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
    # 删除所有期刊话题（后台任务）
    def delete_all
      category_id = SiteSetting.discourse_journals_category_id

      if category_id.blank?
        return render_json_error("请先在设置中配置期刊分类")
      end

      # 查找所有期刊话题数量（兼容新旧字段名）
      topic_count = TopicCustomField
        .where(name: [DiscourseJournals::CUSTOM_FIELD_PRIMARY_ID, DiscourseJournals::CUSTOM_FIELD_ISSN])
        .distinct
        .count(:topic_id)

      if topic_count == 0
        return render_json_dump({ success: true, total: 0, message: "没有找到期刊话题" })
      end

      Rails.logger.warn("[DiscourseJournals::DeleteAll] User #{current_user.id} queued deletion of #{topic_count} journal topics")

      # 后台任务执行删除
      Jobs.enqueue(
        Jobs::DiscourseJournals::DeleteAllJournals,
        user_id: current_user.id
      )

      render_json_dump({
        success: true,
        total: topic_count,
        message: "已开始后台删除 #{topic_count} 个期刊，请勿关闭页面..."
      })
    rescue StandardError => e
      Rails.logger.error("[DiscourseJournals::DeleteAll] Fatal error: #{e.message}\n#{e.backtrace.join("\n")}")
      render_json_error("删除失败: #{e.message}")
    end

    # POST /admin/journals/sync/pause
    # 暂停导入
    def pause
      import_log_id = params[:import_log_id]
      
      if import_log_id.blank?
        return render_json_error("缺少 import_log_id")
      end

      import_log = ImportLog.find_by(id: import_log_id)
      
      if import_log.nil?
        return render_json_error("找不到导入任务")
      end

      unless import_log.processing?
        return render_json_error("只能暂停正在进行的导入任务")
      end

      # 设置暂停状态（Job 会在下次检查时停止）
      import_log.pause!

      Rails.logger.info("[DiscourseJournals::Sync] Pause requested for import_log #{import_log_id}")

      render_json_dump({
        success: true,
        import_log_id: import_log.id,
        status: import_log.status,
        message: "正在暂停导入..."
      })
    rescue StandardError => e
      Rails.logger.error("[DiscourseJournals::Sync] Pause failed: #{e.message}")
      render_json_error("暂停失败: #{e.message}")
    end

    # POST /admin/journals/sync/cancel
    # 取消导入（清除断点数据）
    def cancel
      import_log_id = params[:import_log_id]
      
      if import_log_id.blank?
        return render_json_error("缺少 import_log_id")
      end

      import_log = ImportLog.find_by(id: import_log_id)
      
      if import_log.nil?
        return render_json_error("找不到导入任务")
      end

      if import_log.completed? || import_log.cancelled?
        return render_json_error("该任务已结束，无法取消")
      end

      # 记录取消前的状态
      was_paused = import_log.paused?

      # 取消任务（清除断点数据）
      import_log.cancel!

      Rails.logger.info("[DiscourseJournals::Sync] Cancel requested for import_log #{import_log_id}")

      # 如果任务已暂停（没有后台 Job 在运行），需要直接发送 MessageBus 消息通知前端
      if was_paused
        MessageBus.publish(
          "/journals/import/#{import_log.id}",
          {
            import_log_id: import_log.id,
            status: "cancelled",
            progress: import_log.progress_percent,
            processed: import_log.processed_records,
            total: import_log.total_records,
            created: import_log.created_count,
            updated: import_log.updated_count,
            skipped: import_log.skipped_count,
            errors: import_log.error_count,
            message: "任务已取消"
          },
          user_ids: [current_user.id]
        )
      end

      render_json_dump({
        success: true,
        import_log_id: import_log.id,
        status: import_log.status,
        message: "任务已取消"
      })
    rescue StandardError => e
      Rails.logger.error("[DiscourseJournals::Sync] Cancel failed: #{e.message}")
      render_json_error("取消失败: #{e.message}")
    end

    # POST /admin/journals/sync/resume
    # 恢复导入
    def resume
      import_log_id = params[:import_log_id]
      
      if import_log_id.blank?
        return render_json_error("缺少 import_log_id")
      end

      import_log = ImportLog.find_by(id: import_log_id)
      
      if import_log.nil?
        return render_json_error("找不到导入任务")
      end

      unless import_log.resumable?
        return render_json_error("该任务不可恢复，状态: #{import_log.status}")
      end

      # 检查 api_url 是否有效
      api_url = import_log.api_url.presence || SiteSetting.discourse_journals_api_url
      if api_url.blank?
        return render_json_error("无法恢复：缺少 API URL，请检查插件设置")
      end

      # 如果 import_log 中没有保存 api_url，更新它
      if import_log.api_url.blank?
        import_log.update!(api_url: api_url)
      end

      # 标记为处理中（Job 会从断点继续）
      import_log.resume!

      Rails.logger.info("[DiscourseJournals::Sync] Resume requested for import_log #{import_log_id}, starting from page #{import_log.resume_from_page}, api_url=#{api_url}")

      # 重新排队任务
      Jobs.enqueue(
        Jobs::DiscourseJournals::SyncFromApi,
        import_log_id: import_log.id,
        user_id: current_user.id,
        resume: true
      )

      render_json_dump({
        success: true,
        import_log_id: import_log.id,
        status: import_log.status,
        resume_from_page: import_log.resume_from_page,
        processed_records: import_log.processed_records,
        message: "正在从第 #{import_log.resume_from_page} 页恢复导入..."
      })
    rescue StandardError => e
      Rails.logger.error("[DiscourseJournals::Sync] Resume failed: #{e.message}")
      render_json_error("恢复失败: #{e.message}")
    end

    # GET /admin/journals/sync/status
    # 获取当前导入状态
    def status
      # 获取最近的导入任务
      import_log = ImportLog.order(created_at: :desc).first
      
      if import_log.nil?
        return render_json_dump({ 
          has_active: false, 
          has_resumable: false,
          has_incomplete: false 
        })
      end

      render_json_dump({
        has_active: ImportLog.active.exists?,
        has_resumable: ImportLog.resumable.exists?,
        has_incomplete: ImportLog.incomplete.exists?,
        current: {
          id: import_log.id,
          status: import_log.status,
          progress: import_log.progress_percent,
          processed: import_log.processed_records,
          total: import_log.total_records,
          created: import_log.created_count,
          updated: import_log.updated_count,
          skipped: import_log.skipped_count,
          errors: import_log.error_count,
          current_page: import_log.current_page,
          resumable: import_log.resumable?,
          cancellable: !import_log.completed? && !import_log.cancelled?,
          message: import_log.result_message
        }
      })
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
