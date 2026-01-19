# frozen_string_literal: true

module ::DiscourseJournals
  class Engine < ::Rails::Engine
    engine_name PLUGIN_NAME
    isolate_namespace DiscourseJournals
  end
end
