# frozen_string_literal: true

module DiscourseJournals
  class IndexNowController < ::ApplicationController
    requires_plugin DiscourseJournals::PLUGIN_NAME

    skip_before_action :preload_json,
                       :check_xhr,
                       :redirect_to_login_if_required,
                       :redirect_to_profile_if_required

    # GET /<key>.txt — IndexNow verifies site ownership by fetching this file.
    def key_file
      raise Discourse::NotFound if !IndexNow.enabled? || params[:key] != IndexNow.key

      render plain: IndexNow.key
    end
  end
end
