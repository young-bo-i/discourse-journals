# frozen_string_literal: true

# The old file/API import pipeline (ImportLog model + sync controller/jobs) was
# removed long ago; this table has had no reader or writer since. Drop it.
class DropJournalsImportLogs < ActiveRecord::Migration[7.0]
  def up
    drop_table :discourse_journals_import_logs, if_exists: true
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
