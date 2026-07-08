# frozen_string_literal: true

require "digest"

module DiscourseJournals
  # Shared helpers for the persona pool: the dedicated group, the field taxonomy
  # used when an upload omits a field, deterministic per-username time/tone
  # derivation, and the gamification leaderboard exclusion.
  module PersonaPool
    GROUP_NAME = "journal_personas"

    PERSONA_FIELD = "discourse_journals_persona"          # "1" marks a persona account
    FIELD_FIELD = "discourse_journals_field"              # 中科院大类 (subject) driving assignment
    TONE_FIELD = "discourse_journals_tone"                # writing-tone index bound to the persona
    USER_CUSTOM_FIELDS = [PERSONA_FIELD, FIELD_FIELD, TONE_FIELD].freeze

    TONE_COUNT = 3

    # 中科院大类 — the subject taxonomy JournalTagManager.extract_subject tags topics
    # with. Used as the default persona field when the uploaded file omits one.
    MAJOR_CATEGORIES = %w[
      医学 生物学 化学 物理与天体物理 材料科学 工程技术 地球科学
      环境科学与生态学 数学 计算机科学 农林科学 管理科学 人文科学
    ].freeze

    module_function

    def ensure_group!
      group = ::Group.find_by(name: GROUP_NAME)
      return group if group

      group =
        ::Group.new(
          name: GROUP_NAME,
          full_name: "Journal review personas",
          visibility_level: ::Group.visibility_levels[:staff],
          members_visibility_level: ::Group.visibility_levels[:staff],
        )
      group.save!
      group
    end

    def add_to_group!(group, user_id)
      ::GroupUser.find_or_create_by!(group_id: group.id, user_id: user_id)
    rescue ActiveRecord::RecordNotUnique
      # concurrent insert — already a member
    end

    # Exclude the persona group from every gamification leaderboard so backdated
    # persona posts can never surface on the public all-time board. There is no
    # global setting — it's a per-leaderboard field — so every board must be touched.
    def exclude_from_leaderboards!
      return unless defined?(::DiscourseGamification::GamificationLeaderboard)

      group = ensure_group!
      ::DiscourseGamification::GamificationLeaderboard.find_each do |board|
        excluded = Array(board.excluded_groups_ids).map(&:to_i)
        next if excluded.include?(group.id)
        board.update!(excluded_groups_ids: excluded + [group.id])
      end
    rescue StandardError => e
      Rails.logger.warn(
        "[DiscourseJournals] Failed to exclude persona group from leaderboards: #{e.message}",
      )
    end

    def default_field_for(username)
      MAJOR_CATEGORIES[hash_int(username, "field") % MAJOR_CATEGORIES.size]
    end

    def tone_for(username)
      hash_int(username, "tone") % TONE_COUNT
    end

    # A deterministic "joined a few years ago, spread across all days" timestamp,
    # never earlier than the oldest existing human user (so /about site_creation_date
    # is not pulled backwards) and, when the site is old enough, at least
    # `min_age_days` in the past.
    def created_at_for(username, floor:, join_years:, min_age_days: 30)
      now = Time.zone.now
      latest = now - min_age_days.days
      earliest = now - join_years.years
      # Never earlier than the oldest real user (keeps /about site_creation_date put).
      earliest = floor if floor && floor > earliest

      # Very new site: "at least min_age_days old" and "after the oldest user" can't
      # both hold — keep the floor and let personas be recent (a brand-new site has
      # nothing older to blend in with anyway). earliest is always >= floor here.
      latest = [earliest, now - 1.minute].max if earliest >= latest

      span = latest.to_i - earliest.to_i
      return earliest if span <= 0
      Time.zone.at(earliest.to_i + hash_int(username, "created") % span)
    end

    # "Recently active, but not right now": some point in roughly the last 90 days,
    # never before the account was created.
    def last_seen_at_for(username, created_at)
      latest = 1.day.ago
      earliest = created_at + 1.day
      return created_at if earliest >= latest

      recent_start = [latest - 90.days, earliest].max
      span = latest.to_i - recent_start.to_i
      span = 1 if span <= 0
      Time.zone.at(recent_start.to_i + hash_int(username, "seen") % span)
    end

    def hash_int(username, salt)
      Digest::SHA1.hexdigest("#{salt}:#{username}")[0, 12].to_i(16)
    end
  end
end
