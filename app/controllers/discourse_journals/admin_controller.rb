# frozen_string_literal: true

module DiscourseJournals
  class AdminController < ::Admin::AdminController
    requires_plugin DiscourseJournals::PLUGIN_NAME

    def index
      # 渲染主页面
    end
  end
end
