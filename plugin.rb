# frozen_string_literal: true

# name: discourse-journals
# about: 期刊统一档案系统 - 映射分析与同步
# version: 1.0
# authors: enterscholar

enabled_site_setting :discourse_journals_enabled

register_asset "stylesheets/common/discourse-journals.scss"
register_asset "stylesheets/common/discourse-journals-admin.scss"

module ::DiscourseJournals
  PLUGIN_NAME = "discourse-journals"

  # 话题关联字段（唯一，用于与外部 API 关联）
  CUSTOM_FIELD_PRIMARY_ID = "discourse_journals_primary_id"

  # 兼容旧版（查找时使用）
  CUSTOM_FIELD_ISSN = "discourse_journals_issn"
end

require_relative "lib/discourse_journals/engine"

# 注册管理员路由（在 Plugins 菜单中显示）
add_admin_route "discourse_journals.title", "discourse-journals"

after_initialize do
  require_relative "app/models/discourse_journals/mapping_analysis"
  require_relative "app/services/discourse_journals/field_normalizer"
  require_relative "app/services/discourse_journals/field_usage_tracker"
  require_relative "app/services/discourse_journals/master_record_renderer"
  require_relative "app/services/discourse_journals/journal_upserter"
  require_relative "app/services/discourse_journals/title_matcher"
  require_relative "app/services/discourse_journals/api_data_transformer"
  require_relative "app/services/discourse_journals/mapping_applier"
  require_relative "app/jobs/regular/discourse_journals/analyze_mapping"
  require_relative "app/jobs/regular/discourse_journals/apply_mapping"
  require_relative "app/jobs/regular/discourse_journals/delete_all_journals"

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

  Discourse::Application.routes.append do
    # 映射分析
    post "/admin/journals/mapping/analyze" => "discourse_journals/admin_mapping#analyze",
         :constraints => AdminConstraint.new
    post "/admin/journals/mapping/pause" => "discourse_journals/admin_mapping#pause",
         :constraints => AdminConstraint.new
    post "/admin/journals/mapping/restart" => "discourse_journals/admin_mapping#restart",
         :constraints => AdminConstraint.new
    get "/admin/journals/mapping/status" => "discourse_journals/admin_mapping#status",
        :constraints => AdminConstraint.new
    get "/admin/journals/mapping/details" => "discourse_journals/admin_mapping#details",
        :constraints => AdminConstraint.new

    # 映射应用
    post "/admin/journals/mapping/apply" => "discourse_journals/admin_mapping#apply",
         :constraints => AdminConstraint.new
    get "/admin/journals/mapping/apply_status" => "discourse_journals/admin_mapping#apply_status",
        :constraints => AdminConstraint.new
    post "/admin/journals/mapping/apply_pause" => "discourse_journals/admin_mapping#apply_pause",
         :constraints => AdminConstraint.new
    post "/admin/journals/mapping/apply_resume" => "discourse_journals/admin_mapping#apply_resume",
         :constraints => AdminConstraint.new
    post "/admin/journals/mapping/apply_reset" => "discourse_journals/admin_mapping#apply_reset",
         :constraints => AdminConstraint.new

    # 管理操作
    delete "/admin/journals/delete_all" => "discourse_journals/admin_mapping#delete_all",
           :constraints => AdminConstraint.new
  end
end
