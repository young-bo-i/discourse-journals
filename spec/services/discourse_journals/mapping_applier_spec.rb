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
    connections = [double("http")]

    allow(applier).to receive(:fetch_byids_concurrent).and_raise(StandardError, "boom")
    allow(applier).to receive(:reconnect_all!).and_return(connections)

    expect do
      applier.send(:safe_fetch, connections, [[1, 2, 3]])
    end.to raise_error(StandardError, "boom")
  end
end
