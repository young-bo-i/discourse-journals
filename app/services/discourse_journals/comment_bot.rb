# frozen_string_literal: true

module DiscourseJournals
  # The one account every collected comment is posted under. A bot id (below
  # zero) keeps it out of user counts, the user directory and leaderboards; each
  # reply shows its own anonymous author instead (see CommentAuthor).
  module CommentBot
    STORE_KEY = "comment_bot_user_id"
    USERNAME = "journal_reviews"
    # Same floor as core's BotUser, clear of the fixed ids core and plugins use.
    FIRST_FALLBACK_ID = -1200

    def self.user
      find || create!
    end

    def self.find
      user_id = PluginStore.get(PLUGIN_NAME, STORE_KEY)
      user_id && User.find_by(id: user_id)
    end

    def self.create!
      DistributedMutex.synchronize("discourse_journals_comment_bot") { find || build! }
    end

    # Newer cores hand out bot ids through BotUser, which also honours ids other
    # plugins reserved; older ones lack it, so take the next id below every user.
    def self.next_bot_id
      return ::BotUser.new(PLUGIN_NAME).next_id if defined?(::BotUser)

      [User.minimum(:id).to_i, FIRST_FALLBACK_ID].min - 1
    end

    def self.build!
      user =
        User.new(
          id: next_bot_id,
          email: "#{SecureRandom.hex}@does-not-exist.invalid",
          username: UserNameSuggester.suggest(USERNAME),
          name: I18n.t("discourse_journals.comment_sync.bot_name"),
          active: true,
          approved: true,
          trust_level: TrustLevel[1],
        )
      user.save!(validate: false)

      user.user_option.update!(
        email_level: UserOption.email_level_types[:never],
        email_messages_level: UserOption.email_level_types[:never],
        email_digests: false,
      )
      user.user_profile.update!(bio_raw: I18n.t("discourse_journals.comment_sync.bot_bio"))

      PluginStore.set(PLUGIN_NAME, STORE_KEY, user.id)
      user
    end
    private_class_method :build!, :next_bot_id
  end
end
