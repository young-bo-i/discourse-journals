# frozen_string_literal: true

class AddApplyCheckpointToMappingAnalyses < ActiveRecord::Migration[7.0]
  def change
    add_column :discourse_journals_mapping_analyses, :apply_checkpoint, :jsonb, default: {}
  end
end
