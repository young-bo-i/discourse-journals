# frozen_string_literal: true

describe DiscourseJournals::MappingAnalysis do
  before { enable_current_plugin }

  describe "#can_apply?" do
    it "allows apply only before the first sync run" do
      analysis = described_class.new(user_id: 1, status: :completed, apply_status: :not_applied)

      expect(analysis.can_apply?).to eq(true)

      analysis.apply_status = :sync_processing
      expect(analysis.can_apply?).to eq(false)

      analysis.apply_status = :sync_completed
      expect(analysis.can_apply?).to eq(false)
    end
  end

  describe "#can_resume_apply?" do
    it "allows resume from paused, failed, or stale processing states" do
      analysis = described_class.new(user_id: 1, status: :completed, apply_status: :sync_paused)
      expect(analysis.can_resume_apply?).to eq(true)

      analysis.apply_status = :sync_failed
      expect(analysis.can_resume_apply?).to eq(true)

      analysis.apply_status = :sync_processing
      analysis.apply_started_at = 20.minutes.ago
      expect(analysis.can_resume_apply?).to eq(true)

      analysis.apply_status = :sync_completed
      expect(analysis.can_resume_apply?).to eq(false)
    end

    it "does not offer resume while the running applier still holds the lock" do
      analysis =
        described_class.new(
          user_id: 1,
          status: :completed,
          apply_status: :sync_processing,
          apply_started_at: 20.minutes.ago,
        )

      DiscourseJournals::ApplyLock.synchronize do
        expect(analysis.can_resume_apply?).to eq(false)
      end
      expect(analysis.can_resume_apply?).to eq(true)
    end

    it "does not allow resume for active processing jobs" do
      analysis =
        described_class.new(
          user_id: 1,
          status: :completed,
          apply_status: :sync_processing,
          apply_started_at: 2.minutes.ago,
        )

      expect(analysis.can_resume_apply?).to eq(false)
    end
  end
end
