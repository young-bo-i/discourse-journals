# frozen_string_literal: true

class CreateMappingAnalyses < ActiveRecord::Migration[7.0]
  def change
    create_table :discourse_journals_mapping_analyses do |t|
      t.integer :user_id, null: false
      t.integer :status, default: 0, null: false
      t.integer :total_forum_topics, default: 0
      t.integer :total_api_records, default: 0
      t.integer :exact_1to1_count, default: 0
      t.integer :forum_1_to_api_n_count, default: 0
      t.integer :forum_n_to_api_1_count, default: 0
      t.integer :forum_n_to_api_m_count, default: 0
      t.integer :forum_only_count, default: 0
      t.integer :api_only_count, default: 0
      t.jsonb :details_data, default: {}
      t.text :error_message
      t.datetime :started_at
      t.datetime :completed_at
      t.timestamps
    end

    add_index :discourse_journals_mapping_analyses, :user_id
    add_index :discourse_journals_mapping_analyses, :status
    add_index :discourse_journals_mapping_analyses, :created_at
  end
end
