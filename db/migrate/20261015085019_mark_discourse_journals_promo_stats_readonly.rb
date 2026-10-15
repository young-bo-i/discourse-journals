# frozen_string_literal: true

require "migration/table_dropper"

class MarkDiscourseJournalsPromoStatsReadonly < ActiveRecord::Migration[8.1]
  def up
    Migration::TableDropper.read_only_table(:discourse_journals_promo_stats)
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
