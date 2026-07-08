# frozen_string_literal: true

class CreateDiscourseJournalsPersonaImports < ActiveRecord::Migration[7.0]
  def change
    create_table :discourse_journals_persona_imports do |t|
      t.integer :user_id, null: false
      t.integer :status, default: 0, null: false
      t.integer :total, default: 0, null: false
      t.jsonb :rows_data, default: []
      t.jsonb :stats, default: {}
      t.text :error_message
      t.datetime :started_at
      t.datetime :completed_at
      t.timestamps
    end

    add_index :discourse_journals_persona_imports, :status
    add_index :discourse_journals_persona_imports, :created_at
  end
end
