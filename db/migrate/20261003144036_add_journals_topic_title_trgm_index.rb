# frozen_string_literal: true

# Backs the journal page search box (JournalTitleSearch): substring title
# matches over hundreds of thousands of journal topics need a trigram index.
class AddJournalsTopicTitleTrgmIndex < ActiveRecord::Migration[7.0]
  disable_ddl_transaction!

  def up
    remove_index :topics,
                 name: "idx_dj_topics_title_trgm",
                 algorithm: :concurrently,
                 if_exists: true
    add_index :topics,
              :title,
              using: :gin,
              opclass: :gin_trgm_ops,
              name: "idx_dj_topics_title_trgm",
              algorithm: :concurrently
  end

  def down
    remove_index :topics,
                 name: "idx_dj_topics_title_trgm",
                 algorithm: :concurrently,
                 if_exists: true
  end
end
