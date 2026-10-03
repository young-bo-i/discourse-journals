# frozen_string_literal: true

describe DiscourseJournals::IndexNow do
  fab!(:topic)

  let(:url) { "#{Discourse.base_url}#{topic.relative_url}" }

  before do
    enable_current_plugin
    SiteSetting.discourse_journals_enabled = true
    SiteSetting.discourse_journals_indexnow_enabled = true
    Discourse.redis.del(described_class::QUEUE_KEY)
  end

  it "submits queued journal URLs with the site's key" do
    described_class.queue(topic)
    request =
      stub_request(:post, described_class::ENDPOINT).with(
        body: {
          host: Discourse.current_hostname,
          key: described_class.key,
          keyLocation: described_class.key_location,
          urlList: [url],
        },
      ).to_return(status: 202)

    expect(described_class.submit_pending!).to eq(1)
    expect(request).to have_been_requested
    expect(described_class.pending_count).to eq(0)
  end

  it "keeps URLs queued when the endpoint asks to retry later" do
    described_class.queue(topic)
    stub_request(:post, described_class::ENDPOINT).to_return(status: 429)

    expect(described_class.submit_pending!).to eq(0)
    expect(described_class.pending_count).to eq(1)
  end

  it "queues nothing while disabled" do
    SiteSetting.discourse_journals_indexnow_enabled = false

    described_class.queue(topic)

    expect(described_class.pending_count).to eq(0)
  end
end
