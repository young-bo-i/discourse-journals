# frozen_string_literal: true

module DiscourseJournals
  # The anonymous name a collected comment is shown under: a modifier, a noun
  # and an optional suffix from the word settings. The pick is seeded by the comment's code, so a reply
  # keeps its name across views and syncs; within a topic a repeated name gets
  # extra letters (see `assign!`).
  module CommentAuthor
    FIELD = "discourse_journals_comment"
    LETTERS = ("A".."Z").to_a.freeze

    def self.code_for(record_id)
      Digest::SHA1.hexdigest(record_id.to_s)[0, 6].upcase
    end

    def self.words(setting)
      SiteSetting.get(setting).to_s.split("|").map(&:strip).reject(&:empty?)
    end

    # Slot 0 of the suffixes is "no suffix", so some names stay two-part.
    def self.base_name(code)
      modifiers = words(:discourse_journals_comment_author_modifiers)
      nouns = words(:discourse_journals_comment_author_nouns)
      suffixes = [""] + words(:discourse_journals_comment_author_suffixes)
      return code.to_s if modifiers.empty? || nouns.empty?

      seed = code.to_s.to_i(16)
      modifier = modifiers[seed % modifiers.size]
      seed /= modifiers.size
      noun = nouns[seed % nouns.size]
      seed /= nouns.size
      "#{modifier}#{noun}#{suffixes[seed % suffixes.size]}"
    end

    def self.unique_name(code, taken)
      name = base_name(code)
      random = Random.new(code.to_s.to_i(16))
      name += LETTERS[random.rand(LETTERS.size)] while taken.include?(name)
      name
    end

    UPDATE_BATCH_SIZE = 1_000

    # Names every collected reply in a topic, oldest post first so the earlier
    # reply keeps the plain name. Only rows whose name changes are written, a
    # batch per statement: a big journal's first import renames thousands.
    def self.assign!(topic_id)
      rows =
        PostCustomField
          .joins("JOIN posts ON posts.id = post_custom_fields.post_id")
          .where(posts: { topic_id: topic_id }, name: FIELD)
          .order("posts.post_number")
          .pluck("post_custom_fields.id", "post_custom_fields.value")

      taken = Set.new
      changes = []
      rows.each do |id, value|
        data = fields(value)
        next if data.nil? || data["code"].blank?

        name = unique_name(data["code"], taken)
        taken << name
        changes << [id, data.merge("name" => name).to_json] if data["name"] != name
      end

      changes.each_slice(UPDATE_BATCH_SIZE) do |batch|
        DB.exec(<<~SQL, ids: batch.map(&:first), values: batch.map(&:last))
          UPDATE post_custom_fields
          SET value = changed.value, updated_at = NOW()
          FROM unnest(ARRAY[:ids]::bigint[], ARRAY[:values]::text[]) AS changed(id, value)
          WHERE post_custom_fields.id = changed.id
        SQL
      end
    end

    # `value` is the post's custom field: a Hash, or its JSON when read back raw.
    def self.fields(value)
      fields = value.is_a?(String) ? JSON.parse(value) : value
      fields.is_a?(Hash) ? fields : nil
    rescue JSON::ParserError
      nil
    end

    def self.display(value)
      fields = fields(value)
      return nil if fields.nil?

      code = fields["code"].to_s
      return nil if code.empty?

      { name: fields["name"].presence || base_name(code), code: code }
    end
  end
end
