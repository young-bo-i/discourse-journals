# frozen_string_literal: true

describe DiscourseJournals::Excel::Importer do
  before { enable_current_plugin }

  fab!(:category)

  let(:profile) { DiscourseJournals::ProfileStore.defaults }

  def build_xlsx(headers:, rows:)
    require "caxlsx"

    file = Tempfile.new(["journals", ".xlsx"])
    Axlsx::Package.new do |p|
      p.workbook.add_worksheet(name: "journals") do |sheet|
        sheet.add_row(headers)
        rows.each { |row| sheet.add_row(row) }
      end
      p.serialize(file.path)
    end
    file
  end

  it "parses impact factors and JSON columns" do
    headers = [
      profile.dig(:columns, :issn),
      profile.dig(:columns, :name),
      profile.dig(:columns, :impact_factors),
      profile.dig(:columns, :cas),
      profile.dig(:columns, :wos),
    ]

    file =
      build_xlsx(
        headers:,
        rows: [
          [
            "1234-5678",
            "Journal of Example Studies",
            "2021=2.31;2022=;2023=3.120",
            JSON.generate({ "2025" => { "published_at" => "2025-03-20", "rows" => [] } }),
            JSON.generate({ "2025" => { "published_at" => "2025-06-18", "jcr_rows" => [], "jci_rows" => [] } }),
          ],
        ],
      )

    importer = described_class.new(file_path: file.path, profile:)
    rows = importer.each_row.to_a

    expect(rows.size).to eq(1)
    expect(rows[0][:issn]).to eq("1234-5678")
    expect(rows[0][:impact_factors]).to eq({ 2021 => "2.31", 2022 => nil, 2023 => "3.12" })
    expect(rows[0][:cas].dig("2025", "published_at")).to eq("2025-03-20")
    expect(rows[0][:wos].dig("2025", "published_at")).to eq("2025-06-18")
  ensure
    file&.close!
  end

  it "rejects impact factors with more than 3 decimals" do
    headers = [
      profile.dig(:columns, :issn),
      profile.dig(:columns, :name),
      profile.dig(:columns, :impact_factors),
      profile.dig(:columns, :cas),
      profile.dig(:columns, :wos),
    ]

    file =
      build_xlsx(
        headers:,
        rows: [["1234-5678", "Journal", "2021=2.1234", "{}", "{}"]],
      )

    importer = described_class.new(file_path: file.path, profile:)
    expect { importer.each_row.to_a }.to raise_error(Discourse::InvalidParameters)
  ensure
    file&.close!
  end
end

