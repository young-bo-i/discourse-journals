# frozen_string_literal: true

describe DiscourseJournals::AdminMappingController do
  fab!(:admin)

  before do
    enable_current_plugin
    SiteSetting.discourse_journals_enabled = true
  end

  describe "POST /admin/journals/mapping/apply" do
    it "refuses to start while a cover sync is running" do
      sign_in(admin)
      DiscourseJournals::MappingAnalysis.create!(
        user_id: admin.id,
        status: :completed,
        apply_status: :not_applied,
      )
      DiscourseJournals::CoverSync.create!(
        user_id: admin.id,
        status: :processing,
        checkpoint: {
          "heartbeat" => Time.current.to_i,
        },
      )

      post "/admin/journals/mapping/apply.json"

      expect(response.status).to eq(422)
      expect(response.parsed_body["errors"]).to eq(
        [I18n.t("discourse_journals.cover_sync.errors.cover_sync_running")],
      )
    end
  end

  describe "POST /admin/journals/mapping/apply_resume" do
    it "refuses to start a second applier while a sync holds the apply lock" do
      sign_in(admin)
      DiscourseJournals::MappingAnalysis.create!(
        user_id: admin.id,
        status: :completed,
        apply_status: :sync_processing,
        apply_started_at: 1.hour.ago,
      )

      DiscourseJournals::ApplyLock.synchronize do
        expect_not_enqueued_with(job: Jobs::DiscourseJournals::ApplyMapping) do
          post "/admin/journals/mapping/apply_resume.json"
        end
      end

      expect(response.status).to eq(422)
      expect(response.parsed_body["errors"]).to eq(
        [I18n.t("discourse_journals.errors.apply_running")],
      )
    end
  end
end
