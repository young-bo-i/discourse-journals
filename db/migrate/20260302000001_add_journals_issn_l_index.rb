# frozen_string_literal: true

class AddJournalsIssnLIndex < ActiveRecord::Migration[7.0]
  disable_ddl_transaction!

  def up
    add_index :topic_custom_fields, [:value],
      where: "name = 'discourse_journals_issn_l'",
      name: "idx_tcf_journal_issn_l",
      algorithm: :concurrently,
      if_not_exists: true
  end

  def down
    remove_index :topic_custom_fields,
      name: "idx_tcf_journal_issn_l",
      algorithm: :concurrently,
      if_exists: true
  end
end
