# frozen_string_literal: true

module DiscourseJournals
  # Crawlers never run the client-side journal suggestions, so without these
  # server-rendered links each journal page is reachable only from the sitemap
  # and deep tag listings.
  class RelatedJournalLinks
    LIMIT = 12
    CACHE_TTL = 1.day

    def self.html(topic)
      return "" if !SiteSetting.discourse_journals_enabled || topic.nil?

      category_id = SiteSetting.discourse_journals_category_id.to_i
      return "" if category_id.zero? || topic.category_id != category_id

      criteria =
        SiteSetting.discourse_journals_suggested_criteria.to_s.split("|").map(&:strip).compact_blank
      return "" if criteria.empty?

      ids =
        Discourse
          .cache
          .fetch(
            "dj_related_links_v1_#{topic.id}_#{criteria.sort.join("-")}",
            expires_in: CACHE_TTL,
          ) { JournalSuggestedProvider.find_related_topic_ids(topic, category_id, criteria, LIMIT) }
      return "" if ids.blank?

      related = Topic.where(id: ids, visible: true).select(:id, :title, :slug).index_by(&:id)
      items =
        ids.filter_map do |id|
          journal = related[id]
          next if journal.nil?

          url = ERB::Util.html_escape(journal.relative_url)
          %(<li><a href="#{url}">#{ERB::Util.html_escape(journal.title)}</a></li>)
        end
      return "" if items.empty?

      heading = ERB::Util.html_escape(I18n.t("discourse_journals.related_journals"))
      %(<section class="dj-related-journals"><h2>#{heading}</h2><ul>#{items.join}</ul></section>)
    end
  end
end
