# frozen_string_literal: true

# Earlier mapping analyses treated the journal category's "About" topic as a
# journal missing upstream and flagged it outdated, which closed it and put the
# outdated banner into its post. Analysis now skips definition topics; this
# undoes the flag and queues the post for a rebake from its own raw text.
class RestoreJournalCategoryDefinitionTopic < ActiveRecord::Migration[8.0]
  def up
    execute <<~SQL
      WITH flagged AS (
        DELETE FROM topic_custom_fields
        WHERE name = 'discourse_journals_outdated'
          AND topic_id IN (SELECT topic_id FROM categories WHERE topic_id IS NOT NULL)
        RETURNING topic_id
      ),
      reopened AS (
        UPDATE topics SET closed = false WHERE id IN (SELECT topic_id FROM flagged)
      )
      UPDATE posts SET baked_version = NULL
      WHERE post_number = 1 AND topic_id IN (SELECT topic_id FROM flagged)
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
