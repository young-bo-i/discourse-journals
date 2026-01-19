# frozen_string_literal: true

module DiscourseJournals
  class AdminSyncController < ::Admin::AdminController
    requires_plugin DiscourseJournals::PLUGIN_NAME

    # POST /admin/journals/sync
    # 触发同步（第一页或全部）
    def create
      mode = params[:mode] # "first_page" 或 "all_pages"
      api_url = params[:api_url].presence || SiteSetting.discourse_journals_api_url

      if api_url.blank?
        return render_json_error("请在设置中配置 API URL")
      end

      unless %w[first_page all_pages].include?(mode)
        return render_json_error("无效的模式，必须是 first_page 或 all_pages")
      end

      Rails.logger.info("[DiscourseJournals::Sync] Starting sync: mode=#{mode}, api_url=#{api_url}")

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
        mode: mode
      )

      render_json_dump(
        {
          status: "started",
          import_log_id: import_log.id,
          mode: mode,
          message: mode == "first_page" ? "开始导入第一页数据..." : "开始导入所有数据..."
        }
      )
    rescue StandardError => e
      Rails.logger.error("[DiscourseJournals::Sync] Failed to start: #{e.message}\n#{e.backtrace.join("\n")}")
      render_json_error("启动同步失败: #{e.message}")
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
  end
end
