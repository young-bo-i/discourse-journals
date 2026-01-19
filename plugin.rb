# frozen_string_literal: true

# name: discourse-journals
# about: 期刊统一档案系统 - JSON 导入管理
# version: 0.6
# authors: enterscholar

enabled_site_setting :discourse_journals_enabled

register_asset "stylesheets/common/discourse-journals.scss"

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
  require_relative "app/services/discourse_journals/master_record_renderer"
  require_relative "app/services/discourse_journals/api_sync/client"
  require_relative "app/services/discourse_journals/api_sync/importer"
  require_relative "app/services/discourse_journals/journal_upserter"
  require_relative "app/jobs/regular/discourse_journals/sync_from_api"

  # 注册 API 路由
  Discourse::Application.routes.append do
    # API 同步
    post "/admin/journals/sync" => "discourse_journals/admin_sync#create",
         :constraints => AdminConstraint.new
    post "/admin/journals/sync/test" => "discourse_journals/admin_sync#test_connection",
         :constraints => AdminConstraint.new
    
    # 导入日志查询
    get "/admin/journals/imports/:id/status" => "discourse_journals/admin_imports#status",
        :constraints => AdminConstraint.new
  end
end
