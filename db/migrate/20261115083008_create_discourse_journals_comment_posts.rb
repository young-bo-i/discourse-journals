# frozen_string_literal: true

class CreateDiscourseJournalsCommentPosts < ActiveRecord::Migration[8.1]
  def change
    create_table :discourse_journals_comment_posts do |t|
      t.string :record_id, null: false
      t.integer :topic_id, null: false
      t.integer :post_id, null: false
      t.string :digest, null: false
      t.timestamps
    end

    add_index :discourse_journals_comment_posts, :record_id, unique: true
    add_index :discourse_journals_comment_posts, :post_id, unique: true
    add_index :discourse_journals_comment_posts, :topic_id
  end
end
