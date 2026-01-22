# frozen_string_literal: true

class AddJournalsCustomFieldIndex < ActiveRecord::Migration[7.0]
  disable_ddl_transaction!

  def up
    # 使用部分索引，只索引期刊相关的 custom_fields
    # 这比全表索引更小、更高效
    add_index :topic_custom_fields, [:name, :value],
      where: "name = 'discourse_journals_primary_id'",
      name: "idx_topic_custom_fields_journal_primary_id",
      algorithm: :concurrently,
      if_not_exists: true
  end

  def down
    remove_index :topic_custom_fields,
      name: "idx_topic_custom_fields_journal_primary_id",
      if_exists: true
  end
end
