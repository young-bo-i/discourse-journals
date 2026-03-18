# frozen_string_literal: true

class AddCoverTrackingToMappingAnalyses < ActiveRecord::Migration[7.0]
  def change
    add_column :discourse_journals_mapping_analyses, :cover_status, :integer, default: 0
    add_column :discourse_journals_mapping_analyses, :cover_stats, :jsonb, default: {}
  end
end
