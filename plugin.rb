# frozen_string_literal: true

# name: discourse-journals
# about: Unified journal archive system - mapping, analysis and sync
# version: 1.0
# authors: enterscholar

enabled_site_setting :discourse_journals_enabled

register_asset "stylesheets/common/discourse-journals.scss"
register_asset "stylesheets/common/discourse-journals-admin.scss"

module ::DiscourseJournals
  PLUGIN_NAME = "discourse-journals"
end

require_relative "lib/discourse_journals/engine"

# Register admin route (shows in Plugins menu)
add_admin_route "discourse_journals.title", "discourse-journals"

after_initialize do
  require_relative "app/models/discourse_journals/mapping_analysis"
  require_relative "app/services/discourse_journals/api_rate_limiter"
  require_relative "app/services/discourse_journals/bulk_topic_deleter"
  require_relative "app/services/discourse_journals/field_normalizer"
  require_relative "app/services/discourse_journals/field_usage_tracker"
  require_relative "app/services/discourse_journals/master_record_renderer"
  require_relative "app/services/discourse_journals/journal_upserter"
  require_relative "app/services/discourse_journals/title_matcher"
  require_relative "app/services/discourse_journals/api_data_transformer"
  require_relative "app/services/discourse_journals/svg_chart_builder"
  require_relative "app/services/discourse_journals/cover_image_generator"
  require_relative "app/services/discourse_journals/mapping_applier"
  require_relative "app/services/discourse_journals/journal_tag_manager"
  require_relative "app/services/discourse_journals/journal_suggested_provider"
  require_relative "app/jobs/regular/discourse_journals/analyze_mapping"
  require_relative "app/jobs/regular/discourse_journals/apply_mapping"
  require_relative "app/jobs/regular/discourse_journals/delete_all_journals"

  Topic.register_custom_field_type("discourse_journals_issn_l", :string)
  Topic.register_custom_field_type("discourse_journals_publisher", :string)
  Topic.register_custom_field_type("discourse_journals_data", :string)
  Topic.register_custom_field_type("discourse_journals_cover_url", :string)
  Topic.register_custom_field_type("discourse_journals_country", :string)
  Topic.register_custom_field_type("discourse_journals_cover_url_hash", :string)

  module ::DiscourseJournals
    CUSTOM_FIELD_NAMES = %w[
      discourse_journals_issn_l
      discourse_journals_publisher
      discourse_journals_data
      discourse_journals_cover_url
      discourse_journals_country
    ].freeze

    def self.resolve_seo_placeholders(template, topic)
      return "" if template.blank? || topic.nil?

      custom_fields =
        TopicCustomField
          .where(topic_id: topic.id, name: CUSTOM_FIELD_NAMES)
          .pluck(:name, :value)
          .to_h

      tag_names = topic.tags.loaded? ? topic.tags.map(&:name) : topic.tags.pluck(:name)

      replacements = {
        "title" => topic.title || "",
        "issn" => custom_fields["discourse_journals_issn_l"] || "",
        "publisher" => custom_fields["discourse_journals_publisher"] || "",
        "category" => topic.category&.name || "",
        "tags" => tag_names.join(", "),
        "site_name" => SiteSetting.title || "",
      }

      result = template.gsub(/\{\{(\w+)\}\}/) { |_| replacements[$1] || "" }
      result.gsub(/,\s*,/, ",").gsub(/\s*-\s*-/, " -").strip.gsub(/^[,\s-]+|[,\s-]+$/, "").strip
    end

    def self.find_journal_topic(request_path)
      return nil unless SiteSetting.discourse_journals_enabled
      return nil unless request_path&.start_with?("/t/")

      category_id = SiteSetting.discourse_journals_category_id.to_i
      return nil if category_id.zero?

      topic_id = request_path.match(%r{/t/[^/]+/(\d+)}i)&.captures&.first
      return nil unless topic_id

      Topic.includes(:category, :tags).find_by(id: topic_id, category_id: category_id)
    end
  end

  register_modifier(:meta_data_content) do |content, type, context|
    next content unless SiteSetting.discourse_journals_enabled
    next content unless type == :title || type == :description

    request_path = context[:url]

    begin
      if type == :title
        suffix = SiteSetting.discourse_journals_title_suffix
        next content if suffix.blank?

        category_id = SiteSetting.discourse_journals_category_id.to_i
        next content if category_id.zero?
        next content unless request_path&.start_with?("/t/")

        topic_id = request_path.match(%r{/t/[^/]+/(\d+)}i)&.captures&.first
        next content unless topic_id
        next content unless Topic.where(id: topic_id, category_id: category_id).exists?
        next content if content.include?(suffix)

        "#{content} - #{suffix}"
      elsif type == :description
        template = SiteSetting.discourse_journals_meta_description
        next content if template.blank?

        topic = ::DiscourseJournals.find_journal_topic(request_path)
        next content unless topic

        resolved = ::DiscourseJournals.resolve_seo_placeholders(template, topic)
        resolved.present? ? resolved : content
      else
        content
      end
    rescue StandardError => e
      Rails.logger.warn("[DiscourseJournals] Failed to modify #{type}: #{e.message}")
      content
    end
  end

  keywords_html = ->(controller) do
    next "" unless SiteSetting.discourse_journals_enabled
    next "" unless controller.instance_of?(TopicsController)

    template = SiteSetting.discourse_journals_meta_keywords
    next "" if template.blank?

    topic_view = controller.instance_variable_get(:@topic_view)
    next "" unless topic_view

    topic = topic_view.topic
    category_id = SiteSetting.discourse_journals_category_id.to_i
    next "" if category_id.zero? || topic.category_id != category_id

    resolved = ::DiscourseJournals.resolve_seo_placeholders(template, topic)
    next "" if resolved.blank?

    escaped = ERB::Util.html_escape(resolved)
    "<meta name=\"keywords\" content=\"#{escaped}\">"
  end

  register_html_builder("server:before-head-close-crawler", &keywords_html)
  register_html_builder("server:before-head-close", &keywords_html)

  sidebar_hide_html = ->(controller) do
    next "" unless SiteSetting.discourse_journals_enabled

    category_id = SiteSetting.discourse_journals_category_id.to_i
    next "" if category_id.zero?

    path = controller.request.path rescue nil
    next "" if path.blank?

    topic_id = path[%r{/t/(?:[^/]+/)?(\d+)}, 1]&.to_i
    next "" unless topic_id&.positive?

    topic_cat = Topic.where(id: topic_id).pick(:category_id)
    next "" unless topic_cat == category_id

    <<~HTML
      <style id="dj-hide-sidebar">.sidebar-wrapper{display:none !important}</style>
      <meta name="dj-journal-page" content="1">
    HTML
  end

  register_html_builder("server:before-head-close", &sidebar_hide_html)

  DiscoursePluginRegistry.register_list_suggested_for_provider(
    DiscourseJournals::JournalSuggestedProvider.method(:call),
    self,
  )

  register_modifier(:topic_view_suggested_topics_options) do |options, topic_view|
    next options unless SiteSetting.discourse_journals_enabled
    next options unless SiteSetting.discourse_journals_suggested_mode == "custom_only"

    category_id = SiteSetting.discourse_journals_category_id.to_i
    next options if category_id.zero?
    next options unless topic_view.topic.category_id == category_id

    options.merge(include_random: false)
  end

  on(:before_post_process_cooked) do |doc, post|
    next unless post&.topic
    category_id = SiteSetting.discourse_journals_category_id.to_i
    next if category_id.zero? || post.topic.category_id != category_id
    next unless post.post_number == 1

    json_field =
      TopicCustomField.find_by(topic_id: post.topic_id, name: "discourse_journals_data")
    if json_field&.value.present?
      begin
        normalized = JSON.parse(json_field.value).deep_symbolize_keys
        html = ::DiscourseJournals::MasterRecordRenderer.new(normalized).render
        post.update_columns(cooked: html, baked_version: Post::BAKED_VERSION)
      rescue JSON::ParserError => e
        Rails.logger.warn(
          "[DiscourseJournals] Failed to re-render post #{post.id} from stored data: #{e.message}",
        )
      end
    end
  end

  reloadable_patch do
    sitemap_patch = Module.new do
      def topics
        if name == RECENT_SITEMAP_NAME
          sitemap_topics.pluck(
            :id, :slug,
            Arel.sql("GREATEST(topics.bumped_at, topics.updated_at)"),
            :updated_at, :posts_count,
          )
        elsif name == NEWS_SITEMAP_NAME
          sitemap_topics.pluck(:id, :title, :slug, :created_at)
        else
          sitemap_topics.pluck(
            :id, :slug,
            Arel.sql("GREATEST(topics.bumped_at, topics.updated_at)"),
            :updated_at,
          )
        end
      end
    end

    ::Sitemap.prepend(sitemap_patch)
  end

  Discourse::Application.routes.append do
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

    post "/admin/journals/mapping/apply" => "discourse_journals/admin_mapping#apply",
         :constraints => AdminConstraint.new
    get "/admin/journals/mapping/apply_status" => "discourse_journals/admin_mapping#apply_status",
        :constraints => AdminConstraint.new
    post "/admin/journals/mapping/apply_pause" => "discourse_journals/admin_mapping#apply_pause",
         :constraints => AdminConstraint.new
    post "/admin/journals/mapping/apply_resume" => "discourse_journals/admin_mapping#apply_resume",
         :constraints => AdminConstraint.new

    delete "/admin/journals/delete_all" => "discourse_journals/admin_mapping#delete_all",
           :constraints => AdminConstraint.new
  end
end
