# frozen_string_literal: true

require "migration/table_dropper"

class DropDiscourseJournalsPromoStats < ActiveRecord::Migration[8.1]
  DROPPED_TABLES = %i[discourse_journals_promo_stats]

  def up
    DROPPED_TABLES.each { |table| Migration::TableDropper.execute_drop(table) }

    execute <<~SQL
      DELETE FROM site_settings
      WHERE name IN ('discourse_journals_banner_enabled', 'discourse_journals_banner_url')
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
