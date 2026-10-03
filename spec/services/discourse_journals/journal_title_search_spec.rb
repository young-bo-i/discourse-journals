# frozen_string_literal: true

describe DiscourseJournals::JournalTitleSearch do
  fab!(:category)
  fab!(:nature) { Fabricate(:topic, category: category, title: "Nature Neuroscience Journal") }
  fab!(:advances) { Fabricate(:topic, category: category, title: "Advances in Nature Studies") }
  fab!(:biology) { Fabricate(:topic, category: category, title: "Annals of Applied Biology") }
  fab!(:elsewhere) { Fabricate(:topic, title: "Nature lovers chatting about birds") }

  before do
    enable_current_plugin
    SiteSetting.discourse_journals_enabled = true
    SiteSetting.discourse_journals_category_id = category.id
  end

  def search(query)
    described_class.new(query, guardian: Guardian.new).topic_ids
  end

  describe "#topic_ids" do
    it "matches journal titles containing the query, starting with those that begin with it" do
      expect(search("nature")).to eq([nature.id, advances.id])
    end

    it "matches every word of the query in any order" do
      expect(search("biology applied")).to eq([biology.id])
    end

    it "finds a journal by its ISSN-L with or without the hyphen" do
      biology.upsert_custom_fields(discourse_journals_issn_l: "0003-474X")

      expect([search("0003-474x"), search("0003474X")]).to eq([[biology.id], [biology.id]])
    end

    it "returns nothing for blank input" do
      expect(search("  ")).to eq([])
    end
  end
end
