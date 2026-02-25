# frozen_string_literal: true

module DiscourseJournals
  class MasterRecordRenderer
    API_COVER_BASE = "https://journal.scholay.com"

    def initialize(normalized_data)
      @d = normalized_data.is_a?(Hash) ? normalized_data : {}
    end

    def render
      sections = []
      sections << render_hero
      sections << render_metric_visuals
      sections << render_stats_narrative
      sections << render_compact_info
      sections << render_topic_cloud
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
      return "—" if num.nil?
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
      oa_type = h(id[:openalex_type]).presence || "journal"
      oa_id = h(id[:openalex_id])
      issn_l = h(id[:issn_l])

      cover_html = if cover_url
        %(<img src="#{h(cover_url)}" alt="#{title}" loading="lazy" onerror="this.style.display='none';this.nextElementSibling.style.display='flex'" />) +
        %(<div class="dj-hero__cover-art" style="display:none"><span class="dj-cover-code">#{abbrev}</span></div>)
      else
        %(<div class="dj-hero__cover-art"><span class="dj-cover-code">#{abbrev.present? ? abbrev : title[0..3]}</span></div>)
      end

      homepage_display = homepage.present? ? homepage.sub(%r{https?://}, "").sub(/\/\z/, "") : nil
      homepage_link = homepage.present? ? %(<a href="#{h(homepage)}" target="_blank" rel="noopener">#{h(homepage_display)}</a>) : "—"

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
            <div class="dj-hero__footer">
              <div><span class="dj-label">#{h(t("publisher"))}</span><strong>#{publisher}#{" (#{publisher_id})" if publisher_id.present?}</strong></div>
              <div><span class="dj-label">#{h(t("homepage"))}</span>#{homepage_link}</div>
              <div><span class="dj-label">#{h(t("country"))}</span><strong>#{country_name.present? ? country_name : country_code}</strong></div>
            </div>
          </div>
        </header>
      HTML
    end

    def render_metric_visuals
      jcr_latest = @d.dig(:jcr, :data)&.first
      sjr_latest = @d.dig(:scimago, :data)&.first
      cas_latest = @d.dig(:cas_partition, :data)&.first
      warn_latest = @d.dig(:warning, :data)&.first

      return nil unless jcr_latest || sjr_latest || cas_latest

      jcr_card = render_jcr_card(jcr_latest) if jcr_latest
      sjr_card = render_sjr_card(sjr_latest) if sjr_latest
      cas_card = render_cas_card(cas_latest, jcr_latest, warn_latest) if cas_latest

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
        parts << t("narrative_jcr", quartile: jcr[:quartile], impact: jcr[:impact_factor], year: jcr[:year])
      end
      if sjr && sjr[:sjr]
        parts << t("narrative_sjr", quartile: sjr[:best_quartile], sjr: format("%.3f", sjr[:sjr]))
      end
      if cas
        zone = extract_cas_zone(cas[:major_quartile])
        parts << t("narrative_cas", zone: zone, category: cas[:major_category]) if zone
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

      issns = (id[:issn_details] || []).map { |d| h(d[:issn]) }.join(", ")
      alternates = (id[:alternate_titles] || []).map { |t_val| h(t_val) }.join(", ")

      yes_val = t("yes")
      no_val = t("no")

      basic_cards = [
        info_card("ISSN-L", h(id[:issn_l])),
        info_card(t("issns"), issns.present? ? issns : "—"),
        info_card(t("aliases"), alternates.present? ? alternates : "—"),
        info_card(t("oa"), oa[:is_oa] ? yes_val : no_val),
        info_card(t("doaj"), oa[:is_in_doaj] ? yes_val : no_val),
        info_card(t("openalex_id"), h(id[:openalex_id])),
      ]

      oa_cards = [
        info_card(t("name"), h(id[:title])),
        info_card(t("type"), h(id[:openalex_type])),
        info_card(t("publisher"), h(pub[:publisher_name])),
        info_card(t("country"), h(pub[:country_name] || pub[:country_code])),
        info_card(t("works"), fmt(m[:works_count])),
        info_card(t("cited_by"), fmt(m[:cited_by_count])),
        info_card(t("oa_works"), fmt(m[:oa_works_count])),
        info_card(t("first_year"), pub[:first_publication_year] || "—"),
        info_card(t("last_year"), pub[:last_publication_year] || "—"),
        info_card(t("open_access"), oa[:is_oa] ? yes_val : no_val),
      ]

      <<~HTML
        <section class="dj-panel dj-compact-info">
          <div class="dj-info-group">
            <div class="dj-info-group__title">#{h(t("basic_info"))}</div>
            <div class="dj-info-card-grid">#{basic_cards.join}</div>
          </div>
          <div class="dj-info-group">
            <div class="dj-info-group__title">#{h(t("openalex_data"))}</div>
            <div class="dj-info-card-grid">#{oa_cards.join}</div>
          </div>
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

    def render_visual_dashboard
      charts = []

      scimago_data = (@d.dig(:scimago, :data) || []).reverse
      oa_counts = (metrics[:counts_by_year] || []).reverse
      cr_dois = (@d.dig(:crossref_quality, :dois_by_year) || []).reverse

      if scimago_data.size >= 2
        charts << viz_card(t("chart_sjr"), "#e77642", SvgChartBuilder.from_time_series(scimago_data, value_key: :sjr, color: "#e77642"))
        charts << viz_card(t("chart_total_docs"), "#7ac36a", SvgChartBuilder.from_time_series(scimago_data, value_key: :total_docs_year, color: "#7ac36a"))
        charts << viz_card(t("chart_cites_per_doc"), "#3885c8", SvgChartBuilder.from_time_series(scimago_data, value_key: :citations_per_doc_2years, color: "#3885c8"))
        charts << viz_card(t("chart_female_pct"), "#7ac36a", SvgChartBuilder.from_time_series(scimago_data, value_key: :female_pct, color: "#7ac36a"))
        charts << viz_card(t("chart_refs_per_doc"), "#3885c8", SvgChartBuilder.from_time_series(scimago_data, value_key: :ref_per_doc, color: "#3885c8"))
        charts << viz_card(t("chart_policy_docs"), "#7ac36a", SvgChartBuilder.from_time_series(scimago_data, value_key: :overton, color: "#7ac36a"))
        charts << viz_card(t("chart_sdg_docs"), "#7ac36a", SvgChartBuilder.from_time_series(scimago_data, value_key: :sdg, color: "#7ac36a"))
      end

      if oa_counts.size >= 2
        charts << viz_card(t("chart_annual_citations"), "#3885c8", SvgChartBuilder.from_time_series(oa_counts, value_key: :cited_by_count, color: "#3885c8"))
        charts << viz_card(t("chart_works_vs_oa"), nil,
          SvgChartBuilder.area_from_time_series(oa_counts, key_a: :works_count, key_b: :oa_works_count),
          legends: [["#7ac36a", t("legend_works")], ["#3885c8", t("legend_oa_works")]])
        charts << viz_card_wide(t("chart_total_citations_wide"), "#3885c8",
          SvgChartBuilder.from_time_series(oa_counts, value_key: :cited_by_count, color: "#3885c8",
            width: SvgChartBuilder::WIDE_W, height: SvgChartBuilder::WIDE_H))
      end

      if cr_dois.size >= 2
        charts << viz_card(t("chart_dois_by_year"), "#7ac36a", SvgChartBuilder.from_time_series(cr_dois, value_key: :count, color: "#7ac36a"))
      end

      if oa_counts.size >= 2
        charts << viz_card(t("chart_oa_works_trend"), "#3885c8", SvgChartBuilder.from_time_series(oa_counts, value_key: :oa_works_count, color: "#3885c8"))
      end

      return nil if charts.empty?

      <<~HTML
        <section class="dj-panel dj-visual-dashboard">
          <header class="dj-viz-header"><h3>#{h(t("chart_insights"))}</h3></header>
          <div class="dj-viz-grid">#{charts.compact.join("\n")}</div>
        </section>
      HTML
    end

    def viz_card(title, dot_color, svg, legends: nil)
      return nil if svg.blank?
      dot = dot_color ? %(<span class="dj-legend-dot" style="background:#{dot_color}"></span>) : ""
      legend_html = if legends
        legends.map { |c, l| %(<span class="dj-legend-dot" style="background:#{c}"></span>#{h(l)}) }.join(" ")
      else
        ""
      end
      title_content = legends ? legend_html : "#{dot}#{h(title)}"

      <<~HTML
        <article class="dj-viz-card">
          <div class="dj-viz-card__header"><div class="dj-viz-title">#{title_content}</div></div>
          <div class="dj-viz-chart">#{svg}</div>
        </article>
      HTML
    end

    def viz_card_wide(title, dot_color, svg)
      return nil if svg.blank?
      dot = dot_color ? %(<span class="dj-legend-dot" style="background:#{dot_color}"></span>) : ""

      <<~HTML
        <article class="dj-viz-card dj-viz-card--wide">
          <div class="dj-viz-card__header"><div class="dj-viz-title">#{dot}#{h(title)}</div></div>
          <div class="dj-viz-chart">#{svg}</div>
        </article>
      HTML
    end

    def info_card(label, value)
      <<~HTML
        <article class="dj-info-card">
          <p class="dj-info-card__label">#{h(label)}</p>
          <p class="dj-info-card__value">#{value || "—"}</p>
        </article>
      HTML
    end

    def extract_cas_zone(quartile_str)
      return nil if quartile_str.blank?
      match = quartile_str.to_s.match(/(\d+)/)
      match ? match[1] : nil
    end
  end
end
