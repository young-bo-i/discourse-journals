# frozen_string_literal: true

module DiscourseJournals
  # Brings one journal topic's collected comments in line with upstream: posts
  # the new ones in date order, rewrites the changed ones and removes the ones
  # upstream dropped.
  class CommentSyncer
    MAX_REDIRECTS = 3
    MAX_PAGES = 500

    # Losing more than half of a topic's comments in one pass looks more like an
    # upstream fault than a cleanup, so those deletions wait for a person.
    DELETE_GUARD_MIN = 4

    Result =
      Struct.new(
        :status,
        :created,
        :updated,
        :deleted,
        :unchanged,
        :skipped,
        :held,
        keyword_init: true,
      ) do
        def self.empty(status)
          new(status: status, created: 0, updated: 0, deleted: 0, unchanged: 0, skipped: 0, held: 0)
        end
      end

    # All of a journal's comments, as [status, comments]; comments is nil when
    # upstream has no such journal (:not_found, :gone). HTTP only, so the full
    # sync runs it on fetcher threads (see CommentFetcher).
    def self.fetch(client, api_id)
      comments = []
      after = nil
      redirects = 0
      pages = 0

      loop do
        page = client.fetch_journal_comments(api_id, after: after)

        case page.status
        when :ok
          comments.concat(page.comments)
          return :ok, comments if page.next_cursor.nil?

          pages += 1
          raise ApiClient::Error, "评论分页超过 #{MAX_PAGES} 页 (api_id=#{api_id})" if pages >= MAX_PAGES
          after = page.next_cursor
        when :redirected
          redirects += 1
          raise ApiClient::Error, "评论接口重定向过多 (api_id=#{api_id})" if redirects > MAX_REDIRECTS

          api_id = page.api_id
          comments = []
          after = nil
        when :no_comments
          return :ok, []
        else
          return page.status, nil
        end
      end
    end

    def initialize(topic, bot:, client: nil)
      @topic = topic
      @client = client
      @bot = bot
    end

    # `fetched` is what CommentSyncer.fetch returned, when it already ran.
    def sync!(fetched = nil)
      if fetched.nil?
        api_id =
          TopicCustomField.where(topic_id: @topic.id, name: "discourse_journals_api_id").pick(
            :value,
          )
        return Result.empty(:no_api_id) if api_id.blank?

        fetched = self.class.fetch(@client, api_id.to_i)
      end

      status, comments = fetched
      return Result.empty(status) if comments.nil?

      reconcile(comments)
    end

    private

    def reconcile(comments)
      result = Result.empty(:ok)
      builders = comments.map { |comment| CommentPostBuilder.new(comment) }.select(&:postable?)
      builders = builders.uniq(&:record_id)
      existing = CommentPost.where(topic_id: @topic.id).index_by(&:record_id)
      first_import = existing.empty?
      previous_highest = @topic.highest_post_number

      fresh = builders.reject { |builder| existing.key?(builder.record_id) }
      # A comment already carried by another topic (upstream moved it) stays there.
      elsewhere = CommentPost.where(record_id: fresh.map(&:record_id)).pluck(:record_id).to_set
      result.skipped = elsewhere.size

      fresh
        .reject { |builder| elsewhere.include?(builder.record_id) }
        .sort_by(&:sort_key)
        .each do |builder|
          create_post(builder)
          result.created += 1
        end

      builders.each do |builder|
        mapping = existing[builder.record_id]
        next if mapping.nil?

        if mapping.digest == builder.digest
          result.unchanged += 1
        elsif update_post(mapping, builder)
          result.updated += 1
        end
      end

      delete_dropped(existing, builders.map(&:record_id).to_set, result)
      CommentAuthor.assign!(@topic.id) if result.created > 0 || result.updated > 0
      keep_readers_caught_up(previous_highest) if first_import && result.created > 0
      result
    end

    # import_mode skips what a bulk import has no use for: two live MessageBus
    # pushes per reply to anyone reading the topic, the bot's own counters and
    # topic tracking, and the spam and review checks. Topic stats still update.
    def create_post(builder)
      ActiveRecord::Base.transaction do
        post =
          PostCreator.new(
            @bot,
            topic_id: @topic.id,
            raw: builder.raw,
            created_at: builder.created_at,
            import_mode: true,
            skip_guardian: true,
            skip_validations: true,
            skip_jobs: true,
            skip_events: true,
            no_bump: true,
            custom_fields: {
              CommentAuthor::FIELD => builder.custom_fields,
            },
          ).create!

        CommentPost.create!(
          record_id: builder.record_id,
          topic_id: @topic.id,
          post_id: post.id,
          digest: builder.digest,
        )
      end
    end

    # A reply staff deleted stays deleted: its mapping row still blocks a repost.
    def update_post(mapping, builder)
      post = Post.find_by(id: mapping.post_id)
      return false if post.nil?

      PostRevisor.new(post).revise!(
        Discourse.system_user,
        { raw: builder.raw },
        skip_validations: true,
        bypass_bump: true,
        skip_revision: true,
      )
      post.custom_fields[CommentAuthor::FIELD] = builder.custom_fields
      post.save_custom_fields
      mapping.update!(digest: builder.digest)
      true
    end

    def delete_dropped(existing, current_ids, result)
      dropped = existing.values.reject { |mapping| current_ids.include?(mapping.record_id) }
      return if dropped.empty?

      if dropped.size >= DELETE_GUARD_MIN && dropped.size * 2 > existing.size
        result.held = dropped.size
        Rails.logger.warn(
          "[DiscourseJournals::CommentSyncer] topic #{@topic.id}: upstream dropped " \
            "#{dropped.size}/#{existing.size} comments; deletion held for review",
        )
        return
      end

      dropped.each do |mapping|
        post = Post.find_by(id: mapping.post_id)
        if post
          PostDestroyer.new(
            Discourse.system_user,
            post,
            context: "discourse_journals comment sync",
          ).destroy
        end
        mapping.destroy!
        result.deleted += 1
      end
    end

    # A topic's first import adds many replies at once. Readers who had already
    # read to the end stay there instead of finding the topic full of unread posts.
    def keep_readers_caught_up(previous_highest)
      highest = Topic.where(id: @topic.id).pick(:highest_post_number)
      TopicUser
        .where(topic_id: @topic.id)
        .where("last_read_post_number >= ?", previous_highest)
        .update_all(last_read_post_number: highest)
    end
  end
end
