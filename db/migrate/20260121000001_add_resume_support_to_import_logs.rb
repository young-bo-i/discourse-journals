# frozen_string_literal: true

class AddResumeSupportToImportLogs < ActiveRecord::Migration[7.0]
  def change
    add_column :discourse_journals_import_logs, :current_page, :integer, default: 1
    add_column :discourse_journals_import_logs, :last_processed_issn, :string
    add_column :discourse_journals_import_logs, :api_url, :string
    add_column :discourse_journals_import_logs, :filters, :jsonb, default: {}
    add_column :discourse_journals_import_logs, :import_mode, :string
    add_column :discourse_journals_import_logs, :paused_at, :datetime
    add_column :discourse_journals_import_logs, :page_size, :integer, default: 100

    add_index :discourse_journals_import_logs, :current_page
    add_index :discourse_journals_import_logs, :last_processed_issn
  end
end
