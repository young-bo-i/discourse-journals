# frozen_string_literal: true

describe DiscourseJournals::PerformanceLogger do
  before do
    enable_current_plugin
    allow(Rails.logger).to receive(:info)
  end

  it "does not log when performance logging is disabled" do
    SiteSetting.discourse_journals_performance_logging = false

    described_class.log("cover.download", topic_id: 1, elapsed_ms: 12.3)

    expect(Rails.logger).not_to have_received(:info)
  end

  it "logs structured timing information when enabled" do
    SiteSetting.discourse_journals_performance_logging = true

    described_class.measure("cover.download", topic_id: 1, source_type: "remote") { :downloaded }

    expect(Rails.logger).to have_received(:info).with(
      a_string_including("[DiscourseJournals::Perf]"),
    )
    expect(Rails.logger).to have_received(:info).with(
      a_string_including("phase=cover.download"),
    )
  end
end
