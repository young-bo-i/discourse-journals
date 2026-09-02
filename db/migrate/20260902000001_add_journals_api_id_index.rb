# frozen_string_literal: true

# TitleMatcher's second matching phase looks topics up by discourse_journals_api_id,
# but the field had no partial index — and until the FieldNormalizer fix it was
# never written at all, so the phase was dead. Mirror the issn_l / title-key
# partial indexes. Concurrent + if_not_exists so it is safe on a live, populated DB.
class AddJournalsApiIdIndex < ActiveRecord::Migration[7.0]
  disable_ddl_transaction!

  def up
    add_index :topic_custom_fields, [:value],
      where: "name = 'discourse_journals_api_id'",
      name: "idx_tcf_journal_api_id",
      algorithm: :concurrently,
      if_not_exists: true
  end

  def down
    remove_index :topic_custom_fields,
      name: "idx_tcf_journal_api_id",
      algorithm: :concurrently,
      if_exists: true
  end
end
