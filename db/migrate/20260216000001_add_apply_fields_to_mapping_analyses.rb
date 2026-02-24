# frozen_string_literal: true

class AddApplyFieldsToMappingAnalyses < ActiveRecord::Migration[7.0]
  def change
    add_column :discourse_journals_mapping_analyses, :apply_status, :integer, default: 0
    add_column :discourse_journals_mapping_analyses, :apply_started_at, :datetime
    add_column :discourse_journals_mapping_analyses, :apply_completed_at, :datetime
    add_column :discourse_journals_mapping_analyses, :apply_error_message, :text
    add_column :discourse_journals_mapping_analyses, :apply_stats, :jsonb, default: {}
  end
end
