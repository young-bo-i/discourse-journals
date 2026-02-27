# frozen_string_literal: true

module DiscourseJournals
  class MasterRecordRenderer
    API_COVER_BASE = "https://journal.scholay.com"

    def initialize(normalized_data)
      @d = normalized_data.is_a?(Hash) ? normalized_data : {}
      @toggle_id = 0
    end

    def render
        sections = []
      sections << render_hero
      sections << render_metric_visuals
      sections << render_status_grid
      sections << render_stats_narrative
      sections << render_peer_review
      sections << render_coverage_bars
      sections << render_compact_info
      sections << render_indexing_panel
      sections << render_topic_cloud
      sections << render_topic_donut
      sections << render_warning_timeline
      sections << render_visual_dashboard
      %(<div class="dj-journal">\n#{sections.compact.join("\n")}\n</div>)
    end

    def render_plain_text
      id = @d[:identity] || {}
      pub = @d[:publication] || {}
      m = @d[:metrics] || {}
      jcr = @d.dig(:jcr, :data)&.first
      parts = [id[:title], "ISSN-L: #{id[:issn_l]}"]
      parts << "#{t("publisher")}: #{pub[:publisher_name]}" if pub[:publisher_name]
      parts << "IF: #{jcr[:impact_factor]} (#{jcr[:year]})" if jcr&.dig(:impact_factor)
      parts << "#{t("works")}: #{m[:works_count]}" if m[:works_count]
      parts << "#{t("cited_by")}: #{m[:cited_by_count]}" if m[:cited_by_count]
      parts.compact.join(" | ")
    end

    private

    def identity
      @d[:identity] || {}
    end

    def publication
      @d[:publication] || {}
    end

    def metrics
      @d[:metrics] || {}
    end

    def t(key, **opts)
      I18n.t("discourse_journals.render.#{key}", **opts)
    end

    def h(text)
      return "" if text.nil?
      ERB::Util.html_escape(text.to_s)
    end

    def fmt(num)
      return nil if num.nil?
      num.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse
    end

    def render_hero
      id = identity
      pub = publication
      title = h(id[:title]).presence || t("unknown_journal")
      cover_url = id[:cover_url].present? ? "#{API_COVER_BASE}#{id[:cover_url]}" : nil
      abbrev = h(id[:abbreviation])
      publisher = h(pub[:publisher_name])
      publisher_id = h(pub[:publisher_id])
      country_code = h(pub[:country_code])
      country_name = h(pub[:country_name])
      homepage = id[:homepage_url]
      oa_type = h(id[:openalex_type]).presence || t("type_journal")
      oa_id = h(id[:openalex_id])
      issn_l = h(id[:issn_l])

      cover_initials = extract_initials(id[:title] || "")
      cover_html = if cover_url
        %(<img src="#{h(cover_url)}" alt="#{title}" loading="lazy" onerror="this.style.display='none';this.nextElementSibling.style.display='flex'" />) +
        %(<div class="dj-hero__cover-art" style="display:none"><span class="dj-cover-code">#{h(cover_initials)}</span><span class="dj-cover-label">#{title}</span></div>)
      else
        %(<div class="dj-hero__cover-art"><span class="dj-cover-code">#{h(cover_initials)}</span><span class="dj-cover-label">#{title}</span></div>)
      end

      homepage_display = homepage.present? ? homepage.sub(%r{https?://}, "").sub(/\/\z/, "") : nil
      homepage_link = homepage.present? ? %(<a href="#{h(homepage)}" target="_blank" rel="noopener">#{h(homepage_display)}</a>) : nil

      <<~HTML
        <header class="dj-hero">
          <div class="dj-hero__cover">
            #{cover_html}
          </div>
          <div class="dj-hero__body">
            <div class="dj-hero__eyebrow">#{h(t("eyebrow"))}</div>
            <h2 class="dj-hero__title">#{title}</h2>
            <p class="dj-hero__subtitle">#{publisher}</p>
            <div class="dj-hero__meta">
              <span class="dj-pill dj-pill--type">#{oa_type}</span>
              #{"<span class=\"dj-pill dj-pill--flag\">#{country_code}</span>" if country_code.present?}
              #{"<span class=\"dj-pill\">ISSN-L #{issn_l}</span>" if issn_l.present?}
              #{"<span class=\"dj-pill\">OpenAlex #{oa_id}</span>" if oa_id.present?}
            </div>
            #{hero_footer(publisher, publisher_id, homepage, homepage_link, country_name, country_code)}
          </div>
        </header>
      HTML
    end

    def render_metric_visuals
      jcr_latest = @d.dig(:jcr, :data)&.first
      sjr_latest = @d.dig(:scimago, :data)&.first
      cas_latest = @d.dig(:cas_partition, :data)&.first
      warn_latest = @d.dig(:warning, :data)&.first
      ccf_data = @d[:ccf]

      return nil unless jcr_latest || sjr_latest || cas_latest || ccf_data

      jcr_card = render_jcr_card(jcr_latest) if jcr_latest
      sjr_card = render_sjr_card(sjr_latest) if sjr_latest
      cas_card = render_cas_card(cas_latest, jcr_latest, warn_latest) if cas_latest
      ccf_card = render_ccf_card(ccf_data) if ccf_data

      <<~HTML
        <section class="dj-panel dj-metric-visuals">
          <div class="dj-metric-visuals__header">
            <div>
              <h3>#{h(t("metrics_overview"))}</h3>
            </div>
          </div>
          <div class="dj-metric-grid">
            #{jcr_card}
            #{sjr_card}
            #{cas_card}
            #{ccf_card}
          </div>
        </section>
      HTML
    end

    def render_jcr_card(jcr)
      quartile = h(jcr[:quartile]) || "—"
      impact = h(jcr[:impact_factor]) || "—"
      q_num = quartile.match(/Q(\d)/i)&.captures&.first || "1"

      <<~HTML
        <article class="dj-metric-card dj-metric-card--jcr">
          <h4 class="dj-metric-heading">#{h(t("jcr_heading"))}</h4>
          <div class="dj-metric-structure dj-building dj-building--q#{q_num}">
            <div class="dj-building-level"></div>
            <div class="dj-building-level"></div>
            <div class="dj-building-level"></div>
            <div class="dj-building-level"></div>
            <div class="dj-building-base"></div>
          </div>
          <div class="dj-metric-content">
            <p class="dj-metric-tier dj-metric-tier--jcr">#{quartile}</p>
            <p class="dj-metric-value dj-metric-value--jcr">#{h(t("if_label", value: impact))}</p>
          </div>
        </article>
      HTML
    end

    def render_sjr_card(sjr)
      quartile = h(sjr[:best_quartile]) || "—"
      sjr_val = sjr[:sjr] ? format("%.3f", sjr[:sjr]) : "—"
      q_num = quartile.match(/Q(\d)/i)&.captures&.first || "1"

      <<~HTML
        <article class="dj-metric-card dj-metric-card--sjr">
          <h4 class="dj-metric-heading">#{h(t("scimago_heading"))}</h4>
          <div class="dj-metric-structure dj-building dj-building--q#{q_num}">
            <div class="dj-building-level"></div>
            <div class="dj-building-level"></div>
            <div class="dj-building-level"></div>
            <div class="dj-building-level"></div>
            <div class="dj-building-base"></div>
          </div>
          <div class="dj-metric-content">
            <p class="dj-metric-tier dj-metric-tier--sjr">#{quartile}</p>
            <p class="dj-metric-value dj-metric-value--sjr">#{h(t("sjr_label", value: sjr_val))}</p>
          </div>
        </article>
      HTML
    end

    def render_cas_card(cas, jcr, warn)
      partition = extract_cas_zone(cas[:major_quartile])
      zone_class = partition ? "dj-pyramid--zone#{partition}" : ""
      zone_label = partition ? t("zone_label", num: partition) : "—"
      impact_val = jcr ? t("if_label", value: h(jcr[:impact_factor])) : "—"

      warning_html = ""
      if warn && warn[:level].present?
        warning_html = %(<p class="dj-metric-warning">#{h(t("warning_label", level: warn[:level]))}</p>)
      end

      <<~HTML
        <article class="dj-metric-card dj-metric-card--cas">
          <h4 class="dj-metric-heading">#{h(t("cas_heading"))}</h4>
          <div class="dj-metric-structure dj-pyramid #{zone_class}">
            <div class="dj-pyramid-outline">
              <div class="dj-pyramid-indicator"></div>
              <div class="dj-pyramid-cut dj-pyramid-cut--1"></div>
              <div class="dj-pyramid-cut dj-pyramid-cut--2"></div>
              <div class="dj-pyramid-cut dj-pyramid-cut--3"></div>
              <div class="dj-pyramid-cut dj-pyramid-cut--4"></div>
            </div>
            <div class="dj-pyramid-shadow"></div>
          </div>
          <div class="dj-metric-content">
            <p class="dj-metric-tier dj-metric-tier--cas">#{h(zone_label)}</p>
            <p class="dj-metric-value dj-metric-value--cas">#{h(impact_val)}</p>
            #{warning_html}
          </div>
        </article>
      HTML
    end

    def render_stats_narrative
      m = metrics
      pub = publication
      jcr = @d.dig(:jcr, :data)&.first
      sjr = @d.dig(:scimago, :data)&.first
      cas = @d.dig(:cas_partition, :data)&.first
      oa = @d[:open_access] || {}

      parts = []
      if m[:works_count] && m[:cited_by_count]
        text = t("narrative_works", works: fmt(m[:works_count]), citations: fmt(m[:cited_by_count]))
        text += t("narrative_oa_suffix", oa_works: fmt(m[:oa_works_count])) if m[:oa_works_count]
        text += "."
        parts << text
      end

      year_range = [pub[:first_publication_year], pub[:last_publication_year]].compact
      if year_range.size == 2
        parts << t("narrative_years", from: year_range[0], to: year_range[1])
      end

      oa_status = oa[:is_oa] ? t("narrative_oa_yes") : t("narrative_oa_no")
      doaj_status = oa[:is_in_doaj] ? t("narrative_doaj_yes") : t("narrative_doaj_no")
      parts << t("narrative_oa_status", oa_status: oa_status, doaj_status: doaj_status)

      if jcr && jcr[:impact_factor]
        parts << t("narrative_jcr", quartile: h(jcr[:quartile]), impact: h(jcr[:impact_factor]), year: h(jcr[:year]))
      end
      if sjr && sjr[:sjr]
        parts << t("narrative_sjr", quartile: h(sjr[:best_quartile]), sjr: format("%.3f", sjr[:sjr]))
      end
      if cas
        zone = extract_cas_zone(cas[:major_quartile])
        parts << t("narrative_cas", zone: h(zone), category: h(cas[:major_category])) if zone
      end

      return nil if parts.empty?

      <<~HTML
        <section class="dj-panel dj-stats-narrative">
          <h3>#{h(t("overview"))}</h3>
          <p>#{parts.join(" ")}</p>
        </section>
      HTML
    end

    def render_compact_info
      id = identity
      pub = publication
      m = metrics
      oa = @d[:open_access] || {}
      jcr_latest = @d.dig(:jcr, :data)&.first
      sjr_latest = @d.dig(:scimago, :data)&.first
      cas_latest = @d.dig(:cas_partition, :data)&.first
      st = @d[:subjects_topics] || {}

      issns = (id[:issn_details] || []).map { |d| h(d[:issn]) }.join(", ")
      alternates = (id[:alternate_titles] || []).map { |t_val| h(t_val) }.join(", ")

      homepage_link = if id[:homepage_url].present?
        short = id[:homepage_url].sub(%r{https?://}, "").sub(/\/\z/, "")
        %(<a href="#{h(id[:homepage_url])}" target="_blank" rel="noopener">#{h(short)}</a>)
      end

      basic_cards = [
        info_card("ISSN-L", h(id[:issn_l])),
        info_card(t("issns"), issns.presence),
        info_card(t("aliases"), alternates.presence),
        info_card(t("abbreviation"), h(id[:abbreviation])),
        info_card(t("openalex_id"), h(id[:openalex_id])),
        info_card(t("wikidata_id"), h(id[:wikidata_qid])),
        info_card(t("homepage"), homepage_link),
      ].compact

      oa_cards = [
        info_card(t("type"), h(id[:openalex_type])),
        info_card(t("publisher"), h(pub[:publisher_name])),
        info_card(t("country"), h(pub[:country_name] || pub[:country_code])),
        info_card(t("works"), fmt(m[:works_count])),
        info_card(t("cited_by"), fmt(m[:cited_by_count])),
        info_card(t("oa_works"), fmt(m[:oa_works_count])),
        info_card(t("h_index"), fmt(m[:h_index])),
        info_card(t("i10_index"), fmt(m[:i10_index])),
        info_card(t("two_year_citedness"), m[:two_year_mean_citedness] ? format("%.3f", m[:two_year_mean_citedness]) : nil),
        info_card(t("first_year"), pub[:first_publication_year]&.to_s.presence),
        info_card(t("last_year"), pub[:last_publication_year]&.to_s.presence),
      ].compact

      licenses_text = (oa[:licenses] || []).filter_map { |l|
        l.is_a?(Hash) ? (l[:type] || l[:license_type]) : l.to_s.presence
      }.uniq.map { |v| h(v) }.join(", ")
      apc_prices_text = (oa[:apc_prices] || []).filter_map { |p|
        next unless p.is_a?(Hash) && p[:price] && p[:currency]
        "#{h(p[:currency])} #{fmt(p[:price])}"
      }.join(", ")
      pub_time = oa[:publication_time_weeks]

      oa_apc_cards = [
        info_card(t("apc_usd_label"), (oa[:apc_usd] || m[:apc_usd]) ? "$#{fmt(oa[:apc_usd] || m[:apc_usd])}" : nil),
        info_card(t("apc_prices_label"), apc_prices_text.presence),
        info_card(t("licenses"), licenses_text.presence),
        info_card(t("publication_time_weeks"), pub_time ? t("review_weeks", count: pub_time) : nil),
      ].compact

      minor_cats = (cas_latest&.dig(:minor_categories) || []).filter_map { |mc|
        next unless mc.is_a?(Hash) && mc[:category].present?
        mc[:quartile].present? ? "#{h(mc[:category])} (#{h(mc[:quartile])})" : h(mc[:category])
      }.join(", ")

      sjr_cats = sjr_latest&.dig(:categories)
      sjr_cats_text = sjr_cats.is_a?(Array) ? sjr_cats.join(", ") : sjr_cats&.to_s

      detail_cards = [
        info_card(t("subject_category"), h(jcr_latest&.dig(:category))),
        info_card(t("rank"), h(jcr_latest&.dig(:rank))),
        info_card(t("major_discipline"), h(cas_latest&.dig(:major_category))),
        info_card(t("wos_index"), cas_latest&.dig(:web_of_science).present? ? h(cas_latest[:web_of_science]) : nil),
        info_card(t("minor_partitions"), minor_cats.presence),
        info_card(t("scimago_h_index"), sjr_latest&.dig(:h_index).present? ? fmt(sjr_latest[:h_index]) : nil),
        info_card(t("total_docs_3years"), sjr_latest&.dig(:total_docs_3years).present? ? fmt(sjr_latest[:total_docs_3years]) : nil),
        info_card(t("total_refs"), sjr_latest&.dig(:total_refs).present? ? fmt(sjr_latest[:total_refs]) : nil),
        info_card(t("total_citations_3years"), sjr_latest&.dig(:total_citations_3years).present? ? fmt(sjr_latest[:total_citations_3years]) : nil),
        info_card(t("citable_docs_3years"), sjr_latest&.dig(:citable_docs_3years).present? ? fmt(sjr_latest[:citable_docs_3years]) : nil),
        info_card(t("scimago_categories"), h(sjr_cats_text)),
      ].compact

      keywords_text = (st[:keywords] || []).map { |k| h(k) }.join(", ")
      subjects_text = (st[:subjects] || []).map { |s| h(s) }.join(", ")
      topics_fields = (st[:topics] || []).filter_map { |tp|
        parts = [tp[:field], tp[:domain]].compact
        parts.any? ? parts.map { |p| h(p) }.join(" > ") : nil
      }.uniq.join(", ")

      kw_cards = [
        info_card(t("keywords"), keywords_text.presence),
        info_card(t("subjects"), subjects_text.presence),
        info_card(t("topic_fields"), topics_fields.presence),
      ].compact

      groups = []
      add_group = ->(title, cards) {
        return if cards.empty?
        groups << <<~HTML
          <div class="dj-info-group">
            <div class="dj-info-group__title">#{h(title)}</div>
            <div class="dj-info-card-grid">#{cards.join}</div>
          </div>
        HTML
      }

      add_group.call(t("basic_info"), basic_cards)
      add_group.call(t("openalex_data"), oa_cards)
      add_group.call(t("oa_apc_title"), oa_apc_cards)
      add_group.call(t("ranking_details"), detail_cards)
      add_group.call(t("keywords_subjects"), kw_cards)

      return nil if groups.empty?

      <<~HTML
        <section class="dj-panel dj-compact-info">
          #{groups.join}
        </section>
      HTML
    end

    def render_topic_cloud
      topics = @d.dig(:subjects_topics, :topics) || []
      return nil if topics.empty?

      max_count = topics.map { |tp| tp[:count].to_i }.max
      max_count = 1 if max_count == 0

      spans = topics.map { |tp|
        weight = ((tp[:count].to_f / max_count) * 5).ceil.clamp(1, 5)
        %(<span data-weight="#{weight}">#{h(tp[:name])}</span>)
      }

      <<~HTML
        <section class="dj-panel">
          <h3>#{h(t("topics"))}</h3>
          <div class="dj-topic-cloud">#{spans.join("\n    ")}</div>
        </section>
      HTML
    end

    def render_ccf_card(ccf)
      rank_raw = h(ccf[:rank])
      letter = rank_raw.to_s.match(/([ABC])/i)&.captures&.first&.upcase || "?"
      rank_class = case letter
                   when "A" then "dj-ccf-badge--a"
                   when "B" then "dj-ccf-badge--b"
                   else "dj-ccf-badge--c"
                   end
      field_text = h(ccf[:field])
      cat_text = h(ccf[:category])

      <<~HTML
        <article class="dj-metric-card dj-metric-card--ccf">
          <h4 class="dj-metric-heading">CCF</h4>
          <div class="dj-metric-structure dj-ccf-badge-wrap">
            <div class="dj-ccf-badge #{rank_class}">#{letter}</div>
          </div>
          <div class="dj-metric-content">
            <p class="dj-metric-tier dj-metric-tier--ccf">#{rank_raw}</p>
            #{"<p class=\"dj-metric-field\">#{field_text}</p>" if field_text.present?}
          </div>
        </article>
      HTML
    end

    def render_status_grid
      oa = @d[:open_access] || {}
      pub = publication
      cas_latest = @d.dig(:cas_partition, :data)&.first

      items = []
      add_status = ->(label, val) {
        return if val.nil?
        items << { label: label, value: val }
      }

      add_status.call(t("oa"), oa[:is_oa])
      add_status.call(t("doaj"), oa[:is_in_doaj])
      add_status.call(t("status_diamond_oa"), oa[:diamond_oa])
      add_status.call(t("is_core"), pub[:is_core])
      add_status.call(t("has_apc"), oa[:has_apc])
      add_status.call(t("status_has_waiver"), oa[:has_waiver])
      add_status.call(t("status_boai"), oa[:boai])
      add_status.call(t("status_copyright_retained"), oa[:copyright_author_retains])
      add_status.call(t("status_plagiarism"), oa[:plagiarism_detection])
      add_status.call(t("status_preservation"), oa[:has_preservation])
      add_status.call(t("status_deposit_policy"), oa[:has_deposit_policy])
      add_status.call(t("status_cas_review"), cas_yn_to_bool(oa[:cas_review]))
      add_status.call(t("status_cas_top"), cas_yn_to_bool(oa[:cas_top]))

      return nil if items.empty?

      grid_items = items.map { |item|
        icon = item[:value] ? status_check_svg : status_cross_svg
        css = item[:value] ? "dj-status-item--yes" : "dj-status-item--no"
        %(<div class="dj-status-item #{css}">#{icon}<span>#{h(item[:label])}</span></div>)
      }.join("\n")

      <<~HTML
        <section class="dj-panel dj-status-grid-panel">
          <h3>#{h(t("status_grid_title"))}</h3>
          <div class="dj-status-grid">#{grid_items}</div>
        </section>
      HTML
    end

    def render_coverage_bars
      cr = @d[:crossref_quality] || {}
      coverage = cr[:coverage]
      return nil if coverage.nil? || coverage.empty?

      bars = coverage.map { |key, pct|
        label = t("field_#{key}")
        bar_svg = SvgChartBuilder.progress_bar(pct, color: "#3885c8")
        <<~HTML
          <div class="dj-coverage-row">
            <span class="dj-coverage-label">#{h(label)}</span>
            <div class="dj-coverage-bar">#{bar_svg}</div>
            <span class="dj-coverage-pct">#{pct}%</span>
          </div>
        HTML
      }.join

      doi_info = ""
      if cr[:total_dois] || cr[:current_dois]
        parts = []
        parts << info_card(t("total_dois"), fmt(cr[:total_dois])) if cr[:total_dois]
        parts << info_card(t("current_dois"), fmt(cr[:current_dois])) if cr[:current_dois]
        doi_info = %(<div class="dj-info-card-grid dj-coverage-dois">#{parts.compact.join}</div>) if parts.compact.any?
      end

      <<~HTML
        <section class="dj-panel dj-coverage-panel">
          <h3>#{h(t("metadata_coverage"))}</h3>
          #{doi_info}
          <div class="dj-coverage-bars">#{bars}</div>
        </section>
      HTML
    end

    def render_peer_review
      sr = @d[:scirev]
      return nil unless sr

      first_months = sr[:first_review_months]
      total_months = sr[:total_handling_months]
      return nil unless first_months || total_months

      callouts = []
      if first_months
        callouts << <<~HTML
          <div class="dj-pr-callout">
            <span class="dj-pr-number">#{format("%.1f", first_months)}</span>
            <span class="dj-pr-unit">#{h(t("pr_months"))}</span>
            <span class="dj-pr-label">#{h(t("pr_first_decision"))}</span>
          </div>
        HTML
      end
      if total_months
        callouts << <<~HTML
          <div class="dj-pr-callout">
            <span class="dj-pr-number">#{format("%.1f", total_months)}</span>
            <span class="dj-pr-unit">#{h(t("pr_months"))}</span>
            <span class="dj-pr-label">#{h(t("pr_total_handling"))}</span>
          </div>
        HTML
      end

      rating_html = ""
      if sr[:overall_rating]
        stars = SvgChartBuilder.star_rating(sr[:overall_rating])
        rating_html = %(<div class="dj-pr-rating">#{stars}<span class="dj-pr-rating-text">#{format("%.1f", sr[:overall_rating])}/5</span></div>)
      end

      meta_parts = []
      meta_parts << "#{h(t("pr_rounds"))}: #{sr[:avg_review_rounds]}" if sr[:avg_review_rounds]
      meta_parts << "#{h(t("pr_reports"))}: #{sr[:avg_review_reports]}" if sr[:avg_review_reports]
      meta_parts << "#{h(t("pr_difficulty"))}: #{h(sr[:report_difficulty])}" if sr[:report_difficulty]
      meta_parts << "#{h(t("pr_reviews"))}: #{sr[:review_count]}" if sr[:review_count]
      meta_html = meta_parts.any? ? %(<div class="dj-pr-meta">#{meta_parts.join(" · ")}</div>) : ""

      <<~HTML
        <section class="dj-panel dj-peer-review">
          <h3>#{h(t("pr_title"))}</h3>
          <div class="dj-pr-callouts">#{callouts.join}</div>
          #{rating_html}
          #{meta_html}
        </section>
      HTML
    end

    def render_topic_donut
      shares = @d.dig(:subjects_topics, :topic_shares) || []
      return nil if shares.size < 2

      segments = shares.map { |s| { value: s[:value], name: s[:name] } }
      donut_svg = SvgChartBuilder.donut(segments)
      return nil if donut_svg.blank?

      legend_items = segments.each_with_index.map { |seg, i|
        color = SvgChartBuilder::DONUT_COLORS[i % SvgChartBuilder::DONUT_COLORS.size]
        total = segments.sum { |s| s[:value].to_f }
        pct = total > 0 ? (seg[:value].to_f / total * 100).round(1) : 0
        %(<div class="dj-donut-legend-item"><span class="dj-legend-dot" style="background:#{color}"></span><span>#{h(seg[:name])} (#{pct}%)</span></div>)
      }.join

      <<~HTML
        <section class="dj-panel dj-topic-donut-panel">
          <h3>#{h(t("topic_distribution"))}</h3>
          <div class="dj-donut-layout">
            <div class="dj-donut-chart">#{donut_svg}</div>
            <div class="dj-donut-legend">#{legend_items}</div>
          </div>
        </section>
      HTML
    end

    def render_warning_timeline
      warnings = @d.dig(:warning, :data) || []
      return nil if warnings.empty?

      sorted = warnings.sort_by { |w| w[:year].to_i }

      dots = sorted.map { |w|
        level = h(w[:level])
        level_class = case w[:level]
                      when "高" then "dj-warn-dot--high"
                      when "中" then "dj-warn-dot--med"
                      else "dj-warn-dot--low"
                      end
        reason = w[:reason].present? ? %( title="#{h(w[:reason])}") : ""
        <<~HTML
          <div class="dj-warn-point">
            <span class="dj-warn-year">#{w[:year]}</span>
            <span class="dj-warn-dot #{level_class}"#{reason}></span>
            <span class="dj-warn-level">#{level}</span>
          </div>
        HTML
      }.join(%(<div class="dj-warn-line"></div>))

      <<~HTML
        <section class="dj-panel dj-warning-timeline">
          <h3>#{h(t("warning_history"))}</h3>
          <div class="dj-warn-track">#{dots}</div>
        </section>
      HTML
    end

    def render_indexing_panel
      wd_meta = @d[:wikidata_meta] || {}
      pres = @d[:preservation] || {}

      indexed_in = wd_meta[:indexed_in] || []
      pres_services = pres[:preservation_services] || []
      deposit_services = pres[:deposit_services] || []
      languages = wd_meta[:languages] || []
      editors = wd_meta[:editors] || []

      return nil if indexed_in.empty? && pres_services.empty? && deposit_services.empty? && languages.empty? && editors.empty?

      sections = []
      add_pill_row = ->(title, items) {
        return if items.empty?
        pills = items.map { |item| %(<span class="dj-pill dj-pill--index">#{h(item)}</span>) }.join
        sections << %(<div class="dj-idx-row"><span class="dj-idx-label">#{h(title)}</span><div class="dj-idx-pills">#{pills}</div></div>)
      }

      add_pill_row.call(t("idx_indexed_in"), indexed_in)
      add_pill_row.call(t("idx_preserved_by"), pres_services)
      add_pill_row.call(t("idx_deposit_policy"), deposit_services)
      add_pill_row.call(t("idx_languages"), languages)
      add_pill_row.call(t("idx_editors"), editors)

      return nil if sections.empty?

      inception = wd_meta[:inception]
      coden = wd_meta[:coden]
      extra_cards = [
        info_card(t("idx_inception"), h(inception)),
        info_card(t("idx_coden"), h(coden)),
        info_card(t("idx_frequency"), h(wd_meta[:frequency])),
      ].compact

      extra_html = extra_cards.any? ? %(<div class="dj-info-card-grid">#{extra_cards.join}</div>) : ""

      <<~HTML
        <section class="dj-panel dj-indexing-panel">
          <h3>#{h(t("idx_title"))}</h3>
          #{sections.join("\n")}
          #{extra_html}
        </section>
      HTML
    end

    def render_visual_dashboard
      charts = []

      scimago_data = (@d.dig(:scimago, :data) || []).reverse
      oa_counts = (metrics[:counts_by_year] || []).reverse
      cr_dois = (@d.dig(:crossref_quality, :dois_by_year) || []).reverse

      if scimago_data.size >= 2
        charts << viz_card(t("chart_sjr"), "#e77642",
          SvgChartBuilder.from_time_series(scimago_data, value_key: :sjr, color: "#e77642"),
          data: scimago_data, value_key: :sjr)
        charts << viz_card(t("chart_total_docs"), "#7ac36a",
          SvgChartBuilder.from_time_series(scimago_data, value_key: :total_docs_year, color: "#7ac36a"),
          data: scimago_data, value_key: :total_docs_year)
        charts << viz_card(t("chart_cites_per_doc"), "#3885c8",
          SvgChartBuilder.from_time_series(scimago_data, value_key: :citations_per_doc_2years, color: "#3885c8"),
          data: scimago_data, value_key: :citations_per_doc_2years)
        charts << viz_card(t("chart_female_pct"), "#7ac36a",
          SvgChartBuilder.from_time_series(scimago_data, value_key: :female_pct, color: "#7ac36a"),
          data: scimago_data, value_key: :female_pct)
        charts << viz_card(t("chart_refs_per_doc"), "#3885c8",
          SvgChartBuilder.from_time_series(scimago_data, value_key: :ref_per_doc, color: "#3885c8"),
          data: scimago_data, value_key: :ref_per_doc)
        charts << viz_card(t("chart_policy_docs"), "#7ac36a",
          SvgChartBuilder.from_time_series(scimago_data, value_key: :overton, color: "#7ac36a"),
          data: scimago_data, value_key: :overton)
        charts << viz_card(t("chart_sdg_docs"), "#7ac36a",
          SvgChartBuilder.from_time_series(scimago_data, value_key: :sdg, color: "#7ac36a"),
          data: scimago_data, value_key: :sdg)
      end

      if oa_counts.size >= 2
        charts << viz_card(t("chart_annual_citations"), "#3885c8",
          SvgChartBuilder.from_time_series(oa_counts, value_key: :cited_by_count, color: "#3885c8"),
          data: oa_counts, value_key: :cited_by_count)
        charts << viz_card(t("chart_works_vs_oa"), nil,
          SvgChartBuilder.area_from_time_series(oa_counts, key_a: :works_count, key_b: :oa_works_count),
          data: oa_counts, value_keys: [:works_count, :oa_works_count],
          legends: [["#7ac36a", t("legend_works")], ["#3885c8", t("legend_oa_works")]])
        charts << viz_card_wide(t("chart_total_citations_wide"), "#3885c8",
          SvgChartBuilder.from_time_series(oa_counts, value_key: :cited_by_count, color: "#3885c8",
            width: SvgChartBuilder::WIDE_W, height: SvgChartBuilder::WIDE_H),
          data: oa_counts, value_key: :cited_by_count)
      end

      if cr_dois.size >= 2
        charts << viz_card(t("chart_dois_by_year"), "#7ac36a",
          SvgChartBuilder.from_time_series(cr_dois, value_key: :count, color: "#7ac36a"),
          data: cr_dois, value_key: :count)
      end

      if oa_counts.size >= 2
        charts << viz_card(t("chart_oa_works_trend"), "#3885c8",
          SvgChartBuilder.from_time_series(oa_counts, value_key: :oa_works_count, color: "#3885c8"),
          data: oa_counts, value_key: :oa_works_count)
      end

      jcr_data = (@d.dig(:jcr, :data) || []).select { |j| j[:impact_factor] }.reverse
      if jcr_data.size >= 2
        charts << viz_card(t("chart_jcr_if"), "#e77642",
          SvgChartBuilder.from_time_series(jcr_data, value_key: :impact_factor, color: "#e77642"),
          data: jcr_data, value_key: :impact_factor)
      end

      return nil if charts.empty?

      <<~HTML
        <section class="dj-panel dj-visual-dashboard">
          <header class="dj-viz-header"><h3>#{h(t("chart_insights"))}</h3></header>
          <div class="dj-viz-grid">#{charts.compact.join("\n")}</div>
        </section>
      HTML
    end

    def next_toggle_id
      @toggle_id += 1
      "dj-toggle-#{@toggle_id}"
    end

    def toggle_icon_svg
      '<svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor" xmlns="http://www.w3.org/2000/svg">' \
        '<rect x="1" y="1" width="4" height="4" rx="0.5" opacity="0.7"/>' \
        '<rect x="6" y="1" width="4" height="4" rx="0.5" opacity="0.7"/>' \
        '<rect x="11" y="1" width="4" height="4" rx="0.5" opacity="0.7"/>' \
        '<rect x="1" y="6" width="4" height="4" rx="0.5" opacity="0.7"/>' \
        '<rect x="6" y="6" width="4" height="4" rx="0.5" opacity="0.7"/>' \
        '<rect x="11" y="6" width="4" height="4" rx="0.5" opacity="0.7"/>' \
        '<rect x="1" y="11" width="4" height="4" rx="0.5" opacity="0.7"/>' \
        '<rect x="6" y="11" width="4" height="4" rx="0.5" opacity="0.7"/>' \
        '<rect x="11" y="11" width="4" height="4" rx="0.5" opacity="0.7"/>' \
      '</svg>'
    end

    COLUMN_I18N_MAP = {
      sjr: "col_sjr",
      total_docs_year: "col_total_docs",
      citations_per_doc_2years: "col_cites_per_doc",
      female_pct: "col_female_pct",
      ref_per_doc: "col_refs_per_doc",
      overton: "col_policy_docs",
      sdg: "col_sdg_docs",
      cited_by_count: "col_citations",
      works_count: "col_works",
      oa_works_count: "col_oa_works",
      count: "col_count",
      impact_factor: "col_impact_factor",
    }.freeze

    def build_table(data, value_key: nil, value_keys: nil)
      return "" if data.nil? || data.empty?
      keys = value_keys || [value_key].compact
      return "" if keys.empty?

      header_cells = keys.map { |k|
        i18n_key = COLUMN_I18N_MAP[k]
        label = i18n_key ? t(i18n_key) : k.to_s.tr("_", " ").capitalize
        "<th>#{h(label)}</th>"
      }.join
      rows = data.map { |d|
        yr = h(d[:year])
        cells = keys.map { |k| "<td>#{h(d[k])}</td>" }.join
        "<tr><td>#{yr}</td>#{cells}</tr>"
      }.join

      <<~HTML
        <div class="dj-viz-table"><table>
          <thead><tr><th>#{t("year")}</th>#{header_cells}</tr></thead>
          <tbody>#{rows}</tbody>
        </table></div>
      HTML
    end

    def viz_card(title, dot_color, svg, data: nil, value_key: nil, value_keys: nil, legends: nil)
      return nil if svg.blank?
      dot = dot_color ? %(<span class="dj-legend-dot" style="background:#{dot_color}"></span>) : ""
      legend_html = if legends
        legends.map { |c, l| %(<span class="dj-legend-dot" style="background:#{c}"></span>#{h(l)}) }.join(" ")
      else
        ""
      end
      title_content = legends ? legend_html : "#{dot}#{h(title)}"

      tid = next_toggle_id
      table_html = build_table(data, value_key: value_key, value_keys: value_keys)
      input_html = table_html.present? ? %(<input type="checkbox" class="dj-viz-toggle-input" id="#{tid}" />) : ""
      label_html = table_html.present? ? %(<label for="#{tid}" class="dj-viz-toggle-label" title="#{h(t("toggle_chart_table"))}">#{toggle_icon_svg}</label>) : ""

      <<~HTML
        <article class="dj-viz-card">
          #{input_html}
          <div class="dj-viz-card__header">
            <div class="dj-viz-title">#{title_content}</div>
            #{label_html}
          </div>
          <div class="dj-viz-chart">#{svg}</div>
          #{table_html}
        </article>
      HTML
    end

    def viz_card_wide(title, dot_color, svg, data: nil, value_key: nil, value_keys: nil)
      return nil if svg.blank?
      dot = dot_color ? %(<span class="dj-legend-dot" style="background:#{dot_color}"></span>) : ""

      tid = next_toggle_id
      table_html = build_table(data, value_key: value_key, value_keys: value_keys)
      input_html = table_html.present? ? %(<input type="checkbox" class="dj-viz-toggle-input" id="#{tid}" />) : ""
      label_html = table_html.present? ? %(<label for="#{tid}" class="dj-viz-toggle-label" title="#{h(t("toggle_chart_table"))}">#{toggle_icon_svg}</label>) : ""

      <<~HTML
        <article class="dj-viz-card dj-viz-card--wide">
          #{input_html}
          <div class="dj-viz-card__header">
            <div class="dj-viz-title">#{dot}#{h(title)}</div>
            #{label_html}
          </div>
          <div class="dj-viz-chart">#{svg}</div>
          #{table_html}
        </article>
      HTML
    end

    def hero_footer(publisher, publisher_id, homepage, homepage_link, country_name, country_code)
      items = []
      if publisher.present?
        pub_text = "#{publisher}#{" (#{publisher_id})" if publisher_id.present?}"
        items << %(<div><span class="dj-label">#{h(t("publisher"))}</span><strong>#{pub_text}</strong></div>)
      end
      if homepage.present?
        items << %(<div><span class="dj-label">#{h(t("homepage"))}</span>#{homepage_link}</div>)
      end
      if country_name.present? || country_code.present?
        items << %(<div><span class="dj-label">#{h(t("country"))}</span><strong>#{country_name.present? ? country_name : country_code}</strong></div>)
      end
      return "" if items.empty?
      %(<div class="dj-hero__footer">#{items.join}</div>)
    end

    def info_card(label, value)
      return nil if value.blank? || value == "—"
      <<~HTML
        <article class="dj-info-card">
          <p class="dj-info-card__label">#{h(label)}</p>
          <p class="dj-info-card__value">#{value}</p>
        </article>
      HTML
    end

    def status_check_svg
      '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" xmlns="http://www.w3.org/2000/svg"><circle cx="8" cy="8" r="7" fill="currentColor" opacity="0.12"/><path d="M5 8l2 2 4-4" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/></svg>'
    end

    def status_cross_svg
      '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" xmlns="http://www.w3.org/2000/svg"><circle cx="8" cy="8" r="7" fill="currentColor" opacity="0.06"/><path d="M5.5 5.5l5 5M10.5 5.5l-5 5" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" opacity="0.4"/></svg>'
    end

    def cas_yn_to_bool(val)
      return nil if val.nil? || val.to_s.strip.empty?
      val.to_s.strip == "是"
    end

    def extract_cas_zone(quartile_str)
      return nil if quartile_str.blank?
      match = quartile_str.to_s.match(/(\d+)/)
      match ? match[1] : nil
    end

    STOP_WORDS = Set.new(%w[of the and in for on a an to with]).freeze

    def extract_initials(title)
      return "?" if title.blank?
      words = title.split(/[\s\-\/]+/).reject { |w| STOP_WORDS.include?(w.downcase) }
      initials = words.filter_map { |w| w[0]&.upcase if w.match?(/\A[A-Za-z]/) }
      result = initials.first(6).join
      result.present? ? result : title[0..1].upcase
    end
  end
end
