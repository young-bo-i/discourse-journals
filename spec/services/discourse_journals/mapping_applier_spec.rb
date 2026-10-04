# frozen_string_literal: true

describe DiscourseJournals::MappingApplier do
  before { enable_current_plugin }

  fab!(:analysis) do
    DiscourseJournals::MappingAnalysis.create!(user_id: 1, status: :completed)
  end

  it "creates all api_only records in the action plan" do
    applier = described_class.new(analysis: analysis)

    applier.send(
      :process_api_only,
      [
        {
          "api" => [
            { "api_id" => 11 },
            { "api_id" => 22 },
          ],
        },
      ],
    )

    expect(applier.instance_variable_get(:@create_ids)).to eq([11, 22])
  end

  it "raises fetch errors instead of silently skipping a batch" do
    applier = described_class.new(analysis: analysis)
    client = instance_double(DiscourseJournals::ApiClient, reconnect!: nil)

    allow(applier).to receive(:fetch_details_concurrent).and_raise(StandardError, "boom")

    expect do
      applier.send(:safe_fetch, [client], [[1, 2, 3]])
    end.to raise_error(StandardError, "boom")
    expect(client).to have_received(:reconnect!)
  end

  describe "duplicate topics" do
    fab!(:category)

    it "trashes copies of an upstream record and points their URLs at the kept topic" do
      SiteSetting.discourse_journals_enabled = true
      SiteSetting.discourse_journals_category_id = category.id
      SiteSetting.discourse_journals_api_key = "jk_test"
      keep = Fabricate(:topic, category: category)
      copy = Fabricate(:topic, category: category)
      analysis.update!(
        details_data: {
          "_action_plan" => {
            "merges" => {
              copy.id.to_s => keep.id,
            },
          },
        },
      )

      stats = described_class.new(analysis: analysis).run!

      expect(stats[:merged]).to eq(1)
      expect(Topic.with_deleted.find(copy.id).deleted_at).to be_present
      expect(Permalink.find_by_url(copy.relative_url).topic_id).to eq(keep.id)
    end
  end

  describe "upstream id changes" do
    it "re-points a merged api_id at the topic already tracking it" do
      applier = described_class.new(analysis: analysis)
      applier.instance_variable_set(:@update_map, { 207 => 999 })

      applier.send(:absorb_redirects!, { "207" => 258 })

      expect(applier.send(:lookup_action, 258)).to eq([:update, 999])
    end

    it "queues a topic whose journal upstream deleted for the outdated banner" do
      applier = described_class.new(analysis: analysis)
      applier.instance_variable_set(:@update_map, { 183 => 555 })

      applier.send(:absorb_redirects!, { "183" => nil })

      expect(applier.instance_variable_get(:@gone_topic_ids)).to eq([555])
    end

    it "ignores redirects for ids this sync does not track" do
      applier = described_class.new(analysis: analysis)

      applier.send(:absorb_redirects!, { "1" => 2, "3" => nil })

      expect(applier.instance_variable_get(:@redirect_aliases)).to be_empty
      expect(applier.instance_variable_get(:@gone_topic_ids)).to be_empty
    end
  end
end
