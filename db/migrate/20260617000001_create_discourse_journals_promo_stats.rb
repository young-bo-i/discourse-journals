# frozen_string_literal: true

class CreateDiscourseJournalsPromoStats < ActiveRecord::Migration[7.0]
  def change
    create_table :discourse_journals_promo_stats do |t|
      t.date :day, null: false
      t.string :slide, null: false, limit: 64
      t.integer :impressions, null: false, default: 0
      t.integer :clicks, null: false, default: 0
      t.timestamps
    end

    add_index :discourse_journals_promo_stats, %i[day slide], unique: true
  end
end
