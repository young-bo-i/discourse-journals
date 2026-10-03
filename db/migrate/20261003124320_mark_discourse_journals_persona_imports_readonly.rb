# frozen_string_literal: true

require "migration/table_dropper"

class MarkDiscourseJournalsPersonaImportsReadonly < ActiveRecord::Migration[7.0]
  def up
    Migration::TableDropper.read_only_table(:discourse_journals_persona_imports)
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
