# frozen_string_literal: true

require "securerandom"

module DiscourseJournals
  # Builds a single visible, real-looking persona user from one upload row, with
  # all the anti-tell configuration baked in. Idempotent by username.
  class PersonaBuilder
    class SkipRow < StandardError
    end

    # Columns consumed directly as profile attributes. "field" is our subject key
    # (stored as a custom field), not a profile field. Any remaining column is
    # matched against the site's UserField names.
    KNOWN_KEYS = %w[username name field bio location website title timezone date_of_birth].freeze

    def initialize(group: nil, floor: nil)
      @group = group || PersonaPool.ensure_group!
      # Oldest human user — personas are never created before this, so /about's
      # site_creation_date stays put.
      @floor = floor || ::User.human_users.minimum(:created_at)
      # name (downcased) => UserField, so extra columns can fill custom user fields.
      @user_fields_by_name = ::UserField.all.index_by { |field| field.name.to_s.strip.downcase }
    end

    # row keys: "username" (required) plus any of KNOWN_KEYS and any column whose
    # header matches a site UserField name.
    # Returns :created or :skipped; raises SkipRow for rows that cannot be built.
    def build!(row)
      username = row["username"].to_s.strip
      raise SkipRow, "空 username" if username.blank?

      existing = ::User.find_by(username_lower: ::User.normalize_username(username))
      if existing
        return :skipped if persona?(existing) # idempotent re-import
        raise SkipRow, "username '#{username}' 已被真实用户占用"
      end

      unless ::User.username_available?(username)
        raise SkipRow, "username '#{username}' 不可用或为保留名"
      end

      field = row["field"].to_s.strip.presence || PersonaPool.default_field_for(username)
      tone = PersonaPool.tone_for(username)
      created_at =
        PersonaPool.created_at_for(
          username,
          floor: @floor,
          join_years: SiteSetting.discourse_journals_persona_join_years,
        )

      user = create_user!(username, row["name"], created_at)
      configure!(user, row, field, tone, created_at)
      maybe_grant_member_badge(user)
      :created
    end

    private

    def create_user!(username, name, created_at)
      ::User.create!(
        email: "#{SecureRandom.hex(10)}@#{SiteSetting.discourse_journals_persona_email_domain}",
        skip_email_validation: true,
        username: username,
        name: name.to_s.strip.presence,
        active: true,
        approved: true,
        approved_at: created_at,
        trust_level: 2,
        manual_locked_trust_level: 2, # short-circuits Promotion (no welcome PM / TL badge / auto-demote)
        created_at: created_at,
        import_mode: true, # suppresses the per-user gravatar download job
      )
    end

    def configure!(user, row, field, tone, created_at)
      option_attrs = {
        email_digests: false,
        email_level: ::UserOption.email_level_types[:never],
        email_messages_level: ::UserOption.email_level_types[:never],
        mailing_list_mode: false,
      }
      option_attrs[:timezone] = row["timezone"] if row["timezone"].present?
      user.user_option.update_columns(option_attrs)

      # Backdate created_at explicitly (belt-and-suspenders vs Rails timestamps) and
      # set "recently active" markers + optional profile columns. update_columns skips
      # callbacks / the user_seen DiscourseEvent / online logic / badge title check.
      user_attrs = {
        created_at: created_at,
        last_seen_at: PersonaPool.last_seen_at_for(user.username, created_at),
        previous_visit_at: created_at,
        first_seen_at: created_at,
      }
      user_attrs[:title] = row["title"] if row["title"].present?
      dob = parse_dob(row["date_of_birth"])
      user_attrs[:date_of_birth] = dob if dob
      user.update_columns(user_attrs)

      profile_attrs = {}
      profile_attrs[:location] = row["location"] if row["location"].present?
      profile_attrs[:website] = row["website"] if row["website"].present?
      if row["bio"].present?
        profile_attrs[:bio_raw] = row["bio"]
        profile_attrs[:bio_cooked] = PrettyText.cook(row["bio"])
      end
      # update_columns avoids the per-user cook + pull_hotlinked_image jobs at scale.
      user.user_profile.update_columns(profile_attrs) if profile_attrs.present?

      user.custom_fields[PersonaPool::PERSONA_FIELD] = "1"
      user.custom_fields[PersonaPool::FIELD_FIELD] = field
      user.custom_fields[PersonaPool::TONE_FIELD] = tone.to_s
      apply_user_fields!(user, row)
      user.save_custom_fields

      PersonaPool.add_to_group!(@group, user.id)
    end

    # Any column whose header matches a site UserField name (case-insensitive) is
    # stored as that user field (user_field_<id>), so personas can carry the same
    # profile info real members fill in (机构 / 研究方向 / 职称 …).
    def apply_user_fields!(user, row)
      return if @user_fields_by_name.blank?

      row.each do |key, value|
        next if KNOWN_KEYS.include?(key) || value.blank?
        field = @user_fields_by_name[key]
        next unless field
        user.custom_fields["user_field_#{field.id}"] = value
      end
    end

    def parse_dob(str)
      return nil if str.to_s.strip.blank?

      parts = str.strip.split(%r{[-/]}).map { |part| part.to_i }
      if parts.size == 3
        Date.new(parts[0], parts[1], parts[2])
      elsif parts.size == 2
        # Year hidden: 1904 is the leap-year sentinel Discourse uses for month/day.
        Date.new(1904, parts[0], parts[1])
      end
    rescue ArgumentError
      nil
    end

    def persona?(user)
      user.custom_fields[PersonaPool::PERSONA_FIELD].to_s == "1"
    end

    def maybe_grant_member_badge(user)
      pct = SiteSetting.discourse_journals_persona_member_badge_percent.to_i
      return if pct <= 0
      return unless SiteSetting.enable_badges
      return unless (PersonaPool.hash_int(user.username, "badge") % 100) < pct

      badge = ::Badge.find_by(id: ::Badge::Member)
      ::BadgeGranter.grant(badge, user) if badge&.enabled?
    rescue StandardError => e
      Rails.logger.warn(
        "[DiscourseJournals] Member badge grant failed for #{user.username}: #{e.message}",
      )
    end
  end
end
