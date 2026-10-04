# frozen_string_literal: true

describe Jobs::DiscourseJournals::ApplyMapping do
  fab!(:analysis) do
    DiscourseJournals::MappingAnalysis.create!(
      user_id: Discourse.system_user.id,
      status: :completed,
      apply_status: :not_applied,
    )
  end

  before do
    enable_current_plugin
    SiteSetting.discourse_journals_enabled = true
    Discourse.redis.del(DiscourseJournals::ApplyLock::KEY)
  end

  describe "#execute" do
    it "leaves the analysis untouched while another apply holds the lock" do
      DiscourseJournals::ApplyLock.synchronize do
        described_class.new.execute(analysis_id: analysis.id, user_id: analysis.user_id)
      end

      expect(analysis.reload.apply_status).to eq("not_applied")
    end
  end
end
