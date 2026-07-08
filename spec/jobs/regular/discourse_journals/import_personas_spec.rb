# frozen_string_literal: true

describe Jobs::DiscourseJournals::ImportPersonas do
  before { enable_current_plugin }

  it "creates persona users from the import rows and records stats" do
    import =
      DiscourseJournals::PersonaImport.create!(
        user_id: Discourse.system_user.id,
        status: :pending,
        total: 2,
        rows_data: [{ "username" => "alice.k" }, { "username" => "bob.m" }],
      )

    described_class.new.execute(import_id: import.id, user_id: Discourse.system_user.id)

    import.reload
    expect(import.status).to eq("completed")
    expect(import.stats["created"]).to eq(2)
    expect(import.rows_data).to eq([]) # cleared on completion
    expect(User.where(username_lower: %w[alice.k bob.m]).count).to eq(2)
  end

  it "skips usernames that already exist without creating duplicates" do
    DiscourseJournals::PersonaBuilder.new.build!({ "username" => "existing.p" })

    import =
      DiscourseJournals::PersonaImport.create!(
        user_id: Discourse.system_user.id,
        status: :pending,
        total: 1,
        rows_data: [{ "username" => "existing.p" }],
      )

    expect {
      described_class.new.execute(import_id: import.id, user_id: Discourse.system_user.id)
    }.not_to change { User.where(username_lower: "existing.p").count }

    expect(import.reload.stats["skipped"]).to eq(1)
  end
end
