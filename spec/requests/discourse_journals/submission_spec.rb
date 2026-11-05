# frozen_string_literal: true

describe DiscourseJournals::SubmissionController do
  let(:upstream_url) { "https://journal.example.com/api/open/journals/42/submission/latex" }
  let(:browser) do
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36"
  end
  let(:crawler) { "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko); compatible; ShapBot/0.1.0" }

  before do
    enable_current_plugin
    SiteSetting.discourse_journals_api_base_url = "https://journal.example.com"
    SiteSetting.discourse_journals_api_key = "jk_test_key"
  end

  describe "GET /journals/:api_id/submission/:kind" do
    it "hands browsers the upstream file, marked as not for indexing" do
      stub_request(:get, upstream_url).with(headers: { "X-API-Key" => "jk_test_key" }).to_return(
        status: 200,
        body: "zip-bytes",
        headers: {
          "Content-Type" => "application/zip",
        },
      )

      get "/journals/42/submission/latex", headers: { "User-Agent" => browser }

      expect(response.status).to eq(200)
      expect(response.body).to eq("zip-bytes")
      expect(response.headers["Content-Disposition"]).to include("42-latex.zip")
      expect(response.headers["X-Robots-Tag"]).to eq("noindex, nofollow")
    end

    it "turns crawlers away without fetching the file upstream" do
      upstream = stub_request(:get, upstream_url)

      get "/journals/42/submission/latex", headers: { "User-Agent" => crawler }

      expect(response.status).to eq(403)
      expect(response.headers["X-Robots-Tag"]).to eq("noindex, nofollow")
      expect(upstream).not_to have_been_requested
    end
  end
end
