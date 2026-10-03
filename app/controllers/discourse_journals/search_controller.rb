# frozen_string_literal: true

module DiscourseJournals
  class SearchController < ::ApplicationController
    requires_plugin DiscourseJournals::PLUGIN_NAME

    RATE_LIMIT = 60

    # GET /journals/search?q=
    def index
      RateLimiter.new(
        nil,
        "dj-journal-search-#{request.remote_ip}",
        RATE_LIMIT,
        1.minute,
      ).performed!

      ids = JournalTitleSearch.new(params[:q], guardian: guardian).topic_ids
      topics = Topic.where(id: ids).includes(:tags).index_by(&:id)

      render_json_dump(topics: ids.filter_map { |id| serialize(topics[id]) })
    end

    private

    def serialize(topic)
      return if topic.nil?

      {
        id: topic.id,
        title: topic.title,
        slug: topic.slug,
        tags: topic.visible_tags(guardian).map(&:name),
        excerpt: topic.excerpt,
      }
    end
  end
end
