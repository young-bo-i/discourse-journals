# frozen_string_literal: true

describe DiscourseJournals::PersonaFileParser do
  describe ".parse" do
    it "parses a CSV with a username header plus optional columns" do
      csv = "username,name,field\nwei.zhang,Zhang Wei,化学\nmchen,,\n"

      rows = described_class.parse(csv, "personas.csv")

      expect(rows).to eq(
        [
          { "username" => "wei.zhang", "name" => "Zhang Wei", "field" => "化学" },
          { "username" => "mchen", "name" => "", "field" => "" },
        ],
      )
    end

    it "parses a JSON array and keeps extra columns (for custom user fields)" do
      json = [{ "username" => "lwang", "机构" => "清华大学" }].to_json

      expect(described_class.parse(json, "personas.json")).to eq(
        [{ "username" => "lwang", "机构" => "清华大学" }],
      )
    end

    it "skips rows without a username" do
      csv = "username,name\n,No Name\nvalid_user,Someone\n"

      expect(described_class.parse(csv).map { |row| row["username"] }).to eq(["valid_user"])
    end

    it "raises when the CSV header has no username column" do
      expect { described_class.parse("name\nSomeone\n") }.to raise_error(described_class::ParseError)
    end

    it "raises on empty content" do
      expect { described_class.parse("   ") }.to raise_error(described_class::ParseError)
    end
  end
end
