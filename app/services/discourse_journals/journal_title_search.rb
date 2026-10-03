# frozen_string_literal: true

module DiscourseJournals
  # Quick lookup behind the search box on journal pages. Core full-text search
  # over hundreds of thousands of journal posts takes seconds (tens for broad
  # terms) and ties up a web worker; journals are found by name or ISSN, which a
  # trigram index on topics.title answers in milliseconds.
  class JournalTitleSearch
    LIMIT = 8
    MAX_WORDS = 5
    MIN_WORD_LENGTH = 2
    ISSN = /\A(\d{4})-?(\d{3}[\dX])\z/i
    # A safety net for pathological inputs; real queries finish in well under 200ms.
    STATEMENT_TIMEOUT_MS = 2_000

    def initialize(query, guardian:)
      @query = query.to_s.strip.first(200)
      @guardian = guardian
    end

    def topic_ids
      category_id = SiteSetting.discourse_journals_category_id.to_i
      return [] if category_id.zero? || @query.blank?

      scope =
        Topic.secured(@guardian).where(category_id: category_id, deleted_at: nil, visible: true)

      ids = issn_matches(scope)
      return ids if ids.size >= LIMIT

      ids + title_matches(scope.where.not(id: ids), LIMIT - ids.size)
    end

    private

    def issn_matches(scope)
      match = @query.match(ISSN)
      return [] if match.nil?

      issn = "#{match[1]}-#{match[2].upcase}"
      scope
        .where(
          id:
            TopicCustomField.where(name: "discourse_journals_issn_l", value: issn).select(
              :topic_id,
            ),
        )
        .order(:id)
        .limit(LIMIT)
        .pluck(:id)
    end

    def title_matches(scope, limit)
      words =
        @query
          .scan(/[\p{L}\p{N}]+/)
          .select { |word| word.length >= MIN_WORD_LENGTH }
          .first(MAX_WORDS)
      return [] if words.empty?

      words.each do |word|
        scope = scope.where("topics.title ILIKE ?", "%#{Topic.sanitize_sql_like(word)}%")
      end

      query = @query.downcase
      ordered =
        scope.order(
          Arel.sql(DB.sql_fragment("lower(topics.title) = ? DESC", query)),
          Arel.sql(
            DB.sql_fragment(
              "lower(topics.title) LIKE ? DESC",
              "#{Topic.sanitize_sql_like(query)}%",
            ),
          ),
          Arel.sql("length(topics.title)"),
          :id,
        )

      Topic.transaction do
        DB.exec("SET LOCAL statement_timeout = #{STATEMENT_TIMEOUT_MS}")
        ordered.limit(limit).pluck(:id)
      end
    rescue ActiveRecord::QueryCanceled
      []
    end
  end
end
