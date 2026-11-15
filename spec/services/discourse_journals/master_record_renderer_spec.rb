# frozen_string_literal: true

describe DiscourseJournals::MasterRecordRenderer do
  before { enable_current_plugin }

  let(:journal) do
    {
      identity: {
        api_id: 25_688,
        title: "IEEE Access",
        title_zh: "IEEE 开放获取",
        issn_l: "2169-3536",
        electronic_issn: "2169-3536",
        homepage_url: "https://ieeeaccess.ieee.org",
      },
      publication: {
        publisher_name: "IEEE",
        country_name: "United States",
        first_publication_year: 2012,
      },
      metrics: {
        works_count: 113_831,
        cited_by_count: 2_667_601,
        h_index: 372,
        counts_by_year: [
          { year: 2026, works_count: 7745, oa_works_count: 7745, cited_by_count: 2024 },
          { year: 2025, works_count: 13_000, oa_works_count: 13_000, cited_by_count: 400_000 },
          { year: 2024, works_count: 12_000, oa_works_count: 12_000, cited_by_count: 380_000 },
        ],
      },
      jcr: {
        data: [
          {
            year: 2025,
            impact_factor: "4.2",
            quartile: "Q2",
            web_of_science: "SCIE",
            categories: [
              { name: "TELECOMMUNICATIONS", quartile: "Q2", rank: "53/127" },
              { name: "COMPUTER SCIENCE, INFORMATION SYSTEMS", quartile: "Q2", rank: "100/266" },
            ],
          },
          { year: 2024, impact_factor: "3.6", quartile: "Q2" },
        ],
      },
      cas_partition: {
        data: [
          {
            year: 2025,
            major_category: "计算机科学",
            major_quartile: "4 [318/758]",
            top: "否",
            annotation: "Mega-Journal",
            minor_categories: [{ category: "TELECOMMUNICATIONS 电信学", quartile: "4 [56/119]" }],
          },
        ],
      },
      open_access: {
        is_oa: true,
        has_apc: true,
        is_in_doaj: true,
        apc_usd: 2075,
      },
      reviews: {
        count: 1777,
        rating: 2.96,
        median_first_review_days: 33.95,
        acceptance_rate: 0.7711,
        status_counts: {
          accepted: 588,
          rejected: 163,
        },
        tag_counts: {
          "审稿快" => 199,
        },
        positive_tags: ["审稿快"],
      },
      submission: {
        has_guideline: true,
        submission_system_url: "https://ieee.atyponrex.com/journal/ieee-access",
      },
      warning: {
        data: [{ year: 2020, level: "中" }],
      },
      provenance: {
        sources: %w[openalex jcr fqb],
        built_at: "2026-11-03T10:37:34.000Z",
      },
    }
  end

  def render(data = journal, **opts)
    described_class.new(data, **opts).render
  end

  describe "#render" do
    it "lays out the sections a journal has data for, in page order" do
      html = render

      expect(html.scan(/id="(dj-nav-[a-z-]+)"/).flatten).to eq(
        %w[
          dj-nav-hero
          dj-nav-rankings
          dj-nav-reviews
          dj-nav-submission
          dj-nav-open-access
          dj-nav-impact
          dj-nav-profile
        ],
      )
      expect(html).to include(
        "https://ieee.atyponrex.com/journal/ieee-access",
        "/journals/25688/submission/guideline",
        "Mega-Journal",
        "53/127",
        "dj-outcome--accepted",
        "Sources",
        %(电信学<span class="dj-table__en">TELECOMMUNICATIONS</span>),
      )
    end

    it "escapes upstream values" do
      journal[:identity][:title] = %(<img src=x onerror="alert(1)">)
      journal[:cas_partition][:data][0][:annotation] = "<b>Mega</b>"

      html = render

      expect(html).not_to include(
        journal[:identity][:title],
        journal.dig(:cas_partition, :data, 0, :annotation),
      )
      expect(html).to include("&lt;img src=x onerror=&quot;alert(1)&quot;&gt;")
    end

    it "shows an old warning-list entry as history and a recent one as an alert" do
      expect(render).to include("dj-alert dj-alert--past")

      journal[:warning][:data] = [{ year: 2024, level: "未分级", reason: "引用操纵" }]

      html = render
      expect(html).to include(%(<div class="dj-alert" role="note">), "引用操纵")
      expect(html).not_to include("未分级")
    end

    it "falls back to output figures when the journal has no rankings or reports" do
      sparse = journal.slice(:identity, :publication, :metrics, :provenance)

      html = render(sparse)

      expect(html).to include(I18n.t("discourse_journals.render.no_rankings_note"), "113,831")
      expect(html).not_to include("dj-nav-rankings", "dj-nav-reviews")
    end

    it "states the publication frequency from the Wikidata interval and unit" do
      journal[:wikidata_meta] = { frequency_interval: "1", frequency_unit: "week" }

      expect(render).to include("Every week")
    end

    it "links rankings to their canonical tag pages once the tag cache is warm" do
      SiteSetting.tagging_enabled = true
      DiscourseJournals::JournalTagManager.reset_cache!
      DiscourseJournals::JournalTagManager.warm_caches!

      html = render

      expect(html).to include(
        %(href="#{Tag.find_by(name: "jcr:q2").url}"),
        %(href="#{Tag.find_by(name: "oa").url}"),
      )
    ensure
      DiscourseJournals::JournalTagManager.reset_cache!
    end

    it "keeps the outdated banner and the breadcrumb category" do
      category = Fabricate(:category, name: "Journals")

      html = described_class.new(journal, category: category).render(outdated: true)

      expect(html).to include("dj-outdated-notice", %(href="#{category.url}"))
    end
  end
end
