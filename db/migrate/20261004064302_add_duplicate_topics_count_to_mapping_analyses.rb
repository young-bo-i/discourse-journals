# frozen_string_literal: true

class AddDuplicateTopicsCountToMappingAnalyses < ActiveRecord::Migration[8.0]
  def change
    add_column :discourse_journals_mapping_analyses,
               :duplicate_topics_count,
               :integer,
               default: 0,
               null: false
  end
end
