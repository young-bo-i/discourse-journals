# frozen_string_literal: true

module DiscourseJournals
  # Renders a journal's normalized JSON into the cooked HTML of its first post.
  #
  # The output bypasses Discourse's sanitizer (see README), so every value that
  # comes from upstream data must go through `h`. Interpolated I18n strings are
  # escaped as a whole after interpolation; none of the templates contain markup.
  class MasterRecordRenderer
    # Bump when the markup changes in a way the stylesheet depends on;
    # Jobs::DiscourseJournals::RerenderLayout then rewrites every journal post.
    LAYOUT_VERSION = 2

    SECTIONS = {
      rankings: "nav_rankings",
      reviews: "nav_reviews",
      submission: "nav_submission",
      open_access: "nav_open_access",
      impact: "nav_impact",
      topics: "nav_topics",
      profile: "nav_profile",
    }.freeze

    MAX_KEY_FIGURES = 6
    MAX_TABLE_ROWS = 12
    HISTORY_YEARS = 6
    # A warning-list entry this many years older than the data build is shown
    # as history rather than as a current alert.
    WARNING_CURRENT_WINDOW = 2

    OUTCOMES = %w[
      accepted
      accepted_after_revision
      revision
      under_review
      submitted
      rejected
      desk_rejected
      withdrawn
      unknown
    ].freeze

    REVIEW_DIMENSIONS = [
      [:quality, "rv_quality"],
      [:speed, "rv_speed"],
      [:communication, "rv_communication"],
      [:cost, "rv_cost"],
      [:difficulty, "rv_difficulty", "dj-warnc"],
    ].freeze

    REVIEW_RATES = [
      [:acceptance_rate, "rv_rate_acceptance", "dj-good"],
      [:rejection_rate, "rv_rate_rejection", "dj-bad"],
      [:desk_reject_rate, "rv_rate_desk_reject", "dj-bad"],
      [:revision_rate, "rv_rate_revision", "dj-t3"],
    ].freeze

    PEER_REVIEW_KEYS = {
      "single_blind" => "peer_single_blind",
      "double_blind" => "peer_double_blind",
      "open" => "peer_open",
      "Single anonymous peer review" => "peer_single_blind",
      "Double anonymous peer review" => "peer_double_blind",
      "Open peer review" => "peer_open",
      "Editorial review" => "peer_editorial",
      "Committee review" => "peer_committee",
    }.freeze

    REFERENCE_STYLES = {
      "vancouver" => "Vancouver",
      "apa" => "APA",
      "harvard" => "Harvard",
      "ieee" => "IEEE",
      "ama" => "AMA",
      "chicago" => "Chicago",
      "mla" => "MLA",
      "nature" => "Nature",
    }.freeze

    INTEXT_KEYS = {
      "superscript" => "intext_superscript",
      "numbered" => "intext_numbered",
      "author_year" => "intext_author_year",
    }.freeze

    FREQUENCY_UNITS = %w[day week month year].freeze

    SOURCE_KEYS = %w[
      crossref
      openalex
      doaj
      wikidata
      scimago
      jcr
      fqb
      ccf
      gjqk
      xr
      jufo
      cwts
      submission
      comments
    ].freeze

    ICON_EXTERNAL =
      '<svg class="dj-icon" viewBox="0 0 16 16" aria-hidden="true"><path d="M6.5 3.5H3.5a1 1 0 0 0-1 1v8a1 1 0 0 0 1 1h8a1 1 0 0 0 1-1v-3"/><path d="M9.5 2.5h4v4"/><path d="M13.5 2.5 7.5 8.5"/></svg>'
    ICON_DOWNLOAD =
      '<svg class="dj-icon" viewBox="0 0 16 16" aria-hidden="true"><path d="M8 2.5v8"/><path d="m4.5 7 3.5 3.5L11.5 7"/><path d="M3 13.5h10"/></svg>'
    ICON_WARNING =
      '<svg class="dj-icon dj-alert__icon" viewBox="0 0 16 16" aria-hidden="true"><path d="M8 2 1.5 13.5h13Z"/><path d="M8 6.5v3.2"/><path d="M8 11.6v.1"/></svg>'

    def initialize(normalized_data, category: nil)
      @d = normalized_data.is_a?(Hash) ? normalized_data : {}
      @category = category
    end

    def render(outdated: false)
      sections =
        SECTIONS
          .keys
          .filter_map { |key| [key, send(:"render_#{key}")] }
          .select { |_, html| html.present? }

      parts = []
      parts << render_outdated_notice if outdated
      parts << render_crumbs
      parts << render_hero
      parts << render_alert
      parts << render_key_figures
      parts << render_summary
      parts << render_toc(sections.map(&:first))
      parts.concat(sections.map(&:last))
      parts << render_footer

      %(<article class="dj-journal">\n#{parts.compact.join("\n")}\n</article>)
    end

    def render_plain_text
      id = identity
      jcr = latest(:jcr)
      parts = [id[:title], "ISSN-L: #{id[:issn_l]}"]
      parts << "#{t("publisher")}: #{publication[:publisher_name]}" if publication[:publisher_name]
      parts << "IF: #{jcr[:impact_factor]} (#{jcr[:year]})" if jcr&.dig(:impact_factor)
      parts << "#{t("works")}: #{metrics[:works_count]}" if metrics[:works_count]
      parts << "#{t("cited_by")}: #{metrics[:cited_by_count]}" if metrics[:cited_by_count]
      parts << "SNIP: #{format("%.3f", metrics[:snip])}" if metrics[:snip]
      rv = @d[:reviews]
      if rv&.dig(:rating)
        parts << "#{t("rv_title")}: #{format("%.1f", rv[:rating])}/5 (#{rv[:count]})"
      end
      parts.compact.join(" | ")
    end

    def render_seo_excerpt
      id = identity
      oa = @d[:open_access] || {}
      jcr = latest(:jcr)
      sjr = latest(:scimago)

      title = id[:title] || t("unknown_journal")
      sentences = []

      publisher_part =
        (
          if publication[:publisher_name].present?
            t("seo_published_by", publisher: publication[:publisher_name])
          else
            ""
          end
        )
      issn_part = id[:issn_l].present? ? "ISSN: #{id[:issn_l]}" : ""
      intro_parts = [publisher_part, issn_part].reject(&:blank?)
      sentences << "#{title}#{intro_parts.any? ? ", #{intro_parts.join(", ")}" : ""}"

      metrics_parts = []
      if jcr&.dig(:impact_factor)
        metrics_parts << t("seo_if", value: jcr[:impact_factor], year: jcr[:year])
      end
      metrics_parts << "SJR #{sjr[:best_quartile]}" if sjr&.dig(:best_quartile)
      sentences << metrics_parts.join(", ") if metrics_parts.any?

      stats_parts = []
      stats_parts << t("seo_works", count: fmt(metrics[:works_count])) if metrics[:works_count]
      if metrics[:cited_by_count]
        stats_parts << t("seo_citations", count: fmt(metrics[:cited_by_count]))
      end
      stats_parts << t("seo_h_index", value: metrics[:h_index]) if metrics[:h_index]
      sentences << stats_parts.join(", ") if stats_parts.any?

      sentences << t("seo_oa_yes") if oa[:is_oa]

      rv = @d[:reviews]
      if rv&.dig(:rating) && rv[:count].to_i.positive?
        sentences << t("seo_reviews", rating: format("%.1f", rv[:rating]), count: fmt(rv[:count]))
      end

      result = sentences.join(". ").strip
      result += "." unless result.end_with?(".")
      result.truncate(300)
    end

    def self.cached_translations
      locale = I18n.locale
      @_i18n_cache = {} if !defined?(@_i18n_cache) || @_i18n_cache.nil?
      @_i18n_cache[locale] ||= {}
    end

    def self.reset_i18n_cache!
      @_i18n_cache = nil
    end

    private

    # ── Data access ──────────────────────────────────────────────

    def identity
      @d[:identity] || {}
    end

    def publication
      @d[:publication] || {}
    end

    def metrics
      @d[:metrics] || {}
    end

    def wikidata
      @d[:wikidata_meta] || {}
    end

    def latest(key)
      key = :cas_partition if key == :cas
      key = :xinrui_partition if key == :xinrui
      (@d.dig(key, :data) || []).first
    end

    def build_year
      year = @d.dig(:provenance, :built_at).to_s[0, 4].to_i
      year.positive? ? year : Time.current.year
    end

    def tag_assignments
      return {} unless SiteSetting.tagging_enabled
      @tag_assignments ||= JournalTagManager.build_tag_assignments(@d)
    rescue StandardError
      @tag_assignments = {}
    end

    def tag_name(group)
      tag_assignments[group]&.first
    end

    # ── Formatting helpers ───────────────────────────────────────

    def t(key, **opts)
      if opts.empty?
        self.class.cached_translations[key] ||= I18n.t("discourse_journals.render.#{key}")
      else
        I18n.t("discourse_journals.render.#{key}", **opts)
      end
    end

    # A plain String, not a SafeBuffer: appending markup to a SafeBuffer would
    # escape that markup again.
    def h(text)
      return "" if text.nil?
      String.new(ERB::Util.html_escape(text.to_s))
    end

    def fmt(num)
      return nil if num.nil?
      # Group thousands on the integer part only. A naive reverse-gsub over the
      # whole string mangles decimals ("1234.56" -> "123,4.56").
      int, frac = num.to_s.split(".", 2)
      grouped = int.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse
      frac ? "#{grouped}.#{frac}" : grouped
    end

    def decimal(value, digits)
      return nil if value.nil?
      format("%.#{digits}f", value.to_f)
    end

    def percent(ratio, digits = 1)
      return nil if ratio.nil?
      value = (ratio.to_f * 100).round(digits)
      "#{value == value.to_i ? value.to_i : value}%"
    end

    def yes?(value)
      return false if value.nil?
      value == true || value == 1 || %w[是 yes true 1 top].include?(value.to_s.strip.downcase)
    end

    def zone_of(value)
      value.to_s[/\d/]&.to_i&.then { |z| (1..4).cover?(z) ? z : nil }
    end

    def rank_in(value)
      value.to_s[%r{\[(\d+/\d+)\]}, 1]
    end

    def quartile_tier(value)
      value.to_s.upcase[/Q([1-4])/, 1]&.to_i
    end

    def ccf_tier(rank)
      { "A" => 1, "B" => 2, "C" => 3 }[rank.to_s.strip[0]&.upcase]
    end

    def t_rank_tier(t_rank)
      { "T1" => 1, "T2" => 2, "T3" => 3 }[t_rank.to_s.strip.upcase]
    end

    def tier_class(tier)
      tier ? "dj-t#{tier}" : ""
    end

    # Canonical /tag/:slug/:id when the tag cache is warm (sync and rerender
    # runs warm it); otherwise the by-name route, which redirects there.
    def tag_href(name)
      JournalTagManager.cached_tag(name)&.url ||
        "#{Discourse.base_path}/tag/#{UrlHelper.encode_component(name)}"
    end

    # Wraps already-escaped markup in a link to the journal's tag page, which
    # replaces the topic tag list hidden on journal pages.
    def tag_link(group, inner_html, css = nil)
      name = tag_name(group)
      return inner_html if name.blank?
      %(<a class="#{["dj-taglink", css].compact.join(" ")}" href="#{h(tag_href(name))}">#{inner_html}</a>)
    end

    def chip(inner_html, css = nil)
      %(<span class="#{["dj-chip", css].compact.join(" ")}">#{inner_html}</span>)
    end

    def chips(values, css = nil)
      values.map { |value| chip(h(value), css) }.join
    end

    def external_link(href, label, css = "dj-btn")
      %(<a class="#{css}" href="#{h(href)}" target="_blank" rel="noopener nofollow">#{ICON_EXTERNAL}<span>#{h(label)}</span></a>)
    end

    def section(key, body, meta: nil)
      head = %(<h3 class="dj-section__title">#{h(t(SECTIONS[key]))}</h3>)
      head += %(<span class="dj-section__meta">#{meta}</span>) if meta.present?
      <<~HTML
        <section class="dj-section dj-section--#{key.to_s.tr("_", "-")}" id="dj-nav-#{key.to_s.tr("_", "-")}" data-dj-nav="#{h(t(SECTIONS[key]))}">
          <div class="dj-section__head">#{head}</div>
          #{body}
        </section>
      HTML
    end

    def dl(items, css = nil)
      return "" if items.empty?
      rows = items.map { |label, value| %(<div><dt>#{h(label)}</dt><dd>#{value}</dd></div>) }.join
      %(<dl class="#{["dj-dl", css].compact.join(" ")}">#{rows}</dl>)
    end

    def scale(tier, steps, ends)
      return "" unless tier
      cells = (1..steps).map { |i| %(<span#{' class="is-on"' if i == tier}></span>) }.join
      label = t("scale_label", tier: tier, steps: steps)
      %(<div class="dj-scale #{tier_class(tier)}" style="--steps: #{steps}" role="img" aria-label="#{h(label)}">#{cells}</div>) +
        %(<div class="dj-scale__ends"><span>#{h(ends[0])}</span><span>#{h(ends[1])}</span></div>)
    end

    # Wikidata's short name is sometimes the English title of a Chinese journal,
    # which is no abbreviation.
    def abbreviation?
      abbreviation = identity[:abbreviation].to_s
      title = identity[:title].to_s
      abbreviation.present? && abbreviation != title && abbreviation.length < title.length
    end

    def cjk_gap(text)
      text.to_s.match?(/[\p{Han}）」』]\z/) ? "" : " "
    end

    # ── Page parts ───────────────────────────────────────────────

    def render_outdated_notice
      %(<div class="dj-outdated-notice" role="alert"><span class="dj-outdated-notice__icon">&#x26A0;</span><span class="dj-outdated-notice__text">#{h(t("outdated_notice"))}</span></div>)
    end

    def render_crumbs
      items = []
      items << %(<a href="#{h(@category.url)}">#{h(@category.name)}</a>) if @category
      subject = tag_name(:subject)
      items << %(<a href="#{h(tag_href(subject))}">#{h(subject)}</a>) if subject
      return nil if items.empty?

      separator = %(<span class="dj-crumbs__sep" aria-hidden="true">›</span>)
      %(<nav class="dj-crumbs" aria-label="#{h(t("crumbs_label"))}">#{items.join(separator)}</nav>)
    end

    def render_hero
      id = identity
      pub = publication
      title = id[:title].presence || t("unknown_journal")

      eyebrow = [pub[:publisher_name], pub[:country_name].presence || pub[:country_code]].select(
        &:present?
      )
      alt = []
      alt << %(<span>#{h(id[:title_zh])}</span>) if id[:title_zh].present?
      if id[:abbreviation].present? && id[:abbreviation] != title
        alt << %(<span>#{h(abbreviation? ? t("hero_abbreviation", value: id[:abbreviation]) : id[:abbreviation])}</span>)
      end
      alt << %(<span>#{h(id[:subtitle])}</span>) if id[:subtitle].present?

      ids = []
      ids << [t("issn_l"), id[:issn_l]] if id[:issn_l].present?
      if id[:print_issn].present? && id[:print_issn] != id[:issn_l]
        ids << [t("print_issn"), id[:print_issn]]
      end
      if id[:electronic_issn].present? && id[:electronic_issn] != id[:issn_l]
        ids << [t("electronic_issn"), id[:electronic_issn]]
      end
      ids << [t("cn_number"), id[:cn_number]] if id[:cn_number].present?
      ids_html = ids.map { |label, value| %(<li><span>#{h(label)}</span>#{h(value)}</li>) }.join

      badges = hero_badges
      links = hero_links

      <<~HTML
        <header class="dj-hero" id="dj-nav-hero" data-dj-nav="#{h(t("nav_overview"))}">
          #{render_cover(title)}
          <div class="dj-hero__body">
            #{%(<p class="dj-hero__eyebrow">#{eyebrow.map { |v| h(v) }.join(" · ")}</p>) if eyebrow.any?}
            <h2 class="dj-hero__title">#{h(title)}</h2>
            #{%(<p class="dj-hero__alt">#{alt.join}</p>) if alt.any?}
            #{%(<ul class="dj-hero__ids">#{ids_html}</ul>) if ids.any?}
            #{%(<div class="dj-hero__badges">#{badges.join}</div>) if badges.any?}
            #{%(<div class="dj-hero__links">#{links.join}</div>) if links.any?}
          </div>
        </header>
      HTML
    end

    # The initials art is the sized backdrop; a cover image is layered on top
    # and simply reveals the art if it fails to load (no inline onerror JS,
    # which the default CSP blocks anyway).
    def render_cover(title)
      cover_url = CoverUrl.displayable(CoverUrl.absolute(identity[:cover_url]))
      img =
        (
          if cover_url
            %(<img class="dj-cover__img" src="#{h(cover_url)}" alt="" loading="lazy" />)
          else
            ""
          end
        )
      %(<div class="dj-cover"><span class="dj-cover__mark" aria-hidden="true">#{h(initials(title))}</span><span class="dj-cover__name" aria-hidden="true">#{h(title)}</span>#{img}</div>)
    end

    def hero_badges
      oa = @d[:open_access] || {}
      cas = latest(:cas)
      jcr = latest(:jcr)
      badges = []

      model = oa_model(oa)
      if model
        css = %w[diamond gold free].include?(model) ? "dj-chip--tone dj-good" : nil
        badges << tag_link(:oa_status, chip(h(t("oa_model_#{model}")), css))
      end
      if oa[:is_in_doaj]
        badges << tag_link(:doaj, chip(h(t("badge_doaj")), "dj-chip--tone dj-good"))
      end

      wos = cas&.dig(:web_of_science).presence || jcr&.dig(:web_of_science).presence
      badges << tag_link(:wos_index, chip(h(wos), "dj-chip--tone dj-accent")) if wos
      if yes?(cas&.dig(:top))
        badges << tag_link(:cas_top, chip(h(t("badge_cas_top")), "dj-chip--tone dj-t1"))
      end
      badges << chip(h(t("badge_review_journal"))) if yes?(cas&.dig(:review))
      badges << chip(h(cas[:annotation])) if cas&.dig(:annotation).present?
      badges << chip(h(t("badge_preprint"))) if publication[:is_preprint_repository]
      badges
    end

    def hero_links
      id = identity
      sub = @d[:submission] || {}
      links = []
      links << external_link(id[:homepage_url], t("link_homepage")) if id[:homepage_url].present?
      if sub[:submission_system_url].present?
        links << external_link(
          sub[:submission_system_url],
          t("link_submit"),
          "dj-btn dj-btn--primary",
        )
      end
      links.concat(download_links(sub))
      links
    end

    # Both downloads sit behind the upstream API key, so they go through the
    # plugin's proxy route rather than linking upstream directly.
    def download_links(sub, guideline_label: "link_guideline", latex_label: "link_latex")
      return [] unless SiteSetting.discourse_journals_submission_proxy_enabled
      api_id = identity[:api_id]
      return [] if api_id.blank?

      links = []
      if sub[:has_guideline]
        links << %(<a class="dj-btn" href="#{Discourse.base_path}/journals/#{h(api_id)}/submission/guideline" rel="nofollow">#{ICON_DOWNLOAD}<span>#{h(t(guideline_label))}</span></a>)
      end
      if sub[:has_latex]
        extra = sub[:latex_class].present? ? %( <small>#{h(sub[:latex_class])}</small>) : ""
        links << %(<a class="dj-btn" href="#{Discourse.base_path}/journals/#{h(api_id)}/submission/latex" rel="nofollow">#{ICON_DOWNLOAD}<span>#{h(t(latex_label))}#{extra}</span></a>)
      end
      links
    end

    def oa_model(oa)
      return nil if oa.blank? || oa[:is_oa].nil?
      return "diamond" if oa[:is_oa] && oa[:diamond_oa]
      return "gold" if oa[:is_oa] && oa[:has_apc]
      return "free" if oa[:is_oa]
      oa[:apc_usd].to_i.positive? ? "hybrid" : "subscription"
    end

    def warnings
      @warnings ||=
        (@d.dig(:warning, :data) || []).select { |w| w[:year] }.sort_by { |w| -w[:year].to_i }
    end

    def render_alert
      return nil if warnings.empty?

      years = warnings.map { |w| w[:year] }.uniq.sort
      newest = warnings.first
      current = newest[:year].to_i >= build_year - WARNING_CURRENT_WINDOW
      details = []
      if newest[:level].present? && newest[:level] != "未分级"
        details << t("alert_level", level: newest[:level])
      end
      details << t("alert_reason", reason: newest[:reason]) if newest[:reason].present?
      details << t("alert_note")

      <<~HTML
        <div class="dj-alert#{" dj-alert--past" unless current}" role="note">
          #{ICON_WARNING}
          <p class="dj-alert__title">#{h(t("alert_title", years: years.join(t("list_separator"))))}</p>
          <p class="dj-alert__text">#{h(details.join(t("sentence_separator")))}</p>
        </div>
      HTML
    end

    def render_key_figures
      tiles = ranking_tiles + review_tiles
      note = nil
      if tiles.empty?
        tiles = output_tiles
        note = %(<p class="dj-keys__note">#{h(t("no_rankings_note"))}</p>) if tiles.any?
      end
      tiles = tiles.first(MAX_KEY_FIGURES)
      return nil if tiles.empty?

      odd = tiles.size.odd? ? " dj-keys--odd" : ""
      %(<div class="dj-keys#{odd}" style="--n: #{tiles.size}">#{tiles.join}</div>#{note})
    end

    def key_tile(label, value_html, sub_html, tier: nil, extra: "")
      <<~HTML.strip
        <div class="dj-key #{tier_class(tier)}"><p class="dj-key__label">#{h(label)}</p><p class="dj-key__value">#{value_html}</p><p class="dj-key__sub">#{sub_html}</p>#{extra}</div>
      HTML
    end

    def ranking_tiles
      tiles = []
      jcr = latest(:jcr)
      if jcr&.dig(:impact_factor).present?
        series =
          (@d.dig(:jcr, :data) || []).filter_map { |y| y[:impact_factor].presence&.to_f }.reverse
        previous = @d.dig(:jcr, :data, 1, :impact_factor)
        delta = previous.present? ? jcr[:impact_factor].to_f - previous.to_f : nil
        delta_html =
          if delta && delta.round(1).nonzero?
            direction = delta.positive? ? "up" : "down"
            arrow = delta.positive? ? "▲" : "▼"
            %(<span class="dj-key__delta dj-key__delta--#{direction}">#{arrow}#{format("%.1f", delta.abs)}</span>)
          else
            ""
          end
        sub = [
          jcr[:quartile].present? ? %(<span class="dj-tone">#{h(jcr[:quartile])}</span>) : nil,
          h(t("year_jcr", year: jcr[:year])),
        ].compact.join(" · ")
        tiles << key_tile(
          t("key_impact_factor"),
          "#{h(jcr[:impact_factor])}#{delta_html}",
          sub,
          tier: quartile_tier(jcr[:quartile]),
          extra: SvgChartBuilder.sparkline(series),
        )
      end

      cas = latest(:cas)
      if (zone = zone_of(cas&.dig(:major_quartile)))
        sub =
          [cas[:major_category], (t("top_short") if yes?(cas[:top])), cas[:year]].compact
            .map { |v| h(v) }
            .join(" · ")
        tiles << key_tile(
          t("key_cas"),
          "#{zone}<small>#{h(t("zone_unit"))}</small>",
          sub,
          tier: zone,
        )
      end

      xr = latest(:xinrui)
      if (zone = zone_of(xr&.dig(:major_quartile)))
        major = xr[:major_category_cn].presence || xr[:major_category]
        sub = [major, xr[:year]].compact.map { |v| h(v) }.join(" · ")
        tiles << key_tile(
          t("key_xinrui"),
          "#{zone}<small>#{h(t("zone_unit"))}</small>",
          sub,
          tier: zone,
        )
      end

      sjr = latest(:scimago)
      if sjr&.dig(:best_quartile).present?
        sub =
          [("SJR #{decimal(sjr[:sjr], 3)}" if sjr[:sjr]), sjr[:year]].compact
            .map { |v| h(v) }
            .join(" · ")
        tiles << key_tile(
          t("key_sjr"),
          h(sjr[:best_quartile]),
          sub,
          tier: quartile_tier(sjr[:best_quartile]),
        )
      end

      ccf = @d[:ccf]
      if (tier = ccf_tier(ccf&.dig(:rank)))
        sub = [ccf[:field], ccf[:year]].compact.map { |v| h(v) }.join(" · ")
        tiles << key_tile(
          t("key_ccf"),
          "#{h(ccf[:rank].to_s.strip[0])}<small>#{h(t("ccf_class"))}</small>",
          sub,
          tier: tier,
        )
      elsif (tier = t_rank_tier(ccf&.dig(:t_rank)))
        tiles << key_tile(t("key_ccf_t"), h(ccf[:t_rank]), h(ccf[:year]), tier: tier)
      end
      tiles
    end

    def review_tiles
      rv = @d[:reviews]
      return [] if rv.blank?

      tiles = []
      if rv[:rating]
        tiles << key_tile(
          t("key_rating"),
          "#{decimal(rv[:rating], 1)}<small>/5</small>",
          h(t("key_rating_sub", value: fmt(rv[:count]))),
        )
      end
      if rv[:median_first_review_days]
        sub =
          (
            if rv[:acceptance_rate]
              t("key_first_review_sub", rate: percent(rv[:acceptance_rate], 0))
            else
              t("median")
            end
          )
        tiles << key_tile(
          t("key_first_review"),
          "#{rv[:median_first_review_days].to_f.round}<small>#{h(t("days_unit"))}</small>",
          h(sub),
        )
      end
      tiles
    end

    def output_tiles
      m = metrics
      tiles = []
      if m[:works_count]
        sub =
          (
            if m[:oa_works_count].to_i.positive? && m[:works_count].to_i.positive?
              t("key_oa_share", rate: percent(m[:oa_works_count].to_f / m[:works_count].to_f, 0))
            else
              t("source_openalex")
            end
          )
        tiles << key_tile(t("key_works"), h(fmt(m[:works_count])), h(sub))
      end
      if m[:cited_by_count]
        tiles << key_tile(t("key_citations"), h(fmt(m[:cited_by_count])), h(t("source_openalex")))
      end
      if m[:h_index]
        sub = m[:i10_index] ? t("key_i10", value: fmt(m[:i10_index])) : t("source_openalex")
        tiles << key_tile(t("key_h_index"), h(fmt(m[:h_index])), h(sub))
      end
      if m[:two_year_mean_citedness]
        tiles << key_tile(
          t("key_citedness"),
          h(decimal(m[:two_year_mean_citedness], 2)),
          h(t("source_openalex")),
        )
      end
      tiles
    end

    def render_summary
      id = identity
      pub = publication
      oa = @d[:open_access] || {}
      title = id[:title].presence || t("unknown_journal")
      name =
        (
          if id[:title_zh].present?
            t("summary_name_with_zh", title: title, title_zh: id[:title_zh])
          else
            title
          end
        )
      gap = cjk_gap(name)

      intro =
        if pub[:publisher_name].present?
          t(
            oa[:is_oa] ? "summary_intro_publisher_oa" : "summary_intro_publisher",
            name: name,
            gap: gap,
            publisher: pub[:publisher_name],
          )
        else
          t(oa[:is_oa] ? "summary_intro_oa" : "summary_intro", name: name, gap: gap)
        end
      inception = wikidata[:inception].to_s[0, 4].to_i
      if inception.positive?
        intro += t("summary_founded", year: inception)
      elsif pub[:first_publication_year].present?
        intro += t("summary_first_year", year: pub[:first_publication_year])
      end
      sentences = [intro]

      rankings = []
      jcr = latest(:jcr)
      if jcr&.dig(:impact_factor).present?
        rankings << if jcr[:quartile].present?
          t("summary_jcr", year: jcr[:year], value: jcr[:impact_factor], quartile: jcr[:quartile])
        else
          t("summary_jcr_plain", year: jcr[:year], value: jcr[:impact_factor])
        end
      end
      cas = latest(:cas)
      if (zone = zone_of(cas&.dig(:major_quartile)))
        rankings << t(
          yes?(cas[:top]) ? "summary_cas_top" : "summary_cas",
          zone: zone,
          category: cas[:major_category],
        )
      end
      sentences << rankings.join(t("clause_separator")) if rankings.any?

      m = metrics
      if m[:works_count]
        sentences << (
          if m[:cited_by_count]
            t("summary_works_cited", works: fmt(m[:works_count]), cited: fmt(m[:cited_by_count]))
          else
            t("summary_works", works: fmt(m[:works_count]))
          end
        )
      end

      rv = @d[:reviews]
      if rv&.dig(:median_first_review_days)
        days = rv[:median_first_review_days].to_f.round
        sentences << (
          if rv[:acceptance_rate]
            t("summary_review_rate", days: days, rate: percent(rv[:acceptance_rate], 0))
          else
            t("summary_review", days: days)
          end
        )
      end

      text = sentences.map { |s| "#{s}#{t("sentence_end")}" }.join(t("sentence_join"))
      %(<p class="dj-summary">#{h(text)}</p>)
    end

    def render_toc(keys)
      return nil if keys.size < 2
      links =
        keys
          .map { |key| %(<a href="#dj-nav-#{key.to_s.tr("_", "-")}">#{h(t(SECTIONS[key]))}</a>) }
          .join
      %(<nav class="dj-toc" aria-label="#{h(t("toc_label"))}">#{links}</nav>)
    end

    # ── Rankings ────────────────────────────────────────────────

    def render_rankings
      rows = ladder_rows
      return nil if rows.empty?

      body = %(<div class="dj-ladder">#{rows.join}</div>) + subject_table + history_matrix
      section(:rankings, body, meta: h(t("rankings_meta")))
    end

    def ladder_row(
      system,
      year,
      value_html,
      detail_html,
      tier: nil,
      sub: nil,
      scale_html: "",
      alert: false
    )
      tone = tier ? tier_class(tier) : (alert ? "dj-bad" : "")
      <<~HTML.strip
        <div class="dj-ladder__row#{" dj-ladder__row--alert" if alert}"><div class="dj-ladder__sys">#{h(system)}#{%(<small>#{h(year)}</small>) if year.present?}</div><div class="dj-ladder__value #{tone}">#{value_html}#{%(<small>#{h(sub)}</small>) if sub.present?}</div><div class="dj-ladder__scale">#{scale_html}</div><div class="dj-ladder__detail">#{detail_html}</div></div>
      HTML
    end

    def ladder_rows
      rows = []

      jcr = latest(:jcr)
      if jcr
        tier = quartile_tier(jcr[:quartile])
        details = [t("detail_impact_factor_html", value: "<b>#{h(jcr[:impact_factor] || "—")}</b>")]
        details << h(jcr[:web_of_science]) if jcr[:web_of_science].present?
        categories = jcr[:categories] || []
        if categories.size > 1
          best = categories.filter_map { |c| c[:quartile].presence }.min
          details << h(t("detail_jcr_categories", n: categories.size, best: best))
        end
        value = tag_link(:jcr_quartile, h(jcr[:quartile].presence || "—"))
        rows << ladder_row(
          t("sys_jcr"),
          jcr[:year],
          value,
          details.join(" · "),
          tier: tier,
          scale_html: scale(tier, 4, %w[Q1 Q4]),
        )
      end

      cas = latest(:cas)
      if (zone = zone_of(cas&.dig(:major_quartile)))
        details = [
          %(<b>#{h(cas[:major_category])}</b>#{%( <span class="dj-muted">#{h(rank_in(cas[:major_quartile]))}</span>) if rank_in(cas[:major_quartile])}),
        ]
        details << h(yes?(cas[:top]) ? t("top_journal") : t("not_top"))
        details << h(t("badge_review_journal")) if yes?(cas[:review])
        details << h(cas[:annotation]) if cas[:annotation].present?
        value = tag_link(:cas_zone, h(t("zone_n", n: zone)))
        rows << ladder_row(
          t("sys_cas"),
          cas[:year],
          value,
          details.join(" · "),
          tier: zone,
          scale_html: scale(zone, 4, [t("zone_n", n: 1), t("zone_n", n: 4)]),
        )
      end

      xr = latest(:xinrui)
      if (zone = zone_of(xr&.dig(:major_quartile)))
        majors = [[xr[:major_category_cn].presence || xr[:major_category], zone, xr[:top]]]
        if xr[:major_category2].present?
          majors << [
            xr[:major_category2_cn].presence || xr[:major_category2],
            zone_of(xr[:major_quartile2]),
            xr[:top2],
          ]
        end
        details =
          majors.map do |name, z, top|
            "<b>#{h(name)}</b> #{h(t("zone_n", n: z))}#{h(" · #{t("top_short")}") if yes?(top)}"
          end
        if xr[:database_src].present?
          details << %(<span class="dj-muted">#{h(xr[:database_src])}</span>)
        end
        value = tag_link(:xinrui_zone, h(t("zone_n", n: zone)))
        rows << ladder_row(
          t("sys_xinrui"),
          xr[:year],
          value,
          details.join(" · "),
          tier: zone,
          scale_html: scale(zone, 4, [t("zone_n", n: 1), t("zone_n", n: 4)]),
        )
      end

      sjr = latest(:scimago)
      if sjr
        tier = quartile_tier(sjr[:best_quartile])
        details = [t("detail_sjr_html", value: "<b>#{h(decimal(sjr[:sjr], 3) || "—")}</b>")]
        details << h(t("detail_h_index", value: fmt(sjr[:h_index]))) if sjr[:h_index]
        details << h(t("detail_sjr_rank", rank: fmt(sjr[:rank]))) if sjr[:rank]
        value = tag_link(:sjr_quartile, h(sjr[:best_quartile].presence || "—"))
        rows << ladder_row(
          t("sys_sjr"),
          sjr[:year],
          value,
          details.join(" · "),
          tier: tier,
          scale_html: scale(tier, 4, %w[Q1 Q4]),
        )
      end

      ccf = @d[:ccf]
      if (tier = ccf_tier(ccf&.dig(:rank)))
        details = [ccf[:field], ccf[:category]].select(&:present?).map { |v| h(v) }.join(" · ")
        value = tag_link(:ccf_rank, h(ccf[:rank].to_s.strip))
        rows << ladder_row(
          t("sys_ccf"),
          ccf[:year],
          value,
          details,
          tier: tier,
          scale_html: scale(tier, 3, %w[A C]),
        )
      end
      if (tier = t_rank_tier(ccf&.dig(:t_rank)))
        rows << ladder_row(
          t("sys_ccf_t"),
          ccf[:year],
          h(ccf[:t_rank]),
          %(<span class="dj-muted">#{h(ccf[:category])}</span>),
          tier: tier,
          scale_html: scale(tier, 3, %w[T1 T3]),
        )
      end

      cwts = latest(:cwts)
      if cwts&.dig(:snip)
        details = []
        details << t("detail_ipp_html", value: "<b>#{h(decimal(cwts[:ipp], 2))}</b>") if cwts[:ipp]
        if cwts[:self_cit_pct]
          details << h(t("detail_self_citation", value: percent(cwts[:self_cit_pct])))
        end
        details << h(t("detail_cwts_docs", value: fmt(cwts[:docs]))) if cwts[:docs]
        rows << ladder_row(
          t("sys_cwts"),
          cwts[:year],
          h(decimal(cwts[:snip], 2)),
          details.join(" · "),
          sub: "SNIP",
        )
      end

      jufo = @d[:jufo]
      if jufo && [jufo[:level_fi], jufo[:level_no], jufo[:level_dk]].any?(&:present?)
        detail =
          h(
            t(
              "detail_jufo",
              fi: jufo[:level_fi].presence || "—",
              no: jufo[:level_no].presence || "—",
              dk: jufo[:level_dk].presence || "—",
            ),
          )
        rows << ladder_row(
          t("sys_jufo"),
          jufo.dig(:levels, 0, :year),
          h(jufo[:level_fi].presence || "—"),
          detail,
          sub: t("jufo_finland"),
        )
      end

      if warnings.any?
        details =
          warnings.map do |w|
            parts = [t("year_n", year: w[:year])]
            parts << t("alert_level", level: w[:level]) if w[:level].present? && w[:level] != "未分级"
            parts << t("alert_reason", reason: w[:reason]) if w[:reason].present?
            h(parts.join(" · "))
          end
        value = tag_link(:warning, h(t("warning_value")))
        rows << ladder_row(t("sys_warning"), nil, value, details.join("；"), alert: true)
      end

      rows
    end

    def subject_table
      rows = []
      jcr = latest(:jcr)
      categories = jcr&.dig(:categories) || []
      if categories.any?
        rows << group_row(t("group_jcr", year: jcr[:year]))
        categories
          .first(MAX_TABLE_ROWS)
          .each do |c|
            rank = c[:rank].to_s
            position, total = rank.split("/").map(&:to_i)
            top =
              (
                if position.to_i.positive? && total.to_i.positive?
                  %( <span class="dj-muted">#{h(t("top_percent", value: decimal(position * 100.0 / total, 1)))}</span>)
                else
                  ""
                end
              )
            rows << table_row(
              h(c[:name]),
              tone_span(c[:quartile], quartile_tier(c[:quartile])),
              "#{h(rank.presence || "—")}#{top}",
            )
          end
      end

      cas = latest(:cas)
      minors = cas&.dig(:minor_categories) || []
      if minors.any?
        rows << group_row(t("group_cas", year: cas[:year]))
        minors
          .first(MAX_TABLE_ROWS)
          .each do |c|
            name_en, name_zh = split_bilingual(c[:category])
            zone = zone_of(c[:quartile])
            rows << table_row(
              bilingual_cell(name_zh || name_en, name_zh ? name_en : nil),
              tone_span(zone ? t("zone_n", n: zone) : c[:quartile], zone),
              h(rank_in(c[:quartile]) || "—"),
            )
          end
      end

      xr = latest(:xinrui)
      xr_minors = xr&.dig(:minor_categories) || []
      if xr_minors.any?
        rows << group_row(t("group_xinrui", year: xr[:year]))
        xr_minors
          .first(MAX_TABLE_ROWS)
          .each do |c|
            zone = zone_of(c[:quartile])
            name = c[:category_cn].presence || c[:category]
            rows << table_row(
              bilingual_cell(name, c[:category_cn].present? ? c[:category] : nil),
              tone_span(zone ? t("zone_n", n: zone) : c[:quartile], zone),
              %(<span class="dj-muted">—</span>),
            )
          end
      end
      return "" if rows.empty?

      head =
        %(<tr><th>#{h(t("col_subject"))}</th><th class="num">#{h(t("col_zone"))}</th><th class="num">#{h(t("col_subject_rank"))}</th></tr>)
      %(<h4 class="dj-subhead">#{h(t("subhead_subjects"))}</h4><div class="dj-table-wrap"><table class="dj-table"><thead>#{head}</thead><tbody>#{rows.join}</tbody></table></div>)
    end

    def group_row(label)
      %(<tr class="dj-table__group"><td colspan="3">#{h(label)}</td></tr>)
    end

    def table_row(name_html, zone_html, rank_html)
      %(<tr><td>#{name_html}</td><td class="num">#{zone_html}</td><td class="num">#{rank_html}</td></tr>)
    end

    def tone_span(text, tier)
      return h(text.presence || "—") unless tier
      %(<span class="dj-tone #{tier_class(tier)}">#{h(text)}</span>)
    end

    def bilingual_cell(primary, secondary)
      html = h(primary)
      html += %(<span class="dj-table__en">#{h(secondary)}</span>) if secondary.present? &&
        secondary != primary
      html
    end

    # "COMPUTER SCIENCE, INFORMATION SYSTEMS 计算机：信息系统" -> [en, zh]
    def split_bilingual(text)
      match = text.to_s.match(/\A(.*?)\s*(\p{Han}.*)\z/)
      match ? [match[1].strip.presence, match[2].strip] : [text, nil]
    end

    def history_matrix
      series =
        [
          ["row_impact_factor", @d.dig(:jcr, :data), ->(y) { y[:impact_factor].presence }, nil],
          [
            "row_jcr_quartile",
            @d.dig(:jcr, :data),
            ->(y) { y[:quartile].presence },
            ->(v) { quartile_tier(v) },
          ],
          [
            "row_cas",
            @d.dig(:cas_partition, :data),
            ->(y) do
              if (z = zone_of(y[:major_quartile]))
                "#{t("zone_n", n: z)}#{" #{t("top_short")}" if yes?(y[:top])}"
              else
                nil
              end
            end,
            ->(v) { zone_of(v) },
          ],
          [
            "row_xinrui",
            @d.dig(:xinrui_partition, :data),
            ->(y) { (z = zone_of(y[:major_quartile])) ? t("zone_n", n: z) : nil },
            ->(v) { zone_of(v) },
          ],
          ["row_sjr", @d.dig(:scimago, :data), ->(y) { decimal(y[:sjr], 3) }, nil],
          [
            "row_sjr_quartile",
            @d.dig(:scimago, :data),
            ->(y) { y[:best_quartile].presence },
            ->(v) { quartile_tier(v) },
          ],
          ["row_snip", @d.dig(:cwts, :data), ->(y) { decimal(y[:snip], 2) }, nil],
        ].filter_map do |label, list, value_of, tier_of|
          by_year =
            (list || []).select { |y| y[:year] }.to_h { |y| [y[:year].to_i, value_of.(y)] }.compact
          [label, by_year, tier_of] if by_year.any?
        end
      return "" if series.empty?

      years = series.flat_map { |_, by_year, _| by_year.keys }.uniq.sort.last(HISTORY_YEARS)
      return "" if years.size < 2

      head =
        %(<tr><th>#{h(t("col_metric"))}</th>#{years.map { |y| %(<th class="num">#{y}</th>) }.join}</tr>)
      body =
        series.map do |label, by_year, tier_of|
          cells =
            years.map do |year|
              value = by_year[year]
              next %(<td class="num dj-muted">—</td>) if value.nil?
              tier = tier_of&.call(value)
              latest_css = year == years.last ? " is-latest" : ""
              %(<td class="num#{latest_css}">#{tier ? tone_span(value, tier) : h(value)}</td>)
            end
          %(<tr><td>#{h(t(label))}</td>#{cells.join}</tr>)
        end
      %(<h4 class="dj-subhead">#{h(t("subhead_history"))}</h4><div class="dj-table-wrap"><table class="dj-table dj-table--matrix"><thead>#{head}</thead><tbody>#{body.join}</tbody></table></div>)
    end

    # ── Reader-reported submission experience ───────────────────

    def render_reviews
      rv = @d[:reviews]
      return render_legacy_reviews if rv.blank?

      score =
        if rv[:rating]
          %(<p class="dj-score__value">#{decimal(rv[:rating], 1)}<small> / 5</small></p>) +
            SvgChartBuilder.star_rating(
              rv[:rating],
              label: t("rating_label", value: decimal(rv[:rating], 1)),
            )
        else
          ""
        end
      meta = [t("rv_based_on", value: fmt(rv[:count]))]
      meta << t("rv_sources", value: fmt(rv[:source_count])) if rv[:source_count].to_i > 1
      meta << t("rv_latest", date: rv[:latest_at].to_s[0, 10]) if rv[:latest_at].present?
      confidence = rv[:rating_confidence].to_s
      if %w[high medium low].include?(confidence)
        meta << t("rv_confidence", level: t("rv_confidence_#{confidence}"))
      end

      stats = []
      if rv[:median_first_review_days]
        stats << stat(
          rv[:median_first_review_days].to_f.round,
          t("days_unit"),
          t("rv_first_review"),
        )
      end
      if rv[:median_total_handling_days]
        stats << stat(
          rv[:median_total_handling_days].to_f.round,
          t("days_unit"),
          t("rv_total_handling"),
        )
      end
      if rv[:avg_review_rounds]
        stats << stat(decimal(rv[:avg_review_rounds], 1), t("rounds_unit"), t("rv_rounds"))
      end
      if rv[:acceptance_rate]
        stats << stat((rv[:acceptance_rate].to_f * 100).round, "%", t("rv_acceptance"))
      end

      head =
        %(<div class="dj-review"><div>#{score}<p class="dj-score__meta">#{h(meta.join(" · "))}</p></div>#{%(<div class="dj-stats#{" dj-stats--odd" if stats.size.odd?}" style="--n: #{stats.size}">#{stats.join}</div>) if stats.any?}</div>)
      body = head + review_outcomes(rv) + review_bars(rv) + review_tags(rv)
      section(:reviews, body, meta: h(t("rv_disclaimer")))
    end

    def stat(value, unit, label)
      %(<div class="dj-stat"><p class="dj-stat__value">#{h(value)}<small>#{h(unit)}</small></p><p class="dj-stat__label">#{h(label)}</p></div>)
    end

    def review_outcomes(rv)
      counts = (rv[:status_counts] || {}).to_h { |k, v| [k.to_s, v.to_i] }
      present = OUTCOMES.select { |key| counts[key].to_i.positive? }
      return "" if present.empty?

      bar =
        present
          .map do |key|
            %(<span class="dj-outcome--#{key}" style="flex: #{counts[key]} 1 0"></span>)
          end
          .join
      legend =
        present
          .map do |key|
            %(<span class="dj-outcome--#{key}"><i></i>#{h(t("outcome_#{key}"))} <b>#{h(fmt(counts[key]))}</b></span>)
          end
          .join
      %(<h4 class="dj-subhead">#{h(t("rv_outcomes"))}</h4><div class="dj-outcome" role="img" aria-label="#{h(t("rv_outcomes"))}">#{bar}</div><div class="dj-legend">#{legend}</div>)
    end

    def review_bars(rv)
      dims =
        REVIEW_DIMENSIONS.filter_map do |key, label, css|
          next if rv[key].nil?
          bar(t(label), rv[key].to_f / 5 * 100, decimal(rv[key], 1), css)
        end
      rates =
        REVIEW_RATES.filter_map do |key, label, css|
          next if rv[key].nil?
          bar(t(label), rv[key].to_f * 100, percent(rv[key], 0), css)
        end
      return "" if dims.empty? && rates.empty?

      columns = []
      if dims.any?
        columns << %(<div><h4 class="dj-subhead">#{h(t("rv_dimensions"))}</h4><div class="dj-bars">#{dims.join}</div></div>)
      end
      if rates.any?
        columns << %(<div><h4 class="dj-subhead">#{h(t("rv_rates"))}</h4><div class="dj-bars">#{rates.join}</div></div>)
      end
      %(<div class="dj-split">#{columns.join}</div>)
    end

    def bar(label, pct, value, css = nil)
      %(<div class="dj-bar #{css}"><span class="dj-bar__label">#{h(label)}</span><span class="dj-bar__track"><span class="dj-bar__fill" style="width: #{pct.to_f.clamp(0, 100).round(1)}%"></span></span><span class="dj-bar__value">#{h(value)}</span></div>)
    end

    def review_tags(rv)
      counts = (rv[:tag_counts] || {}).to_h { |k, v| [k.to_s, v.to_i] }
      positive = Array(rv[:positive_tags]).map(&:to_s)
      negative = Array(rv[:negative_tags]).map(&:to_s)
      # Older rows have no counts; fall back to the top-tag lists.
      counts = (positive + negative).index_with { nil } if counts.empty?
      return "" if counts.empty?

      tags =
        counts.map do |tag, count|
          css =
            (
              if positive.include?(tag)
                "dj-chip--tone dj-good"
              else
                (negative.include?(tag) ? "dj-chip--tone dj-bad" : nil)
              end
            )
          chip("#{h(tag)}#{%(<span class="dj-chip__count">#{h(fmt(count))}</span>) if count}", css)
        end
      %(<h4 class="dj-subhead">#{h(t("rv_tags"))}</h4><div class="dj-chips">#{tags.join}</div>)
    end

    # Topics synced before upstream contract v4 still carry the retired
    # `scirev` block; it goes once they are re-synced.
    def render_legacy_reviews
      sr = @d[:scirev]
      return nil if sr.blank?

      stats = []
      if sr[:first_review_months]
        stats << stat(decimal(sr[:first_review_months], 1), t("months_unit"), t("rv_first_review"))
      end
      if sr[:total_handling_months]
        stats << stat(
          decimal(sr[:total_handling_months], 1),
          t("months_unit"),
          t("rv_total_handling"),
        )
      end
      if sr[:avg_review_rounds]
        stats << stat(sr[:avg_review_rounds], t("rounds_unit"), t("rv_rounds"))
      end
      return nil if stats.empty?

      score =
        if sr[:overall_rating]
          %(<p class="dj-score__value">#{decimal(sr[:overall_rating], 1)}<small> / 5</small></p>) +
            SvgChartBuilder.star_rating(
              sr[:overall_rating],
              label: t("rating_label", value: decimal(sr[:overall_rating], 1)),
            )
        else
          ""
        end
      meta =
        (
          if sr[:review_count]
            %(<p class="dj-score__meta">#{h(t("rv_based_on", value: fmt(sr[:review_count])))}</p>)
          else
            ""
          end
        )
      section(
        :reviews,
        %(<div class="dj-review"><div>#{score}#{meta}</div><div class="dj-stats#{" dj-stats--odd" if stats.size.odd?}" style="--n: #{stats.size}">#{stats.join}</div></div>),
        meta: h(t("rv_disclaimer")),
      )
    end

    # ── Submission guide ─────────────────────────────────────────

    def render_submission
      sub = @d[:submission] || {}
      editorial = @d[:editorial] || {}
      return nil if sub.blank? && editorial.blank?

      buttons = []
      if sub[:submission_system_url].present?
        buttons << external_link(
          sub[:submission_system_url],
          t("link_submit_system"),
          "dj-btn dj-btn--primary",
        )
      end
      buttons.concat(
        download_links(
          sub,
          guideline_label: "link_download_guideline",
          latex_label: "link_download_latex",
        ),
      )
      links = editorial[:links] || {}
      {
        author_instructions: "link_author_instructions",
        aims_scope: "link_aims_scope",
        editorial_board: "link_editorial_board",
        review_process: "link_review_process",
      }.each { |key, label| buttons << external_link(links[key], t(label)) if links[key].present? }

      items = submission_items(sub, editorial)
      return nil if buttons.empty? && items.empty?

      body = ""
      body += %(<div class="dj-btns">#{buttons.join}</div>) if buttons.any?
      body += dl(items)
      meta = sub[:capture_quality] == "landing_page" ? h(t("sub_landing_note")) : nil
      section(:submission, body, meta: meta)
    end

    def submission_items(sub, editorial)
      items = []
      peer = sub[:peer_review_model].presence
      doaj_peer = Array(editorial[:peer_review]).first
      if peer
        items << [t("sub_peer_review"), h(peer_review_label(peer))]
      elsif doaj_peer
        items << [
          t("sub_peer_review"),
          "#{h(peer_review_label(doaj_peer))} <span class=\"dj-muted\">DOAJ</span>",
        ]
      end
      weeks = @d.dig(:open_access, :publication_time_weeks)
      items << [t("sub_publication_time"), h(t("weeks_value", value: weeks))] if weeks.present?

      length = []
      length << t("words_max", value: fmt(sub[:word_limit])) if sub[:word_limit].present?
      length << t("pages_max", value: fmt(sub[:page_limit])) if sub[:page_limit].present?
      items << [t("sub_length"), h(length.join(t("clause_separator")))] if length.any?
      if sub[:abstract_word_limit].present?
        items << [t("sub_abstract"), h(t("words_max", value: fmt(sub[:abstract_word_limit])))]
      end
      if sub[:keywords_min].present? || sub[:keywords_max].present?
        text =
          if sub[:keywords_min].present? && sub[:keywords_max].present?
            t("keywords_range", min: sub[:keywords_min], max: sub[:keywords_max])
          elsif sub[:keywords_max].present?
            t("keywords_max", max: sub[:keywords_max])
          else
            t("keywords_min", min: sub[:keywords_min])
          end
        items << [t("sub_keywords"), h(text)]
      end
      if sub[:reference_style].present?
        style = REFERENCE_STYLES[sub[:reference_style].to_s.downcase] || sub[:reference_style].to_s
        intext = INTEXT_KEYS[sub[:reference_intext].to_s]
        text = intext ? t("reference_with_intext", style: style, intext: t(intext)) : style
        items << [t("sub_references"), h(text)]
      end
      figures = []
      figures << Array(sub[:figure_formats]).join(" / ") if Array(sub[:figure_formats]).any?
      figures << t("figure_dpi", dpi: sub[:figure_dpi]) if sub[:figure_dpi].present?
      items << [t("sub_figures"), h(figures.join(t("clause_separator")))] if figures.any?
      items << [t("sub_highlights"), h(t("required"))] if sub[:highlights]
      items << [t("sub_graphical_abstract"), h(t("required"))] if sub[:graphical_abstract]
      items << [t("sub_ai_disclosure"), h(t("required"))] if sub[:ai_disclosure_required]
      guidelines = Array(sub[:reporting_guidelines])
      if guidelines.any?
        items << [t("sub_reporting_guidelines"), h(guidelines.join(t("list_separator")))]
      end
      if Array(sub[:file_formats]).any?
        items << [t("sub_file_formats"), chips(Array(sub[:file_formats]))]
      end
      if Array(sub[:article_types]).any?
        items << [t("sub_article_types"), chips(Array(sub[:article_types]))]
      end
      items
    end

    def peer_review_label(value)
      key = PEER_REVIEW_KEYS[value.to_s]
      key ? t(key) : value.to_s
    end

    # ── Open access and fees ─────────────────────────────────────

    def render_open_access
      oa = @d[:open_access] || {}
      model = oa_model(oa)
      return nil if model.nil? && oa[:apc_usd].blank?

      items = []
      if model
        css = %w[diamond gold free].include?(model) ? "dj-chip--tone dj-good" : nil
        items << [
          t("oa_model"),
          "#{chip(h(t("oa_model_#{model}")), css)} <span class=\"dj-muted\">#{h(t("oa_model_#{model}_note"))}</span>",
        ]
      end

      history =
        Array(oa[:apc_usd_by_year])
          .select { |a| a[:year] && a[:price] }
          .sort_by { |a| a[:year].to_i }
      if oa[:apc_usd].present?
        apc = "<b>#{h(t("usd", amount: fmt(oa[:apc_usd])))}</b>"
        apc +=
          %( <span class="dj-muted">#{h(t("year_n", year: history.last[:year]))}</span>) if history.any?
        doaj_max = Array(oa[:doaj_apc_max]).find { |a| a[:price].present? }
        if doaj_max
          apc +=
            " · #{h(t("apc_doaj_max", amount: fmt(doaj_max[:price]), currency: doaj_max[:currency].presence || "USD"))}"
        end
        items << [t("oa_apc"), apc]
      end
      if oa[:has_waiver]
        waiver = h(t("waiver_available"))
        waiver +=
          %( · <a href="#{h(oa[:waiver_url])}" target="_blank" rel="noopener nofollow">#{h(t("waiver_policy"))}</a>) if oa[
          :waiver_url
        ].present?
        items << [t("oa_waiver"), waiver]
      end
      licenses = Array(oa[:licenses]).select { |l| l[:type].present? }
      if licenses.any?
        html =
          licenses.map do |l|
            if l[:url].present?
              %(<a href="#{h(l[:url])}" target="_blank" rel="noopener nofollow">#{h(l[:type])}</a>)
            else
              h(l[:type])
            end
          end
        items << [t("oa_licenses"), html.join(h(t("list_separator")))]
      end
      items << [t("oa_copyright"), h(t("copyright_author"))] if oa[:copyright_author_retains]
      items << [t("oa_since"), h(t("year_n", year: oa[:oa_start]))] if oa[:oa_start].present?
      items << [t("oa_plagiarism"), h(t("plagiarism_value"))] if oa[:plagiarism_detection]
      preservation =
        (Array(@d.dig(:preservation, :preservation_services)) + Array(wikidata[:archives])).uniq
      items << [t("oa_preservation"), chips(preservation)] if preservation.any?
      deposit = Array(@d.dig(:preservation, :deposit_services))
      items << [t("oa_deposit"), h(deposit.join(t("list_separator")))] if deposit.any?

      chart = ""
      if history.size > 1
        svg =
          SvgChartBuilder.line_chart(
            history.map { |a| { year: a[:year], value: a[:price] } },
            label: t("chart_apc"),
          )
        chart =
          %(<div class="dj-chart dj-chart--apc"><div class="dj-chart__head"><span class="dj-chart__title">#{h(t("chart_apc"))}</span><span class="dj-muted">OpenAlex</span></div>#{svg}</div>)
      end

      return nil if items.size < 2 && chart.blank?

      body =
        (
          if chart.present?
            %(<div class="dj-split">#{dl(items, "dj-dl--single")}#{chart}</div>)
          else
            dl(items)
          end
        )
      section(:open_access, body)
    end

    # ── Output and citations ─────────────────────────────────────

    def render_impact
      m = metrics
      counts = Array(m[:counts_by_year]).select { |c| c[:year] }.sort_by { |c| c[:year].to_i }
      stats = []
      stats << stat(fmt(m[:works_count]), "", t("stat_works")) if m[:works_count]
      stats << stat(fmt(m[:cited_by_count]), "", t("stat_citations")) if m[:cited_by_count]
      stats << stat(fmt(m[:h_index]), "", t("stat_h_index")) if m[:h_index]
      stats << stat(fmt(m[:i10_index]), "", t("stat_i10_index")) if m[:i10_index]
      if m[:two_year_mean_citedness]
        stats << stat(decimal(m[:two_year_mean_citedness], 2), "", t("stat_citedness"))
      end
      if m[:oa_works_count] && m[:works_count].to_i.positive?
        stats << stat(
          percent(m[:oa_works_count].to_f / m[:works_count].to_f, 0),
          "",
          t("stat_oa_share"),
        )
      end
      return nil if stats.empty? && counts.size < 3

      partial = counts.any? { |c| c[:year].to_i == build_year } ? build_year : nil
      charts = []
      if counts.size >= 3
        works =
          counts.map do |c|
            { year: c[:year].to_i, total: c[:works_count].to_i, part: c[:oa_works_count].to_i }
          end
        legend =
          %(<span class="dj-legend"><span class="dj-legend--part"><i></i>#{h(t("legend_oa"))}</span><span class="dj-legend--total"><i></i>#{h(t("legend_all"))}</span></span>)
        charts << chart_card(
          t("chart_works"),
          legend,
          SvgChartBuilder.bar_chart(works, label: t("chart_works"), partial_year: partial),
          [t("col_year"), t("col_works"), t("col_oa_works")],
          works.reverse.map { |w| [w[:year], fmt(w[:total]), fmt(w[:part])] },
        )
        cited = counts.map { |c| { year: c[:year].to_i, value: c[:cited_by_count].to_i } }
        charts << chart_card(
          t("chart_citations"),
          "",
          SvgChartBuilder.line_chart(cited, label: t("chart_citations"), partial_year: partial),
          [t("col_year"), t("col_citations")],
          cited.reverse.map { |c| [c[:year], fmt(c[:value])] },
        )
      end

      odd = stats.size.odd? ? " dj-statrow--odd" : ""
      body = ""
      body +=
        %(<div class="dj-statrow#{odd}" style="--n: #{stats.size}">#{stats.join}</div>) if stats.any?
      body += %(<div class="dj-charts">#{charts.join}</div>) if charts.any?
      meta =
        ["OpenAlex", (t("partial_year_note", year: partial) if partial)].compact
          .map { |v| h(v) }
          .join(" · ")
      section(:impact, body, meta: meta)
    end

    def chart_card(title, legend_html, svg, head, rows)
      return "" if svg.blank?
      table_head =
        head
          .each_with_index
          .map { |label, i| %(<th#{' class="num"' if i.positive?}>#{h(label)}</th>) }
          .join
      table_rows =
        rows
          .map do |row|
            "<tr>#{row.each_with_index.map { |cell, i| %(<td#{' class="num"' if i.positive?}>#{h(cell)}</td>) }.join}</tr>"
          end
          .join
      <<~HTML
        <div class="dj-chart">
          <div class="dj-chart__head"><span class="dj-chart__title">#{h(title)}</span>#{legend_html}</div>
          #{svg}
          <details><summary>#{h(t("show_data"))}</summary><div class="dj-table-wrap"><table class="dj-table"><thead><tr>#{table_head}</tr></thead><tbody>#{table_rows}</tbody></table></div></details>
        </div>
      HTML
    end

    # ── Research topics ──────────────────────────────────────────

    def render_topics
      st = @d[:subjects_topics] || {}
      shares =
        Array(st[:topic_shares])
          .select { |s| s[:name].present? && s[:value].to_f.positive? }
          .sort_by { |s| -s[:value].to_f }

      rows = []
      chip_row = ->(label, values) do
        values = Array(values).select(&:present?).uniq
        if values.any?
          rows << %(<div class="dj-chiprow"><span>#{h(label)}</span><div class="dj-chips">#{chips(values.first(16))}</div></div>)
        end
      end
      chip_row.(t("topics_keywords"), st[:keywords])
      chip_row.(t("topics_subjects"), st[:subjects])
      chip_row.(t("topics_scimago_areas"), @d.dig(:scimago, :areas))
      chip_row.(t("topics_wikidata"), st[:wikidata_subjects])
      return nil if shares.empty? && rows.empty?

      body = ""
      if shares.any?
        max = shares.first[:value].to_f
        list =
          shares.map do |s|
            name = h(s[:name])
            name += %(<small>#{h(s[:subfield])}</small>) if s[:subfield].present?
            %(<div class="dj-share"><span class="dj-share__name">#{name}</span><span class="dj-bar__track"><span class="dj-bar__fill" style="width: #{(s[:value].to_f / max * 100).round(1)}%"></span></span><span class="dj-share__value">#{h(percent(s[:value], 1))}</span></div>)
          end
        body +=
          %(<div class="dj-shares">#{list.join}</div><p class="dj-note">#{h(t("topics_note"))}</p>)
      end
      body += %(<div class="dj-chiprows">#{rows.join}</div>) if rows.any?

      fields = shares.filter_map { |s| s[:field].presence }.uniq.first(3)
      meta = fields.any? ? h(t("topics_fields", fields: fields.join(t("list_separator")))) : nil
      section(:topics, body, meta: meta)
    end

    # ── Journal profile ──────────────────────────────────────────

    def render_profile
      id = identity
      pub = publication
      items = []
      add = ->(label, value) { items << [t(label), value] if value.present? }

      add.("profile_title", h(id[:title]))
      add.("profile_title_zh", h(id[:title_zh]))
      add.("profile_abbreviation", h(id[:abbreviation])) if abbreviation?
      # Wikidata aliases come in every script; readers here use Latin or Chinese names.
      other_names =
        (
          Array(id[:alternate_titles]) + Array(id[:aliases]) +
            [(id[:abbreviation] unless abbreviation?)]
        )
          .map(&:to_s)
          .reject { |n| n.blank? || n == id[:title] || n == id[:title_zh] }
          .select { |n| n.match?(/\A[\p{Latin}\p{Han}\p{Common}]+\z/) }
          .uniq
          .first(4)
      add.("profile_other_names", h(other_names.join("；")))
      add.("profile_former_title", h(id[:former_title]))
      add.("profile_successor_title", h(id[:successor_title]))
      add.("issn_l", h(id[:issn_l]))
      add.("profile_print_issn", h(id[:print_issn]))
      add.("profile_electronic_issn", h(id[:electronic_issn]))
      add.("profile_cn_number", h(id[:cn_number]))
      if pub[:publisher_name].present?
        add.("profile_publisher", tag_link(:publisher, h(pub[:publisher_name])))
      end
      add.("profile_sponsor", h(pub[:sponsor]))
      add.("profile_owned_by", h(pub[:owned_by]))
      add.("profile_societies", h(Array(pub[:societies]).join("；")))
      country = pub[:country_name].presence || pub[:country_code]
      add.("profile_country", tag_link(:country, h(country))) if country.present?
      add.("profile_hq", h(pub[:hq_location]))
      add.("profile_languages", h(Array(wikidata[:languages]).join(t("list_separator"))))
      inception = wikidata[:inception].to_s[0, 4]
      add.("profile_inception", h(t("year_n", year: inception))) if inception.to_i.positive?
      if pub[:first_publication_year].present?
        span = [pub[:first_publication_year], pub[:last_publication_year]].compact.join("–")
        add.("profile_coverage_years", %(#{h(span)} <span class="dj-muted">OpenAlex</span>))
      end
      add.("profile_frequency", h(frequency_text))
      if pub[:editor_in_chief].present?
        add.("profile_editor_in_chief", h(pub[:editor_in_chief]))
      else
        add.("profile_editors", h(Array(wikidata[:editors]).first(3).join(t("list_separator"))))
      end
      add.("profile_doi_prefix", h(pub[:doi_prefix]))
      add.("profile_coden", h(wikidata[:coden]))
      access = pub[:online_access].to_s
      if access.present?
        add.("profile_access", h(access == "paywall" ? t("access_paywall") : access))
      end
      if id[:homepage_url].present?
        display = id[:homepage_url].sub(%r{\Ahttps?://}, "").chomp("/")
        add.(
          "profile_homepage",
          %(<a href="#{h(id[:homepage_url])}" target="_blank" rel="noopener">#{h(display)}</a>),
        )
      end

      chip_rows = []
      databases = Array(wikidata[:indexed_in]).dup
      wos =
        latest(:cas)&.dig(:web_of_science).presence || latest(:jcr)&.dig(:web_of_science).presence
      if wos && databases.none? { |d| d.include?("Citation Index") }
        databases.unshift("Web of Science (#{wos})")
      end
      if databases.any?
        chip_rows << %(<div class="dj-chiprow"><span>#{h(t("profile_databases"))}</span><div class="dj-chips">#{chips(databases.uniq)}</div></div>)
      end
      if @d.dig(:scimago, :coverage).present?
        chip_rows << %(<div class="dj-chiprow"><span>#{h(t("profile_scopus_coverage"))}</span><div>#{h(@d.dig(:scimago, :coverage))}</div></div>)
      end
      external =
        Array(id[:external_ids])
          .select { |e| e[:property].present? && e[:identifier].present? }
          .first(10)
      if external.any?
        ids =
          external
            .map do |e|
              chip(
                %(<span class="dj-chip__key">#{h(e[:property])}</span>#{h(e[:identifier])}),
                "dj-chip--mono",
              )
            end
            .join
        chip_rows << %(<div class="dj-chiprow"><span>#{h(t("profile_external_ids"))}</span><div class="dj-chips">#{ids}</div></div>)
      end
      return nil if items.empty? && chip_rows.empty?

      section(
        :profile,
        dl(items) + (chip_rows.any? ? %(<div class="dj-chiprows">#{chip_rows.join}</div>) : ""),
      )
    end

    def frequency_text
      interval = wikidata[:frequency_interval].to_s
      unit = wikidata[:frequency_unit].to_s.downcase
      if interval.present? && FREQUENCY_UNITS.include?(unit)
        unit_label = t("unit_#{unit}")
        if interval == "1"
          t("frequency_every_one", unit: unit_label)
        else
          t("frequency_every_n", n: interval, unit: unit_label)
        end
      else
        wikidata[:frequency].presence
      end
    end

    # ── Provenance ───────────────────────────────────────────────

    def render_footer
      prov = @d[:provenance] || {}
      sources = Array(prov[:sources]).map(&:to_s).select { |s| SOURCE_KEYS.include?(s) }
      return nil if sources.empty? && prov[:built_at].blank?

      lines = []
      if sources.any?
        names = sources.map { |s| t("source_#{s}") }
        lines << %(<p><b>#{h(t("foot_sources"))}</b>#{h(names.join(" · "))}</p>)
      end
      updated = []
      updated << t("foot_updated_at", date: prov[:built_at].to_s[0, 10]) if prov[:built_at].present?
      updated << t("foot_partial") if prov[:partial]
      updated << t("foot_note")
      lines << %(<p>#{h(updated.join(" · "))}</p>)
      %(<footer class="dj-foot">#{lines.join}</footer>)
    end

    STOP_WORDS = Set.new(%w[of the and in for on a an to with]).freeze

    def initials(title)
      return "?" if title.blank?
      if title.match?(/\p{Han}/)
        han = title.scan(/\p{Han}/).first(2).join
        return han if han.present?
      end
      words = title.split(%r{[\s\-/&:,.]+}).reject { |w| STOP_WORDS.include?(w.downcase) }
      letters = words.filter_map { |w| w[0]&.upcase if w.match?(/\A[A-Za-z0-9]/) }
      result = letters.first(3).join
      result.presence || title[0..1].upcase
    end
  end
end
