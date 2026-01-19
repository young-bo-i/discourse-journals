# frozen_string_literal: true

# name: discourse-journals
# about: Manage a read-only, SEO-friendly journal directory with Excel import/upsert.
# version: 0.1
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
  require_relative "app/services/discourse_journals/json/importer"
  require_relative "app/services/discourse_journals/journal_upserter"
  require_relative "app/jobs/regular/discourse_journals/import_json"

  add_admin_route "discourse_journals.title", "journals", use_new_show_route: true

  add_to_serializer(
    :admin_plugin,
    :extras,
    include_condition: -> { self.name == "discourse-journals" },
  ) { { discourse_journals_enabled: SiteSetting.discourse_journals_enabled } }
end
