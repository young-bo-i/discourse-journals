# frozen_string_literal: true

describe Jobs::DiscourseJournals::RerenderLayout do
  fab!(:category)

  fab!(:journal_post) do
    create_post(
      user: Discourse.system_user,
      title: "Journal of Layouts",
      raw: "journal body text",
      category: category.id,
    )
  end

  before do
    enable_current_plugin
    SiteSetting.discourse_journals_category_id = category.id
    journal_post.topic.upsert_custom_fields(
      discourse_journals_data: {
        identity: {
          title: "Journal of Layouts",
        },
        metrics: {
          works_count: 42,
        },
      }.to_json,
    )
  end

  def layout_state
    PluginStore.get(DiscourseJournals::PLUGIN_NAME, described_class::STATE_KEY)
  end

  describe "#execute" do
    it "rewrites journal posts once for the current layout version" do
      described_class.new.execute({})

      expect(journal_post.reload.cooked).to include(%(<article class="dj-journal">))
      expect(layout_state).to include(
        "version" => DiscourseJournals::MasterRecordRenderer::LAYOUT_VERSION,
      )

      journal_post.update_columns(cooked: "<p>edited</p>")
      described_class.new.execute({})

      expect(journal_post.reload.cooked).to eq("<p>edited</p>")
    end

    it "keeps going while a mapping apply holds the lock" do
      stub_const(described_class, :BATCH_PAUSE, 0) do
        DiscourseJournals::ApplyLock.synchronize { described_class.new.execute({}) }
      end

      expect(journal_post.reload.cooked).to include(%(<article class="dj-journal">))
    end
  end
end
