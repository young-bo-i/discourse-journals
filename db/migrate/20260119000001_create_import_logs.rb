# frozen_string_literal: true

class CreateImportLogs < ActiveRecord::Migration[7.0]
  def change
    create_table :discourse_journals_import_logs do |t|
      t.integer :upload_id, null: false
      t.integer :user_id, null: false
      t.integer :status, default: 0, null: false
      t.integer :total_records, default: 0
      t.integer :processed_records, default: 0
      t.integer :created_count, default: 0
      t.integer :updated_count, default: 0
      t.integer :skipped_count, default: 0
      t.integer :error_count, default: 0
      t.jsonb :errors_data, default: []
      t.text :result_message
      t.datetime :started_at
      t.datetime :completed_at
      t.timestamps
    end

    add_index :discourse_journals_import_logs, :upload_id
    add_index :discourse_journals_import_logs, :user_id
    add_index :discourse_journals_import_logs, :status
    add_index :discourse_journals_import_logs, :created_at
  end
end
