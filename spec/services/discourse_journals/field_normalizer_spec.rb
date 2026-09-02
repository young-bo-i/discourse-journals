# frozen_string_literal: true

describe DiscourseJournals::FieldNormalizer do
  describe "#normalize emerging-tier (新锐分区 / xr)" do
    it "builds xinrui_partition from the xr source, newest year first" do
      data = {
        sources: {
          xr: {
            main: {},
            all_years: [
              { year: 2025, major_category: "Medicine", major_quartile: "4 区" },
              {
                year: 2026,
                major_category: "Medicine",
                major_category_cn: "医学",
                major_quartile: "3 区",
                top: "—",
                major_category2: "Biology",
                major_category2_cn: "生物学",
                major_quartile2: "2 区",
                top2: "是",
                database_src: "Web of Science (SCIE); Scopus",
                subcategory_1: "NEUROSCIENCES",
                subcategory_1_cn: "神经科学",
                subcategory_1_quartile: "3 区",
              },
            ],
          },
        },
      }

      result = described_class.new(data).normalize[:xinrui_partition]

      expect(result[:data].map { |y| y[:year] }).to eq([2026, 2025])

      latest = result[:data].first
      expect(latest[:major_category_cn]).to eq("医学")
      expect(latest[:major_quartile]).to eq("3 区")
      expect(latest[:major_category2_cn]).to eq("生物学")
      expect(latest[:database_src]).to eq("Web of Science (SCIE); Scopus")
      expect(latest[:minor_categories]).to contain_exactly(
        { category: "NEUROSCIENCES", category_cn: "神经科学", quartile: "3 区" },
      )
    end

    it "returns nil for xinrui_partition when the xr source is absent" do
      expect(described_class.new({ sources: {} }).normalize[:xinrui_partition]).to be_nil
    end
  end

  describe "#normalize identity" do
    it "carries the upstream row id so JournalUpserter can persist api_id" do
      data = { unified: { id: 3078, canonical_name: "Nature" } }

      expect(described_class.new(data).normalize.dig(:identity, :api_id)).to eq(3078)
    end
  end

  describe "#normalize reviews (upstream comments aggregate)" do
    let(:comments) do
      {
        comment_count: 176,
        source_count: 4,
        journal_rating_0_5: 3.38,
        rating_confidence: "high",
        difficulty_index_0_5: 2.94,
        quality_index_0_5: 4.74,
        speed_index_0_5: 3.43,
        acceptance_reported_rate: 0.7174,
        median_first_review_days: 32.72,
        avg_review_rounds: 1,
        top_positive_tags: %w[录用 审稿快],
        top_negative_tags: %w[退稿],
        status_counts: { accepted: 66 },
        recent: [{ record_id: "x", comment_text: "..." }],
      }
    end

    it "flattens the aggregate and drops the inlined recent comments" do
      result = described_class.new({ sources: { comments: comments } }).normalize[:reviews]

      expect(result[:count]).to eq(176)
      expect(result[:rating]).to eq(3.38)
      expect(result[:rating_confidence]).to eq("high")
      expect(result[:quality]).to eq(4.74)
      expect(result[:acceptance_rate]).to eq(0.7174)
      expect(result[:median_first_review_days]).to eq(32.72)
      expect(result[:positive_tags]).to eq(%w[录用 审稿快])
      expect(result).not_to have_key(:recent)
    end

    it "falls back to the row-level comments summary when the source is absent" do
      data = { comments_summary: { count: 2, rating: 3.01, rating_confidence: "low" } }

      result = described_class.new(data).normalize[:reviews]

      expect(result[:count]).to eq(2)
      expect(result[:rating]).to eq(3.01)
    end

    it "returns nil when the journal has no reports" do
      data = { comments_summary: { has_comments: false, count: 0 } }

      expect(described_class.new(data).normalize[:reviews]).to be_nil
    end
  end

  describe "#normalize cwts / jufo" do
    it "builds cwts history newest year first and mirrors the latest into metrics" do
      data = {
        unified: { cwts_snip: 10.6 },
        sources: {
          cwts: {
            main: { year: 2025, snip: 10.6, ipp: 47.3, self_cit_pct: 0.0121, p: 3683 },
            all_years: [
              { year: 2024, snip: 10.09, ipp: 45.32 },
              { year: 2025, snip: 10.6, ipp: 47.3, self_cit_pct: 0.0121, p: 3683 },
            ],
          },
        },
      }

      normalized = described_class.new(data).normalize

      expect(normalized.dig(:cwts, :data).map { |c| c[:year] }).to eq([2025, 2024])
      expect(normalized.dig(:cwts, :data).first[:docs]).to eq(3683)
      expect(normalized.dig(:metrics, :snip)).to eq(10.6)
    end

    it "reads the jufo per-year list from `levels`, not `all_years`" do
      data = {
        sources: {
          jufo: {
            main: { level_fi: "3", level_no: "2", level_dk: "3", channel_type: "Lehti/sarja" },
            levels: [{ year: 2025, level: "3" }, { year: 2026, level: "3" }],
          },
        },
      }

      result = described_class.new(data).normalize[:jufo]

      expect(result[:level_fi]).to eq("3")
      expect(result[:levels].map { |l| l[:year] }).to eq([2026, 2025])
    end
  end

  describe "#normalize submission" do
    it "merges the row summary with the structured guide fields" do
      data = {
        submission_summary: { has_guideline: true, has_latex: true, latex_class: "sn-jnl.cls" },
        sources: {
          submission: {
            main: { capture_quality: "full" },
            latex: { class: "sn-jnl.cls", master_zip: "sn-jnl.zip" },
            fields_json: {
              reference_style: { intext: "superscript" },
              submission: { file_formats: %w[latex word] },
              figures: { formats: ["PDF"] },
            },
          },
        },
      }

      result = described_class.new(data).normalize[:submission]

      expect(result[:has_guideline]).to eq(true)
      expect(result[:latex_class]).to eq("sn-jnl.cls")
      expect(result[:latex_zip]).to eq("sn-jnl.zip")
      expect(result[:reference_intext]).to eq("superscript")
      expect(result[:file_formats]).to eq(%w[latex word])
      expect(result[:figure_formats]).to eq(["PDF"])
    end

    it "returns nil when the journal has neither a guideline nor a template" do
      data = { submission_summary: { has_guideline: false, has_latex: false } }

      expect(described_class.new(data).normalize[:submission]).to be_nil
    end
  end

  describe "#normalize provenance" do
    it "records the contributing sources and whether the row was degraded" do
      data = {
        unified: { source_count: 3, sources: "crossref,openalex, jcr" },
        partial: true,
        degraded_sources: ["doaj"],
      }

      result = described_class.new(data).normalize[:provenance]

      expect(result[:source_count]).to eq(3)
      expect(result[:sources]).to eq(%w[crossref openalex jcr])
      expect(result[:partial]).to eq(true)
      expect(result[:degraded_sources]).to eq(["doaj"])
    end
  end
end
