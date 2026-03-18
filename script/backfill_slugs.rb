# frozen_string_literal: true
#
# Usage (inside container):
#   rails runner plugins/discourse-journals/script/backfill_slugs.rb
#

total = Topic.where(slug: "topic").count
puts "[Slug Backfill] Topics to update: #{total}"

if total.zero?
  puts "[Slug Backfill] Nothing to do."
  Sitemap.regenerate_sitemaps
  puts "[Slug Backfill] Sitemap regenerated."
  exit
end

count = 0
start_time = Time.now

Topic.where(slug: "topic").select(:id, :title, :slug).find_in_batches(batch_size: 1000) do |batch|
  updates = []
  batch.each do |t|
    new_slug = Slug.for(t.title)
    next if new_slug.blank? || new_slug == "topic"
    updates << { id: t.id, slug: new_slug }
  end

  next if updates.empty?

  case_sql = updates.map { |u| "WHEN #{u[:id]} THEN #{ActiveRecord::Base.connection.quote(u[:slug])}" }.join(" ")
  ids = updates.map { |u| u[:id] }.join(",")
  ActiveRecord::Base.connection.execute("UPDATE topics SET slug = CASE id #{case_sql} END WHERE id IN (#{ids})")

  count += updates.size
  elapsed = (Time.now - start_time).round(1)
  speed = elapsed > 0 ? (count.to_f / elapsed).round(0) : 0
  remaining = total - count
  eta = speed > 0 ? (remaining.to_f / speed).round(0) : 0
  puts "[Slug Backfill] #{count}/#{total} (#{speed}/s, ETA #{eta}s)"

  GC.start if (count / 1000) % 10 == 0
end

elapsed = (Time.now - start_time).round(1)
puts "[Slug Backfill] Done! #{count} slugs updated in #{elapsed}s"

remaining = Topic.where(slug: "topic").count
puts "[Slug Backfill] Remaining with 'topic' slug: #{remaining}"

Sitemap.regenerate_sitemaps
puts "[Slug Backfill] Sitemap regenerated!"

samples = Topic.where.not(slug: "topic").order("RANDOM()").limit(3).pluck(:id, :slug, :updated_at)
samples.each do |id, slug, updated_at|
  puts "  Sample: /t/#{slug}/#{id} (updated_at: #{updated_at})"
end
