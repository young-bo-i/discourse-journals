# frozen_string_literal: true

# Per-record title-key lookups in JournalUpserter#find_existing_topic otherwise
# fall back to the non-selective core (value) index. Mirror the issn_l partial
# index. Concurrent + if_not_exists so it is safe to run on a live, populated DB.
class AddJournalsNormalizedTitleKeyIndex < ActiveRecord::Migration[7.0]
  disable_ddl_transaction!

  def up
    add_index :topic_custom_fields, [:value],
      where: "name = 'discourse_journals_normalized_title_key'",
      name: "idx_tcf_journal_normalized_title_key",
      algorithm: :concurrently,
      if_not_exists: true
  end

  def down
    remove_index :topic_custom_fields,
      name: "idx_tcf_journal_normalized_title_key",
      algorithm: :concurrently,
      if_exists: true
  end
end
