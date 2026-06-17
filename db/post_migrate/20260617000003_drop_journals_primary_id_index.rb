# frozen_string_literal: true

# Drops the orphaned idx_topic_custom_fields_journal_primary_id index. The
# `discourse_journals_primary_id` custom field is never written or read anywhere
# in the plugin, so this partial index is always empty yet its predicate is
# evaluated on every write to the shared topic_custom_fields table.
# Post-deploy + concurrent + if_exists so it is safe on a live DB.
class DropJournalsPrimaryIdIndex < ActiveRecord::Migration[7.0]
  disable_ddl_transaction!

  def up
    remove_index :topic_custom_fields,
      name: "idx_topic_custom_fields_journal_primary_id",
      algorithm: :concurrently,
      if_exists: true
  end

  def down
    add_index :topic_custom_fields, [:name, :value],
      where: "name = 'discourse_journals_primary_id'",
      name: "idx_topic_custom_fields_journal_primary_id",
      algorithm: :concurrently,
      if_not_exists: true
  end
end
