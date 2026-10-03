# frozen_string_literal: true

class CreateDiscourseJournalsCoverSyncs < ActiveRecord::Migration[7.0]
  def change
    create_table :discourse_journals_cover_syncs do |t|
      t.integer :user_id, null: false
      t.integer :status, default: 0, null: false
      t.integer :total, default: 0, null: false
      t.jsonb :checkpoint, default: {}, null: false
      t.jsonb :stats, default: {}, null: false
      t.text :error_message
      t.datetime :started_at
      t.datetime :completed_at
      t.timestamps
    end
  end
end
