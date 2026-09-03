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
  require_relative "app/models/discourse_journals/promo_stat"
  require_relative "app/models/discourse_journals/persona_import"
  require_relative "app/services/discourse_journals/persona_pool"
  require_relative "app/services/discourse_journals/persona_builder"
  require_relative "app/services/discourse_journals/persona_file_parser"
  require_relative "app/services/discourse_journals/api_rate_limiter"
  require_relative "app/services/discourse_journals/api_client"
  require_relative "app/services/discourse_journals/outdated_marker"
  require_relative "app/services/discourse_journals/bulk_topic_deleter"
  require_relative "app/services/discourse_journals/field_normalizer"
  require_relative "app/services/discourse_journals/master_record_renderer"
  require_relative "app/services/discourse_journals/journal_upserter"
  require_relative "app/services/discourse_journals/journal_seo_context"
  require_relative "app/services/discourse_journals/performance_logger"
  require_relative "app/services/discourse_journals/title_matcher"
  require_relative "app/services/discourse_journals/api_data_transformer"
  require_relative "app/services/discourse_journals/svg_chart_builder"
  require_relative "app/services/discourse_journals/topic_title_key_backfill"
  require_relative "app/services/discourse_journals/mapping_applier"
  require_relative "app/services/discourse_journals/journal_tag_manager"
  require_relative "app/services/discourse_journals/journal_suggested_provider"
  require_relative "app/jobs/regular/discourse_journals/analyze_mapping"
  require_relative "app/jobs/regular/discourse_journals/apply_mapping"
  require_relative "app/jobs/regular/discourse_journals/delete_all_journals"
  require_relative "app/jobs/regular/discourse_journals/import_personas"

  # Persona-pool user custom fields (server-only; never exposed via serializers).
  User.register_custom_field_type("discourse_journals_persona", :string)
  User.register_custom_field_type("discourse_journals_field", :string)
  User.register_custom_field_type("discourse_journals_tone", :string)

  Topic.register_custom_field_type("discourse_journals_issn_l", :string)
  Topic.register_custom_field_type("discourse_journals_publisher", :string)
  Topic.register_custom_field_type("discourse_journals_data", :string)
  Topic.register_custom_field_type("discourse_journals_cover_url", :string)
  Topic.register_custom_field_type("discourse_journals_country", :string)
  Topic.register_custom_field_type("discourse_journals_normalized_title_key", :string)
  Topic.register_custom_field_type("discourse_journals_api_id", :string)
  Topic.register_custom_field_type("discourse_journals_outdated", :string)

  module ::DiscourseJournals
    # The canonical journal custom-field list lives in JournalUpserter
    # (JournalUpserter::CUSTOM_FIELD_NAMES) — the only reader/writer of the set.

    SEO_FIELD_NAMES = %w[discourse_journals_issn_l discourse_journals_publisher].freeze
    JSONLD_FIELD_NAMES = %w[
      discourse_journals_issn_l
      discourse_journals_publisher
      discourse_journals_country
      discourse_journals_data
    ].freeze
    JOURNAL_SEO_FIELD_NAMES = (SEO_FIELD_NAMES + JSONLD_FIELD_NAMES).uniq.freeze

    def self.build_journal_jsonld(topic, topic_view, seo_context = nil)
      seo_context ||= JournalSeoContext.new(topic: topic, topic_view: topic_view)

      issn = seo_context.custom_fields["discourse_journals_issn_l"]
      publisher_name = seo_context.custom_fields["discourse_journals_publisher"]
      country = seo_context.custom_fields["discourse_journals_country"]

      jsonld = {
        "@context" => "https://schema.org",
        "@type" => "Periodical",
        "name" => topic.title,
        "url" => "#{Discourse.base_url}#{topic.relative_url}",
      }

      jsonld["issn"] = issn if issn.present?

      if publisher_name.present?
        jsonld["publisher"] = { "@type" => "Organization", "name" => publisher_name }
      end

      image_url = seo_context.image_url
      if image_url.present?
        jsonld["image"] = image_url.start_with?("http") ? image_url : "#{Discourse.base_url}#{image_url}"
      end

      tag_names = seo_context.tag_names
      jsonld["keywords"] = tag_names.join(", ") if tag_names.present?

      if country.present?
        jsonld["countryOfOrigin"] = { "@type" => "Country", "name" => country }
      end

      jsonld["dateCreated"] = topic.created_at.iso8601 if topic.created_at
      jsonld["dateModified"] = topic.updated_at.iso8601 if topic.updated_at

      template = SiteSetting.discourse_journals_meta_description
      if template.present?
        desc = seo_context.resolve_template(template)
        jsonld["description"] = desc if desc.present?
      end

      enrich_jsonld_from_data!(jsonld, seo_context.parsed_data)
      jsonld
    end

    def self.enrich_jsonld_from_data!(jsonld, data)
      return if data.blank?

      id = data[:identity] || {}
      jsonld["alternateName"] = id[:abbreviation] if id[:abbreviation].present?

      pub = data[:publication] || {}
      if pub[:first_publication_year].present?
        jsonld["startDate"] = pub[:first_publication_year].to_s
      end

      oa = data[:open_access] || {}
      jsonld["isAccessibleForFree"] = true if oa[:is_oa]

      jcr = data.dig(:jcr, :data)&.first
      if jcr&.dig(:impact_factor)
        jsonld["award"] = "Impact Factor: #{jcr[:impact_factor]} (#{jcr[:year]})"
      end

      st = data[:subjects_topics] || {}
      subjects = st[:subjects] || []
      if subjects.present?
        jsonld["about"] = subjects.first(5).map do |s|
          { "@type" => "Thing", "name" => s }
        end
      end

      # Reader-reported submission experiences (upstream `comments` source) map
      # cleanly onto schema.org aggregateRating.
      rv = data[:reviews] || {}
      if rv[:rating].present? && rv[:count].to_i.positive?
        jsonld["aggregateRating"] = {
          "@type" => "AggregateRating",
          "ratingValue" => rv[:rating],
          "ratingCount" => rv[:count],
          "bestRating" => 5,
          "worstRating" => 0,
        }
      end

      m = data[:metrics] || {}
      metrics_parts = []
      metrics_parts << "Works: #{m[:works_count]}" if m[:works_count]
      metrics_parts << "Citations: #{m[:cited_by_count]}" if m[:cited_by_count]
      metrics_parts << "H-Index: #{m[:h_index]}" if m[:h_index]
      if metrics_parts.any? && jsonld["description"].present?
        jsonld["description"] = "#{jsonld["description"]}. #{metrics_parts.join(", ")}"
      end
    rescue StandardError => e
      Rails.logger.warn("[DiscourseJournals] JSON-LD enrichment failed: #{e.message}")
    end

    def self.resolve_seo_placeholders(template, topic, seo_context = nil)
      return "" if template.blank? || topic.nil?

      (seo_context || JournalSeoContext.new(topic: topic)).resolve_template(template)
    end

    def self.cached_seo_context_for_topic(topic, topic_view: nil)
      cached = topic.instance_variable_get(:@dj_seo_context)
      return cached if cached

      context = JournalSeoContext.new(topic: topic, topic_view: topic_view)
      topic.instance_variable_set(:@dj_seo_context, context)
      context
    end

    def self.find_journal_topic(request_path)
      return nil unless SiteSetting.discourse_journals_enabled
      return nil unless request_path&.start_with?("/t/")

      category_id = SiteSetting.discourse_journals_category_id.to_i
      return nil if category_id.zero?

      topic_id = request_path.match(%r{/t/[^/]+/(\d+)}i)&.captures&.first
      return nil unless topic_id

      Topic.includes(:tags, :category).find_by(id: topic_id, category_id: category_id)
    end
  end

  add_preloaded_topic_list_custom_field("discourse_journals_cover_url")

  add_to_serializer(
    :suggested_topic,
    :discourse_journals_cover_url,
    include_condition: -> {
      object.custom_fields["discourse_journals_cover_url"].present? || object.image_upload_id.present?
    },
  ) { object.image_url.presence || object.custom_fields["discourse_journals_cover_url"] }

  register_modifier(:meta_data_content) do |content, type, context|
    next content unless SiteSetting.discourse_journals_enabled
    next content unless type == :title || type == :description

    request_path = context[:url]
    next content unless request_path&.start_with?("/t/")

    category_id = SiteSetting.discourse_journals_category_id.to_i
    next content if category_id.zero?

    begin
      if type == :title
        suffix = SiteSetting.discourse_journals_title_suffix
        next content if suffix.blank?
        next content if content.include?(suffix)

        topic_id = request_path.match(%r{/t/[^/]+/(\d+)}i)&.captures&.first
        next content unless topic_id

        topic_cat =
          DiscourseJournals::PerformanceLogger.measure("seo.title.category_lookup", topic_id: topic_id) do
            Topic.where(id: topic_id).pick(:category_id)
          end
        next content unless topic_cat == category_id

        "#{content} - #{suffix}"
      elsif type == :description
        template = SiteSetting.discourse_journals_meta_description
        next content if template.blank?

        topic =
          DiscourseJournals::PerformanceLogger.measure("seo.description.topic_lookup") do
            ::DiscourseJournals.find_journal_topic(request_path)
          end
        next content unless topic

        resolved =
          DiscourseJournals::PerformanceLogger.measure("seo.description.resolve", topic_id: topic.id) do
            seo_context = ::DiscourseJournals.cached_seo_context_for_topic(topic)
            ::DiscourseJournals.resolve_seo_placeholders(template, topic, seo_context)
          end
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

    topic_view = controller.instance_variable_get(:@topic_view)
    next "" unless topic_view

    category_id = SiteSetting.discourse_journals_category_id.to_i
    next "" if category_id.zero?

    topic = topic_view.topic
    next "" unless topic.category_id == category_id

    template = SiteSetting.discourse_journals_meta_keywords
    next "" if template.blank?

    begin
      resolved =
        DiscourseJournals::PerformanceLogger.measure("seo.keywords.resolve", topic_id: topic.id) do
          seo_context = ::DiscourseJournals.cached_seo_context_for_topic(topic, topic_view: topic_view)
          ::DiscourseJournals.resolve_seo_placeholders(template, topic, seo_context)
        end
      next "" if resolved.blank?

      escaped = ERB::Util.html_escape(resolved)
      "<meta name=\"keywords\" content=\"#{escaped}\">"
    rescue StandardError => e
      Rails.logger.warn("[DiscourseJournals] Keywords generation failed: #{e.message}")
      ""
    end
  end

  register_html_builder("server:before-head-close-crawler", &keywords_html)
  register_html_builder("server:before-head-close", &keywords_html)

  jsonld_html = ->(controller) do
    next "" unless SiteSetting.discourse_journals_enabled
    next "" unless controller.instance_of?(TopicsController)

    topic_view = controller.instance_variable_get(:@topic_view)
    next "" unless topic_view

    category_id = SiteSetting.discourse_journals_category_id.to_i
    next "" if category_id.zero?

    topic = topic_view.topic
    next "" unless topic.category_id == category_id

    begin
      jsonld =
        DiscourseJournals::PerformanceLogger.measure("seo.jsonld.build", topic_id: topic.id) do
          seo_context = ::DiscourseJournals.cached_seo_context_for_topic(topic, topic_view: topic_view)
          ::DiscourseJournals.build_journal_jsonld(topic, topic_view, seo_context)
        end
      %(<script type="application/ld+json">#{jsonld.to_json}</script>)
    rescue StandardError => e
      Rails.logger.warn("[DiscourseJournals] JSON-LD generation failed: #{e.message}")
      ""
    end
  end

  register_html_builder("server:before-head-close-crawler", &jsonld_html)
  register_html_builder("server:before-head-close", &jsonld_html)

  sidebar_hide_html = ->(controller) do
    next "" unless SiteSetting.discourse_journals_enabled
    next "" unless controller.instance_of?(TopicsController)

    category_id = SiteSetting.discourse_journals_category_id.to_i
    next "" if category_id.zero?

    topic_cat = begin
      tv = controller.instance_variable_get(:@topic_view)
      tv&.topic&.category_id
    rescue StandardError
      nil
    end
    next "" unless topic_cat == category_id

    <<~HTML
      <style id="dj-hide-sidebar">.sidebar-wrapper{display:none !important}@media(min-width:925px){.more-topics__container{display:none !important}}</style>
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

    current_cooked = post.cooked
    if current_cooked.present? && current_cooked.include?('class="dj-journal"')
      post.update_columns(baked_version: Post::BAKED_VERSION) if post.baked_version != Post::BAKED_VERSION
      next
    end

    json_value =
      TopicCustomField.where(topic_id: post.topic_id, name: "discourse_journals_data").pick(:value)

    outdated =
      TopicCustomField.exists?(topic_id: post.topic_id, name: "discourse_journals_outdated")

    if json_value.blank?
      # No journal data to render from. If the topic is outdated, re-inject the
      # standalone banner so a rebake (which re-cooks from raw) does not drop it.
      if outdated && !post.cooked.to_s.include?("dj-outdated-notice")
        notice =
          I18n.with_locale(SiteSetting.default_locale) do
            ERB::Util.html_escape(I18n.t("discourse_journals.render.outdated_notice"))
          end
        banner =
          %(<div class="dj-outdated-notice" role="alert"><span class="dj-outdated-notice__text">#{notice}</span></div>)
        post.update_columns(cooked: "#{banner}\n#{post.cooked}")
        fragment = Nokogiri::HTML5.fragment(banner)
        first_node = doc.children.first
        first_node ? first_node.add_previous_sibling(fragment) : doc.add_child(fragment)
      end
      next
    end

    begin
      normalized = JSON.parse(json_value).deep_symbolize_keys
      renderer = ::DiscourseJournals::MasterRecordRenderer.new(normalized)
      html =
        DiscourseJournals::PerformanceLogger.measure("render.cooked_rebuild", topic_id: post.topic_id) do
          I18n.with_locale(SiteSetting.default_locale) { renderer.render(outdated: outdated) }
        end
      post.update_columns(cooked: html, baked_version: Post::BAKED_VERSION)

      doc.children.remove
      Nokogiri::HTML5.fragment(html).children.each { |child| doc.add_child(child.dup) }

      plain =
        DiscourseJournals::PerformanceLogger.measure("render.seo_excerpt", topic_id: post.topic_id) do
          I18n.with_locale(SiteSetting.default_locale) { renderer.render_seo_excerpt }
        end
      post.topic.update_excerpt(plain) if plain.present?
    rescue StandardError => e
      Rails.logger.warn(
        "[DiscourseJournals] Failed to re-render post #{post.id} from stored data: #{e.message}",
      )
    end
  end

  # Sitemap patches:
  # 1. last_posted_topic: Core bug – MAX(updated_at) on a scope with LIMIT/OFFSET
  #    returns nil for page 2+ because the aggregate collapses to one row and OFFSET
  #    skips past it. Fix: use a subquery so MAX operates on the correct row set.
  # 2. topics: Journal sync updates updated_at but not bumped_at. Core uses
  #    (bumped_at || updated_at) for <lastmod>, ignoring updated_at when bumped_at
  #    is present. For journal topics only, use max(bumped_at, updated_at).
  reloadable_patch do
    sitemap_patch = Module.new do
      def last_posted_topic
        ::Topic.where(id: sitemap_topics.select(:id)).maximum(:updated_at)
      end

      def topics
        rows = super
        return rows if name == Sitemap::NEWS_SITEMAP_NAME

        journal_cid = SiteSetting.discourse_journals_category_id.to_i
        return rows if journal_cid.zero?

        journal_topic_ids = ::Topic.where(category_id: journal_cid).where(
          id: rows.map(&:first),
        ).pluck(:id).to_set

        rows.map do |row|
          topic_id = row[0]
          next row unless journal_topic_ids.include?(topic_id)

          if name == Sitemap::RECENT_SITEMAP_NAME
            id, slug, bumped_at, updated_at, posts_count = row
            effective = [bumped_at, updated_at].compact.max
            [id, slug, effective, updated_at, posts_count]
          else
            id, slug, bumped_at, updated_at = row
            effective = [bumped_at, updated_at].compact.max
            [id, slug, effective, updated_at]
          end
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

    get "/admin/journals/promo_stats" => "discourse_journals/admin_mapping#promo_stats",
        :constraints => AdminConstraint.new

    delete "/admin/journals/delete_all" => "discourse_journals/admin_mapping#delete_all",
           :constraints => AdminConstraint.new

    post "/admin/journals/personas/import" => "discourse_journals/admin_personas#import",
         :constraints => AdminConstraint.new
    get "/admin/journals/personas/status" => "discourse_journals/admin_personas#status",
        :constraints => AdminConstraint.new

    # Public: site header banner impression/click tracking (anonymous allowed)
    post "/journals/promo/track" => "discourse_journals/promo#track"

    # Public: server-side proxy for upstream submission guideline / LaTeX
    # template downloads, which sit behind the API key a browser cannot send.
    get "/journals/:api_id/submission/:kind" => "discourse_journals/submission#show",
        :constraints => { api_id: /\d+/, kind: /guideline|latex/ }
  end
end
