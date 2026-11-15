# frozen_string_literal: true

require_relative "../../db/post_migrate/20261115063354_restore_journal_category_definition_topic"

RSpec.describe RestoreJournalCategoryDefinitionTopic do
  fab!(:category, :category_with_definition)
  fab!(:journal_topic) { Fabricate(:topic, category: category) }

  before do
    @original_verbose = ActiveRecord::Migration.verbose
    ActiveRecord::Migration.verbose = false
  end

  after { ActiveRecord::Migration.verbose = @original_verbose }

  it "unflags and reopens the category's About topic and leaves outdated journals alone" do
    about = category.topic
    [about, journal_topic].each do |topic|
      topic.upsert_custom_fields(discourse_journals_outdated: "2026-10-04T12:00:00Z")
      topic.update_columns(closed: true)
    end

    described_class.new.up

    expect(about.reload.custom_fields["discourse_journals_outdated"]).to be_nil
    expect(about.closed).to eq(false)
    expect(about.first_post.reload.baked_version).to be_nil
    expect(journal_topic.reload.custom_fields["discourse_journals_outdated"]).to be_present
    expect(journal_topic.closed).to eq(true)
  end
end
