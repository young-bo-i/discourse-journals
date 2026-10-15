# frozen_string_literal: true

require_relative "../../db/migrate/20261015085019_mark_discourse_journals_promo_stats_readonly"
require_relative "../../db/post_migrate/20261015085021_drop_discourse_journals_promo_stats"

RSpec.describe DropDiscourseJournalsPromoStats do
  before do
    @original_verbose = ActiveRecord::Migration.verbose
    ActiveRecord::Migration.verbose = false
  end

  after { ActiveRecord::Migration.verbose = @original_verbose }

  it "removes the banner statistics and the banner settings on upgrade" do
    DB.exec(<<~SQL)
      CREATE TABLE IF NOT EXISTS discourse_journals_promo_stats (id serial PRIMARY KEY, impressions integer);
      INSERT INTO discourse_journals_promo_stats (impressions) VALUES (42);
      INSERT INTO site_settings (name, data_type, value, created_at, updated_at)
      VALUES ('discourse_journals_banner_enabled', 5, 't', now(), now()),
             ('discourse_journals_banner_url', 1, 'https://www.scholay.com', now(), now());
    SQL

    MarkDiscourseJournalsPromoStatsReadonly.new.up
    described_class.new.up

    expect(DB.query_single("SELECT to_regclass('discourse_journals_promo_stats')::text")).to eq(
      [nil],
    )
    expect(
      DB.query_single(
        "SELECT count(*) FROM site_settings WHERE name LIKE 'discourse_journals_banner_%'",
      ),
    ).to eq([0])
  end
end
