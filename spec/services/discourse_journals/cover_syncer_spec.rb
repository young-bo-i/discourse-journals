# frozen_string_literal: true

describe DiscourseJournals::CoverSyncer do
  fab!(:admin)
  fab!(:category)

  before do
    enable_current_plugin
    SiteSetting.discourse_journals_enabled = true
    SiteSetting.discourse_journals_category_id = category.id
    SiteSetting.discourse_journals_api_base_url = "https://journal.example.com"
    SiteSetting.discourse_journals_api_key = "jk_test_key"
    SiteSetting.discourse_journals_cover_sync_rate_limit = 100
  end

  let(:cover_sync) do
    DiscourseJournals::CoverSync.create!(user_id: admin.id, status: :processing, total: 0)
  end
  let(:legacy_path) { "/api/covers/image/Annals%20of%20Neurology" }

  def journal_topic(api_id: nil, issn_l: "0364-5134", cover_path: nil)
    topic = create_post(user: Discourse.system_user, category: category, raw: "journal").topic
    identity = { title: topic.title, cover_url: cover_path, cover_original_url: nil }
    fields = { discourse_journals_data: { identity: identity, metrics: {} }.to_json }
    fields[:discourse_journals_api_id] = api_id.to_s if api_id
    fields[:discourse_journals_issn_l] = issn_l if issn_l
    fields[:discourse_journals_cover_url] = "https://journal.example.com#{cover_path}" if cover_path
    topic.upsert_custom_fields(fields)
    topic
  end

  def attach_local_cover(topic)
    upload = Fabricate(:upload)
    topic.update_columns(image_upload_id: upload.id)
    topic.first_post.update_columns(image_upload_id: upload.id)
    UploadReference.ensure_exist!(upload_ids: [upload.id], target: topic.first_post)
    upload
  end

  def stub_cover(api_id, status:, headers: {})
    stub_request(:head, "https://journal.example.com/api/covers/preview/#{api_id}.webp").to_return(
      status: status,
      headers: headers,
    )
  end

  def cover_field(topic)
    topic.reload.custom_fields["discourse_journals_cover_url"]
  end

  def run_sync(**options)
    described_class.new(cover_sync: cover_sync, **options).run!
  end

  describe "#run!" do
    it "switches a journal to its upstream cover and deletes the local cover it replaces" do
      topic = journal_topic(api_id: 1, cover_path: legacy_path)
      upload = attach_local_cover(topic)
      stub_cover(1, status: 200, headers: { "ETag" => '"a855e4f0a5126ab1"' })

      stats = run_sync

      expect(cover_field(topic)).to eq(
        "https://journal.example.com/api/covers/preview/1.webp?v=a855e4f0a5126ab1",
      )
      expect(topic.first_post.cooked).to include("/api/covers/preview/1.webp?v=a855e4f0a5126ab1")
      expect(topic.image_upload_id).to be_nil
      expect(Upload.exists?(upload.id)).to eq(false)
      expect(stats).to include("with_cover" => 1, "updated" => 1, "purged" => 1, "errors" => 0)
    end

    it "returns a journal without an upstream cover to its default and keeps its local cover" do
      topic = journal_topic(api_id: 2, cover_path: legacy_path)
      upload = attach_local_cover(topic)
      stub_cover(2, status: 404)

      stats = run_sync

      expect(cover_field(topic)).to be_nil
      expect(topic.image_upload_id).to eq(upload.id)
      expect(stats).to include("cleared" => 1, "purged" => 0)
    end

    it "leaves a cover that upstream reports unchanged alone" do
      topic = journal_topic(api_id: 5, cover_path: "/api/covers/preview/5.webp?v=29f75b7daa06eb76")
      topic.update_columns(updated_at: 1.day.ago)
      stub_request(:head, "https://journal.example.com/api/covers/preview/5.webp").with(
        headers: {
          "If-None-Match" => '"29f75b7daa06eb76"',
        },
      ).to_return(status: 304)

      stats = run_sync

      expect(topic.reload.updated_at).to be < 1.hour.ago
      expect(stats).to include("unchanged" => 1, "updated" => 0)
    end

    it "follows a merged journal to the id it now lives under" do
      topic = journal_topic(api_id: 207)
      stub_cover(207, status: 301, headers: { "Location" => "/api/covers/preview/258.webp" })
      stub_cover(258, status: 200, headers: { "ETag" => '"74314c293b4df29b"' })

      run_sync

      expect(cover_field(topic)).to eq(
        "https://journal.example.com/api/covers/preview/258.webp?v=74314c293b4df29b",
      )
    end

    it "skips journals that cannot have a cover and clears leftovers of the old cover system" do
      without_issn = journal_topic(api_id: 3, issn_l: nil)
      without_issn.update_columns(image_upload_id: Upload.maximum(:id).to_i + 1000)
      without_issn.upsert_custom_fields(discourse_journals_cover_url_hash: "fingerprint")
      without_api_id = journal_topic(issn_l: nil, cover_path: legacy_path)
      current_path = "/api/covers/preview/9.webp?v=0a2b1ebae584e432"
      unverifiable = journal_topic(issn_l: nil, cover_path: current_path)

      stats = run_sync

      expect(without_issn.reload.image_upload_id).to be_nil
      expect(without_issn.custom_fields["discourse_journals_cover_url_hash"]).to be_nil
      expect(cover_field(without_api_id)).to be_nil
      expect(cover_field(unverifiable)).to eq("https://journal.example.com#{current_path}")
      expect(stats).to include("skipped" => 3, "cleared" => 1, "legacy_cleaned" => 2, "errors" => 0)
      expect(a_request(:head, %r{/api/covers/preview/})).not_to have_been_made
    end

    it "stops without changing anything when the upstream cover store is down" do
      topic = journal_topic(api_id: 1, cover_path: legacy_path)
      stub_cover(1, status: 503)

      expect { run_sync }.to raise_error(DiscourseJournals::ApiClient::CoverStorageUnavailableError)
      expect(cover_field(topic)).to eq("https://journal.example.com#{legacy_path}")
      expect(cover_sync.reload.checkpoint).not_to have_key("last_topic_id")
    end

    it "leaves a topic whose probe failed untouched and finishes the others" do
      failing = journal_topic(api_id: 1, cover_path: legacy_path)
      healthy = journal_topic(api_id: 2)
      stub_cover(1, status: 500)
      stub_cover(2, status: 200, headers: { "ETag" => '"74314c293b4df29b"' })

      stats = run_sync

      expect(cover_field(failing)).to eq("https://journal.example.com#{legacy_path}")
      expect(cover_field(healthy)).to be_present
      expect(stats).to include("errors" => 1, "updated" => 1)
    end

    it "resumes after the last checkpointed topic" do
      done = journal_topic(api_id: 1)
      remaining = journal_topic(api_id: 2)
      cover_sync.update!(checkpoint: { "last_topic_id" => done.id, "processed" => 1 })
      stub_cover(2, status: 404)

      run_sync

      expect(a_request(:head, "https://journal.example.com/api/covers/preview/1.webp")).not_to(
        have_been_made,
      )
      expect(cover_sync.reload.checkpoint).to include(
        "last_topic_id" => remaining.id,
        "processed" => 2,
      )
    end

    it "stops before the next batch once the run is paused" do
      journal_topic(api_id: 1)

      expect { run_sync(cancel_check: -> { true }) }.to raise_error(described_class::PausedError)
      expect(a_request(:head, %r{/api/covers/preview/})).not_to have_been_made
    end
  end
end
