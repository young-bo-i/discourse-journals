# frozen_string_literal: true

describe DiscourseJournals::ApiClient do
  before do
    enable_current_plugin
    SiteSetting.discourse_journals_api_base_url = "https://journal.example.com"
    SiteSetting.discourse_journals_api_key = "jk_test_key"
  end

  def stub_api(query, status: 200, body: {})
    stub_request(:get, "https://journal.example.com/api/open/journals")
      .with(query: query, headers: { "X-API-Key" => "jk_test_key" })
      .to_return(status: status, body: body.to_json, headers: { "Content-Type" => "application/json" })
  end

  describe ".ensure_configured!" do
    it "raises when no key is set" do
      SiteSetting.discourse_journals_api_key = ""

      expect { described_class.ensure_configured! }.to raise_error(described_class::AuthError)
    end

    it "passes once a key is set" do
      expect { described_class.ensure_configured! }.not_to raise_error
    end
  end

  describe "#fetch_journal_page" do
    it "sends the key, the cursor and the slim field list" do
      stub_api(
        { "pageSize" => "2000", "fields" => described_class::LIST_FIELDS, "afterId" => "2013" },
        body: {
          success: true,
          data: {
            rows: [{ "unified" => { "id" => 2014 } }],
            nextCursor: 4013,
            hasMore: true,
          },
        },
      )

      result = described_class.new.fetch_journal_page(cursor: 2013)

      expect(result[:rows].size).to eq(1)
      expect(result[:next_cursor]).to eq(4013)
      expect(result[:has_more]).to eq(true)
    end
  end

  describe "#fetch_journals_by_ids" do
    it "uses the /journals selector that replaced the retired byIds endpoint" do
      stub_api(
        { "ids" => "1,2", "full" => "1", "resolveIds" => "follow" },
        body: {
          success: true,
          data: {
            rows: [{ "unified" => { "id" => 1 } }],
            redirects: { "2" => nil },
            lookup: { "key" => "ids" },
          },
        },
      )

      result = described_class.new.fetch_journals_by_ids([1, 2])

      expect(result[:rows].size).to eq(1)
      expect(result[:redirects]).to eq({ "2" => nil })
    end

    it "refuses a batch larger than the upstream selector cap" do
      expect { described_class.new.fetch_journals_by_ids((1..201).to_a) }.to raise_error(
        described_class::Error,
        /200/,
      )
    end

    it "short-circuits an empty batch without calling upstream" do
      expect(described_class.new.fetch_journals_by_ids([])).to eq(
        { rows: [], redirects: {}, lookup: {} },
      )
    end
  end

  describe "error handling" do
    it "raises AuthError on 401 without retrying" do
      stub = stub_api(
        { "pageSize" => "2000", "fields" => described_class::LIST_FIELDS },
        status: 401,
        body: { success: false, error: "invalid_api_key" },
      )

      expect { described_class.new.fetch_journal_page }.to raise_error(described_class::AuthError)
      expect(stub).to have_been_requested.once
    end

    it "surfaces the successor path on 410 endpoint_gone" do
      stub_request(:get, "https://journal.example.com/api/open/journals")
        .with(query: hash_including({}))
        .to_return(
          status: 410,
          body: {
            success: false,
            error: "endpoint_gone",
            successor: "/api/open/journals?ids=1,2,3&resolveIds=follow",
          }.to_json,
        )

      expect { described_class.new.fetch_journal_page }.to raise_error(
        described_class::EndpointGoneError,
        /resolveIds=follow/,
      )
    end
  end
end
