# frozen_string_literal: true

# name: discourse-journals
# about: 期刊统一档案系统 - JSON 导入管理
# version: 0.8
# authors: enterscholar

enabled_site_setting :discourse_journals_enabled

register_asset "stylesheets/common/discourse-journals.scss"
register_asset "stylesheets/common/discourse-journals-admin.scss"

module ::DiscourseJournals
  PLUGIN_NAME = "discourse-journals"

  CUSTOM_FIELD_ISSN = "discourse_journals_issn"
  CUSTOM_FIELD_NAME = "discourse_journals_name"
  CUSTOM_FIELD_UNIFIED_INDEX = "discourse_journals_unified_index"
  CUSTOM_FIELD_ALIASES = "discourse_journals_aliases"
  CUSTOM_FIELD_CROSSREF = "discourse_journals_crossref"
  CUSTOM_FIELD_DOAJ = "discourse_journals_doaj"
  CUSTOM_FIELD_NLM = "discourse_journals_nlm"
  CUSTOM_FIELD_OPENALEX = "discourse_journals_openalex"
  CUSTOM_FIELD_WIKIDATA = "discourse_journals_wikidata"
end

require_relative "lib/discourse_journals/engine"

# 注册管理员路由（在 Plugins 菜单中显示）
add_admin_route "discourse_journals.title", "discourse-journals"

after_initialize do
  require_relative "app/models/discourse_journals/import_log"
  require_relative "app/services/discourse_journals/field_normalizer"
  require_relative "app/services/discourse_journals/field_usage_tracker"
  require_relative "app/services/discourse_journals/master_record_renderer"
  require_relative "app/services/discourse_journals/api_sync/client"
  require_relative "app/services/discourse_journals/api_sync/importer"
  require_relative "app/services/discourse_journals/journal_upserter"
  require_relative "app/jobs/regular/discourse_journals/sync_from_api"

  # 注册自定义字段
  Topic.register_custom_field_type("journal_issn_l", :string)

  # 使用 register_modifier 来修改标题内容（这是 Discourse 官方推荐的方法）
  register_modifier(:meta_data_content) do |content, type, context|
    # 只修改 title 类型的元数据
    next content unless type == :title
    next content unless SiteSetting.discourse_journals_enabled
    next content if SiteSetting.discourse_journals_title_suffix.blank?
    
    # 获取当前请求的上下文
    request_path = context[:url]
    next content unless request_path&.start_with?("/t/")
    
    # 尝试从请求中获取话题信息
    # 这个方法在服务器端渲染时有效
    begin
      # 从 request_path 解析话题 ID
      # 路径格式: /t/topic-slug/123
      topic_id = request_path.match(%r{/t/[^/]+/(\d+)}i)&.captures&.first
      next content unless topic_id
      
      topic = Topic.find_by(id: topic_id)
      next content unless topic
      
      category_id = SiteSetting.discourse_journals_category_id
      next content if category_id.blank?
      
      # 检查是否是期刊分类的话题
      if topic.category_id == category_id.to_i
        suffix = SiteSetting.discourse_journals_title_suffix
        
        # 避免重复添加后缀
        next content if content.include?(suffix)
        
        # 返回修改后的标题
        "#{content} - #{suffix}"
      else
        content
      end
    rescue StandardError => e
      Rails.logger.warn("[DiscourseJournals] Failed to modify title: #{e.message}")
      content
    end
  end

  # 注册 API 路由
  Discourse::Application.routes.append do
    # API 同步
    post "/admin/journals/sync" => "discourse_journals/admin_sync#create",
         :constraints => AdminConstraint.new
    post "/admin/journals/sync/test" => "discourse_journals/admin_sync#test_connection",
         :constraints => AdminConstraint.new
    post "/admin/journals/sync/pause" => "discourse_journals/admin_sync#pause",
         :constraints => AdminConstraint.new
    post "/admin/journals/sync/resume" => "discourse_journals/admin_sync#resume",
         :constraints => AdminConstraint.new
    post "/admin/journals/sync/cancel" => "discourse_journals/admin_sync#cancel",
         :constraints => AdminConstraint.new
    get "/admin/journals/sync/status" => "discourse_journals/admin_sync#status",
        :constraints => AdminConstraint.new
    
    # 删除所有期刊
    delete "/admin/journals/delete_all" => "discourse_journals/admin_sync#delete_all",
           :constraints => AdminConstraint.new
    
    # 导入日志查询
    get "/admin/journals/imports/:id/status" => "discourse_journals/admin_imports#status",
        :constraints => AdminConstraint.new
  end
end
