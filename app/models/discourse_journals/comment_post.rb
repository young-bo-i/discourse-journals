# frozen_string_literal: true

module DiscourseJournals
  # Which reply carries which upstream comment. The unique record_id keeps a
  # rerun or an overlapping sync from posting the same comment twice.
  class CommentPost < ActiveRecord::Base
    self.table_name = "discourse_journals_comment_posts"

    belongs_to :post
    belongs_to :topic
  end
end
