# frozen_string_literal: true

module DiscourseJournals
  # Public endpoint hit by the site header banner to record impressions/clicks.
  # Anonymous visitors must be able to call it, so CSRF/XHR guards are relaxed;
  # abuse is capped by a per-IP rate limit and a strict slide/event allowlist,
  # and only anonymous aggregate counters are ever written.
  class PromoController < ::ApplicationController
    requires_plugin DiscourseJournals::PLUGIN_NAME

    skip_before_action :verify_authenticity_token, :check_xhr, only: [:track], raise: false

    # events per IP per minute before tracking is silently dropped
    RATE_LIMIT = 120

    def track
      # `requires_plugin` already rejects requests with 404 when the plugin is
      # disabled, so no explicit enabled check is needed here.
      slide = params[:slide].to_s
      event = params[:event].to_s

      unless PromoStat::SLIDES.include?(slide) && PromoStat::EVENTS.include?(event)
        return render json: failed_json, status: 400
      end

      begin
        RateLimiter.new(nil, "dj-promo-track-#{request.remote_ip}", RATE_LIMIT, 1.minute).performed!
      rescue RateLimiter::LimitExceeded
        # fail soft: never surface an error to the visitor for analytics
        return render json: success_json
      end

      PromoStat.track!(slide: slide, event: event)

      render json: success_json
    end
  end
end
