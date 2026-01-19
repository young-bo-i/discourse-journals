# frozen_string_literal: true

module DiscourseJournals
  class AdminController < ::Admin::AdminController
    requires_plugin DiscourseJournals::PLUGIN_NAME

    def index
    end
  end
end
