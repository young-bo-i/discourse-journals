# frozen_string_literal: true

require "net/http"
require "json"

uri = URI("https://journal.scholay.com/api/open/journals/byIds?ids=1&full=1")
resp = Net::HTTP.get(uri)
data = JSON.parse(resp)

puts "Response type: #{data.class}"
puts "Response keys: #{data.keys}" if data.is_a?(Hash)

rows = data.is_a?(Hash) ? (data["data"] || []) : data
row = rows.is_a?(Array) ? rows.first : rows

if row.nil?
  puts "No data"
  exit
end

puts "Row type: #{row.class}"
puts "Row keys: #{row.keys}" if row.is_a?(Hash)
puts "Title: #{row.dig("unified", "canonical_name")}"

transformed = DiscourseJournals::ApiDataTransformer.transform(row)
puts "Transformed keys: #{transformed.keys}"
puts "Sources keys: #{transformed[:sources].keys}"

normalizer = DiscourseJournals::FieldNormalizer.new(transformed)
normalized = normalizer.normalize
puts "Normalized keys: #{normalized.keys}"
puts "Identity title: #{normalized.dig(:identity, :title)}"

renderer = DiscourseJournals::MasterRecordRenderer.new(normalized)
html = renderer.render
puts "HTML length: #{html.length}"
puts "Has dj-journal: #{html.include?("dj-journal")}"
puts "First 200 chars:"
puts html[0..200]
