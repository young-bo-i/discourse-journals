# frozen_string_literal: true

# name: discourse-journals
# about: 期刊统一档案系统 - 导入页面：/admin/journals
# version: 0.5
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

after_initialize do
  require_relative "app/services/discourse_journals/field_normalizer"
  require_relative "app/services/discourse_journals/master_record_renderer"
  require_relative "app/services/discourse_journals/json_import/importer"
  require_relative "app/services/discourse_journals/journal_upserter"
  require_relative "app/jobs/regular/discourse_journals/import_json"

  # 加载控制器
  load File.expand_path("../app/controllers/discourse_journals/admin_controller.rb", __FILE__)
  load File.expand_path("../app/controllers/discourse_journals/admin_imports_controller.rb", __FILE__)

  # 直接在 Discourse 路由中注册
  Discourse::Application.routes.prepend do
    get "/admin/journals" => "discourse_journals/admin#index", :constraints => AdminConstraint.new
    post "/admin/journals/imports" => "discourse_journals/admin_imports#create", :constraints => AdminConstraint.new
  end
end
