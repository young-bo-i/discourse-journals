# frozen_string_literal: true

describe DiscourseJournals::JournalSummary do
  let(:data) do
    {
      publication: {
        publisher_name: "Elsevier",
        country_name: "Netherlands",
      },
      jcr: {
        data: [{ year: 2025, impact_factor: 6.1, quartile: "Q1" }],
      },
      cas_partition: {
        data: [{ major_category: "化学", major_quartile: "2 [40/200]", top: "否" }],
      },
      open_access: {
        is_oa: true,
        is_in_doaj: false,
      },
      metrics: {
        works_count: 5321,
        cited_by_count: 98_765,
        h_index: "None",
      },
    }
  end

  def summary(title: "Talanta", issn: "0039-9140", data: self.data)
    I18n.with_locale(:zh_CN) { described_class.new(title: title, issn: issn, data: data).to_s }
  end

  it "leads with the journal's metrics and skips values the record does not have" do
    expect(summary).to eq(
      "Talanta：2025 年影响因子 6.1，JCR Q1，中科院分区 化学 2 区。" \
        "ISSN 0039-9140，Elsevier 出版，国家/地区：Netherlands。" \
        "开放获取。发文 5321 篇，被引 98765 次。",
    )
  end

  it "falls back to SJR for journals without a JCR impact factor" do
    data.delete(:jcr)
    data[:scimago] = { data: [{ sjr: "0.17", best_quartile: "Q4" }] }

    expect(summary).to start_with("Talanta：SJR 0.17（Q4），中科院分区 化学 2 区。")
  end

  it "stops before a sentence would push the description past the displayed length" do
    data[:publication][:publisher_name] = "A" * 120

    expect(summary).to eq("Talanta：2025 年影响因子 6.1，JCR Q1，中科院分区 化学 2 区。")
  end

  it "returns nothing when the record holds no facts to describe" do
    expect(summary(issn: nil, data: nil)).to eq("")
  end
end
