# frozen_string_literal: true

require "migration/table_dropper"

class DropDiscourseJournalsPersonaImports < ActiveRecord::Migration[7.0]
  DROPPED_TABLES = %i[discourse_journals_persona_imports]

  def up
    DROPPED_TABLES.each { |table| Migration::TableDropper.execute_drop(table) }

    execute <<~SQL
      DELETE FROM site_settings
      WHERE name IN (
        'discourse_journals_persona_email_domain',
        'discourse_journals_persona_join_years',
        'discourse_journals_persona_member_badge_percent'
      )
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
