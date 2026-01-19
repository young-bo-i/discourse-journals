# frozen_string_literal: true

desc "Import journals from JSON file"
task "journals:import", [:file_path] => :environment do |_, args|
  require_relative "../../app/services/discourse_journals/json_import/importer"
  require_relative "../../app/services/discourse_journals/journal_upserter"
  require_relative "../../app/services/discourse_journals/field_normalizer"
  require_relative "../../app/services/discourse_journals/master_record_renderer"

  file_path = args[:file_path]

  if file_path.blank?
    puts "Usage: rake journals:import[/path/to/file.json]"
    exit 1
  end

  unless File.exist?(file_path)
    puts "Error: File not found: #{file_path}"
    exit 1
  end

  puts "Starting import from: #{file_path}"
  puts "=" * 80

  importer = DiscourseJournals::JsonImport::Importer.new(file_path: file_path)
  importer.import!

  puts "=" * 80
  puts "Import completed!"
  puts "  Processed: #{importer.processed_rows}"
  puts "  Created:   #{importer.created_topics}"
  puts "  Updated:   #{importer.updated_topics}"
  puts "  Skipped:   #{importer.skipped_rows}"
  puts "  Errors:    #{importer.errors.size}"

  if importer.errors.any?
    puts ""
    puts "Errors:"
    importer.errors.each { |error| puts "  - #{error}" }
  end
end

desc "List journals import status"
task "journals:status" => :environment do
  category_id = SiteSetting.discourse_journals_category_id
  
  if category_id.blank?
    puts "Error: discourse_journals_category_id not set"
    exit 1
  end

  category = Category.find_by(id: category_id)
  if category.nil?
    puts "Error: Category not found (ID: #{category_id})"
    exit 1
  end

  topics = Topic.where(category_id: category_id).order(created_at: :desc).limit(10)
  
  puts "Journals Category: #{category.name} (ID: #{category_id})"
  puts "Total Topics: #{Topic.where(category_id: category_id).count}"
  puts ""
  puts "Recent journals:"
  puts "-" * 80

  topics.each do |topic|
    issn = topic.custom_fields["discourse_journals_issn"]
    puts "#{topic.title}"
    puts "  ISSN: #{issn}"
    puts "  Created: #{topic.created_at}"
    puts ""
  end
end
