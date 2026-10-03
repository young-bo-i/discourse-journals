# frozen_string_literal: true

describe DiscourseJournals::CoverSync do
  before { enable_current_plugin }

  fab!(:admin)

  def cover_sync(status, heartbeat:)
    described_class.create!(
      user_id: admin.id,
      status: status,
      checkpoint: {
        "heartbeat" => heartbeat.to_i,
        "processed" => 40,
      },
      total: 100,
    )
  end

  it "counts an active run with a recent heartbeat as running" do
    sync = cover_sync(:processing, heartbeat: 1.minute.ago)

    expect(sync.running?).to eq(true)
    expect(sync.can_resume?).to eq(false)
    expect(described_class.running?).to eq(true)
  end

  it "treats an active run whose heartbeat went quiet as interrupted and resumable" do
    sync = cover_sync(:processing, heartbeat: 20.minutes.ago)

    expect(sync.running?).to eq(false)
    expect(sync.can_resume?).to eq(true)
    expect(sync.summary).to include(
      status: "failed",
      processed: 40,
      error_message: I18n.t("discourse_journals.cover_sync.errors.interrupted"),
    )
  end

  it "lets paused and failed runs resume but not completed ones" do
    expect(cover_sync(:paused, heartbeat: 1.hour.ago).can_resume?).to eq(true)
    expect(cover_sync(:failed, heartbeat: 1.hour.ago).can_resume?).to eq(true)
    expect(cover_sync(:completed, heartbeat: 1.hour.ago).can_resume?).to eq(false)
  end
end
