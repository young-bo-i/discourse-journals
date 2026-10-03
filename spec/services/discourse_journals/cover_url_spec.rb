# frozen_string_literal: true

describe DiscourseJournals::CoverUrl do
  before do
    enable_current_plugin
    SiteSetting.discourse_journals_api_base_url = "https://journal.example.com"
  end

  let(:preview_path) { "/api/covers/preview/7.webp?v=0a2b1ebae584e432" }

  describe ".from_api" do
    it "reads preview_url and ignores the deprecated cover_url alias" do
      expect(described_class.from_api({ preview_url: preview_path, cover_url: "/stale" })).to eq(
        preview_path,
      )
      expect(described_class.from_api({ cover_url: preview_path })).to be_nil
      expect(described_class.from_api(nil)).to be_nil
    end
  end

  describe ".preview_path" do
    it "rebuilds upstream's preview_url from the journal id and content hash" do
      expect(described_class.preview_path("7", "0a2b1ebae584e432")).to eq(preview_path)
    end
  end

  describe ".version" do
    it "returns the content hash of a current preview path only" do
      expect(described_class.version(preview_path)).to eq("0a2b1ebae584e432")
      expect(described_class.version("/api/covers/image/Annals%20of%20Neurology")).to be_nil
      expect(described_class.version(nil)).to be_nil
    end
  end

  describe ".displayable" do
    it "drops the dead name-addressed covers and passes every other url through" do
      legacy = "https://journal.example.com/api/covers/image/Annals%20of%20Neurology"

      expect(described_class.legacy?(legacy)).to eq(true)
      expect(described_class.displayable(legacy)).to be_nil
      expect(described_class.displayable("https://journal.example.com#{preview_path}")).to eq(
        "https://journal.example.com#{preview_path}",
      )
      expect(described_class.displayable("")).to be_nil
    end
  end

  describe ".absolute" do
    it "prefixes relative paths with the base url and leaves absolute urls alone" do
      expect(described_class.absolute(preview_path)).to eq(
        "https://journal.example.com#{preview_path}",
      )
      expect(described_class.absolute("https://cdn.example.com/a.webp")).to eq(
        "https://cdn.example.com/a.webp",
      )
      expect(described_class.absolute(" ")).to be_nil
    end

    it "does not double the slash when the base url ends with one" do
      SiteSetting.discourse_journals_api_base_url = "https://journal.example.com/"

      expect(described_class.absolute(preview_path)).to eq(
        "https://journal.example.com#{preview_path}",
      )
    end
  end

  describe ".relative" do
    it "turns an absolute url on the base back into its path" do
      expect(described_class.relative("https://journal.example.com#{preview_path}")).to eq(
        preview_path,
      )
      expect(described_class.relative("https://elsewhere.example.com/a.webp")).to eq(
        "https://elsewhere.example.com/a.webp",
      )
      expect(described_class.relative(nil)).to be_nil
    end
  end
end
