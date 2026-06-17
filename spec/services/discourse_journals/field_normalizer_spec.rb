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
end
