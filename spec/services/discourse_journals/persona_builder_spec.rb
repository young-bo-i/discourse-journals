# frozen_string_literal: true

describe DiscourseJournals::PersonaBuilder do
  before { enable_current_plugin }

  describe "#build!" do
    it "creates a visible non-staged TL2 persona with email suppressed, backdated, and in the group" do
      Fabricate(:user, created_at: 2.years.ago) # an old real user, so the join-date window is years wide

      expect(
        described_class.new.build!(
          { "username" => "wei.zhang", "name" => "Zhang Wei", "field" => "化学" },
        ),
      ).to eq(:created)

      user = User.find_by(username: "wei.zhang")
      expect(user.active).to eq(true)
      expect(user.staged).to eq(false)
      expect(user.trust_level).to eq(2)
      expect(user.manual_locked_trust_level).to eq(2)
      expect(user.name).to eq("Zhang Wei")
      expect(user.created_at).to be < 1.hour.ago
      expect(user.last_seen_at).to be_present
      expect(user.custom_fields["discourse_journals_persona"]).to eq("1")
      expect(user.custom_fields["discourse_journals_field"]).to eq("化学")

      expect(user.user_option.email_digests).to eq(false)
      expect(user.user_option.email_level).to eq(UserOption.email_level_types[:never])
      expect(user.user_option.email_messages_level).to eq(UserOption.email_level_types[:never])

      group = Group.find_by(name: DiscourseJournals::PersonaPool::GROUP_NAME)
      expect(GroupUser.exists?(group_id: group.id, user_id: user.id)).to eq(true)
    end

    it "assigns a default field from the CAS taxonomy when the row omits one" do
      described_class.new.build!({ "username" => "no_field_user" })

      user = User.find_by(username: "no_field_user")
      expect(DiscourseJournals::PersonaPool::MAJOR_CATEGORIES).to include(
        user.custom_fields["discourse_journals_field"],
      )
    end

    it "fills the extended profile fields and matching custom user fields" do
      user_field = Fabricate(:user_field, name: "机构")

      described_class.new.build!(
        {
          "username" => "rich.profile",
          "bio" => "神经科学方向",
          "location" => "北京",
          "website" => "https://example.edu/lab",
          "title" => "副研究员",
          "机构" => "清华大学",
        },
      )

      user = User.find_by(username: "rich.profile")
      expect(user.title).to eq("副研究员")
      expect(user.user_profile.location).to eq("北京")
      expect(user.user_profile.website).to eq("https://example.edu/lab")
      expect(user.user_profile.bio_raw).to eq("神经科学方向")
      expect(user.custom_fields["user_field_#{user_field.id}"]).to eq("清华大学")
    end

    it "is idempotent — re-building the same username skips without creating a duplicate" do
      described_class.new.build!({ "username" => "dup_user" })

      expect { described_class.new.build!({ "username" => "dup_user" }) }.not_to change {
        User.where(username_lower: "dup_user").count
      }
      expect(described_class.new.build!({ "username" => "dup_user" })).to eq(:skipped)
    end

    it "refuses a username already taken by a real user" do
      Fabricate(:user, username: "realperson")

      expect { described_class.new.build!({ "username" => "realperson" }) }.to raise_error(
        described_class::SkipRow,
      )
    end
  end
end
