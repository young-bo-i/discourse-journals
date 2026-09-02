# frozen_string_literal: true

require "cgi"

module DiscourseJournals
  class TitleMatcher
    class PausedError < StandardError; end

    # Contract v4 raised the `/journals` page-size cap from 100 to 2000, and the
    # `afterId` cursor walk has no deep-offset ceiling — so one page now carries
    # 20x what it used to. Paired with `fields=`, the whole-catalogue pass is a
    # couple of hundred requests instead of a couple of thousand.
    API_PAGE_SIZE = ApiClient::LIST_PAGE_SIZE
    PROGRESS_BATCH_INTERVAL = 5

    attr_reader :forum_index, :api_index, :results,
                :total_forum_topics, :total_api_records

    def initialize(progress_callback: nil, cancel_check: nil)
      @progress_callback = progress_callback
      @cancel_check = cancel_check
      @rate_limiter = ApiRateLimiter.new
      @forum_index = {}
      @api_index = {}
      @forum_issn_index = {}
      @api_issn_index = {}
      @forum_api_id_index = {}
      @api_id_index = {}
      @api_seen_issns = Set.new
      @dropped_duplicate_issns = 0
      @total_forum_topics = 0
      @total_api_records = 0
      @results = {
        exact_1to1: [],
        forum_1_to_api_n: [],
        forum_n_to_api_1: [],
        forum_n_to_api_m: [],
        forum_only: [],
        api_only: [],
      }
    end

    def self.normalize(title)
      return "" if title.blank?
      text = CGI.unescapeHTML(title.to_s)
      text = TextCleaner.clean_title(TextSentinel.title_sentinel(text).text)
      text.strip.downcase
    end

    def self.normalized_title_key(title)
      normalize(title).gsub(/[^[:alnum:]]+/, "")
    end

    def run!
      ApiClient.ensure_configured!
      PerformanceLogger.measure("analysis.build_forum_index", source_type: "title_matcher") { build_forum_index }
      PerformanceLogger.measure("analysis.build_api_index", source_type: "title_matcher") { build_api_index }
      PerformanceLogger.measure("analysis.cross_match", source_type: "title_matcher") { cross_match }
      release_indexes!
      results
    end

    private

    def publish_progress(phase, current, total, message)
      @progress_callback&.call(phase, current, total, message)
    end

    def check_cancelled!
      raise PausedError, "分析已被用户暂停" if @cancel_check&.call
    end

    def release_indexes!
      @total_forum_topics = @forum_index.values.sum(&:size)
      @total_api_records = @api_index.values.sum(&:size)

      @forum_index = {}
      @api_index = {}
      @forum_issn_index = {}
      @api_issn_index = {}
      @forum_api_id_index = {}
      @api_id_index = {}
      @api_seen_issns = nil
    end

    def build_forum_index
      category_id = SiteSetting.discourse_journals_category_id.to_i
      if category_id.zero?
        raise "请先在设置中配置期刊分类 (discourse_journals_category_id)"
      end

      publish_progress(:forum, 0, 0, "正在查询论坛期刊数据...")

      base_scope = Topic.where(category_id: category_id).where(deleted_at: nil)
      total = base_scope.count
      topics = base_scope.select(:id, :title)
      publish_progress(:forum, 0, total, "正在建立论坛标题索引 (#{total} 个话题)...")

      field_map =
        TopicCustomField
          .where(
            name: %w[
              discourse_journals_issn_l
              discourse_journals_normalized_title_key
              discourse_journals_api_id
              discourse_journals_outdated
            ],
            topic_id: base_scope.select(:id),
          )
          .pluck(:topic_id, :name, :value)
          .group_by(&:first)
          .transform_values { |rows| rows.to_h { |_, name, value| [name, value] } }

      topics.find_each.with_index do |topic, idx|
        fields = field_map[topic.id] || {}
        normalized =
          fields["discourse_journals_normalized_title_key"].presence || self.class.normalized_title_key(topic.title)
        next if normalized.blank?

        outdated = fields["discourse_journals_outdated"].present?
        entry = { topic_id: topic.id, title: topic.title, outdated: outdated }

        # Keep outdated topics in EVERY index (incl. the title index) so a returning
        # journal matches and revives them via update, instead of being classified
        # api_only and creating a duplicate topic. They are filtered out of the
        # forum_only bucket in match_by_title so they are never re-flagged.
        @forum_index[normalized] ||= []
        @forum_index[normalized] << entry

        issn_l = fields["discourse_journals_issn_l"]
        if issn_l.present?
          @forum_issn_index[issn_l] ||= []
          @forum_issn_index[issn_l] << entry
        end

        api_id = fields["discourse_journals_api_id"]
        if api_id.present?
          @forum_api_id_index[api_id.to_s] = entry
        end

        if (idx + 1) % 10_000 == 0
          check_cancelled!
          publish_progress(:forum, idx + 1, total, "论坛索引构建中... #{idx + 1}/#{total}")
        end
      end

      publish_progress(
        :forum,
        total,
        total,
        "论坛索引构建完成：#{total} 个话题，#{@forum_index.size} 个唯一标题，#{@forum_issn_index.size} 个 ISSN-L",
      )
    end

    def build_api_index
      publish_progress(:api, 0, 0, "正在获取 API 数据...")

      client = ApiClient.new(rate_limiter: @rate_limiter).start!
      fetched = 0
      cursor = nil
      batch = 0
      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      begin
        loop do
          check_cancelled!

          # Cursor pagination: the API returns nextCursor (the last id of the page)
          # plus hasMore; pass nextCursor back as afterId for the next page until
          # hasMore is false. This is inherently sequential but has no deep-offset
          # cap, so it reaches every journal (page/pageSize topped out at ~100k).
          result = client.fetch_journal_page(cursor: cursor, page_size: API_PAGE_SIZE)
          rows = result[:rows]
          break if rows.empty?

          fetched += process_api_rows(rows)
          batch += 1

          if batch % PROGRESS_BATCH_INTERVAL == 0
            elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time
            speed = elapsed > 0 ? (fetched.to_f / elapsed).round(0) : 0
            publish_progress(:api, fetched, 0, "API 获取中... 已取 #{fetched} 条 (#{speed} 条/秒)")
          end

          next_cursor = result[:next_cursor]
          break if !result[:has_more] || next_cursor.nil?

          cursor = next_cursor
        end
      ensure
        client.finish!
      end

      elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time).round(1)
      publish_progress(
        :api,
        fetched,
        fetched,
        "API 索引构建完成：#{fetched} 条记录，#{@api_index.size} 个唯一标题，" \
          "#{@api_issn_index.size} 个 ISSN-L#{"，跳过 #{@dropped_duplicate_issns} 条重复 ISSN-L" if @dropped_duplicate_issns > 0} (耗时 #{elapsed}s)",
      )
    end

    def process_api_rows(rows)
      count = 0
      rows.each do |row|
        unified = row["unified"] || {}
        canonical_name = unified["canonical_name"]
        next if canonical_name.blank?

        api_id = unified["id"]
        issn_l = unified["issn_l"]

        # Defensive dedupe. Upstream's canonical ISSN projection (contract v4)
        # globally isolates any ISSN that straddles incompatible entities, so a
        # collision here means the guarantee broke — count and log it instead of
        # dropping rows silently, because a dropped row means its forum topic
        # falls into forum_only and gets flagged outdated.
        if issn_l.present? && @api_seen_issns.include?(issn_l)
          @dropped_duplicate_issns += 1
          if @dropped_duplicate_issns <= 20
            Rails.logger.warn(
              "[DiscourseJournals::TitleMatcher] Duplicate ISSN-L #{issn_l} from API " \
                "(id=#{api_id.inspect}, #{canonical_name.inspect}) — record skipped",
            )
          end
          next
        end

        normalized = self.class.normalized_title_key(canonical_name)
        next if normalized.blank?

        entry = {
          api_id: api_id,
          canonical_name: canonical_name,
          issn_l: issn_l,
        }

        if api_id.present?
          @api_id_index[api_id.to_s] = entry
        end

        @api_index[normalized] ||= []
        @api_index[normalized] << entry

        if issn_l.present?
          @api_seen_issns.add(issn_l)
          @api_issn_index[issn_l] = entry
        end

        count += 1
      end
      count
    end


    def cross_match
      publish_progress(:match, 0, 0, "正在进行 API ID、ISSN-L 和标题交叉比对...")

      matched_forum_ids = Set.new
      matched_api_ids = Set.new
      # ISSN-L is the authoritative journal identifier, so it takes priority over
      # the stored api_id (an upstream snapshot that can drift). Order: ISSN-L,
      # then api_id, then title; each later phase skips already-matched forum
      # topics and API records, so a topic is never emitted as a target twice.
      match_issn_l(matched_forum_ids, matched_api_ids)
      match_api_id(matched_forum_ids, matched_api_ids)
      match_by_title(matched_forum_ids, matched_api_ids)

      publish_progress(:match, 1, 1, "比对完成！")
    end

    def match_api_id(matched_forum_ids, matched_api_ids)
      common_api_ids = @forum_api_id_index.keys & @api_id_index.keys
      return if common_api_ids.empty?

      matched_count = 0
      common_api_ids.each do |api_id|
        forum_entry = @forum_api_id_index[api_id]
        api_entry = @api_id_index[api_id]
        next unless forum_entry && api_entry
        # The authoritative ISSN-L phase ran first; skip topics/records it already
        # claimed so a forum topic is never an update target for two API records.
        next if matched_forum_ids.include?(forum_entry[:topic_id])
        next if matched_api_ids.include?(api_entry[:api_id])

        normalized_title = self.class.normalize(api_entry[:canonical_name])

        entry = {
          normalized_title: normalized_title,
          forum: [forum_entry],
          api: [api_entry],
        }

        @results[:exact_1to1] << entry

        matched_forum_ids.add(forum_entry[:topic_id])
        matched_api_ids.add(api_entry[:api_id])
        matched_count += 1
      end

      Rails.logger.info(
        "[DiscourseJournals::TitleMatcher] API ID phase: #{matched_count} matched " \
        "(#{matched_forum_ids.size} forum topics, #{matched_api_ids.size} API records)",
      )
    end

    def match_issn_l(matched_forum_ids, matched_api_ids)
      common_issns = @forum_issn_index.keys & @api_issn_index.keys
      return if common_issns.empty?

      common_issns.each do |issn_l|
        forum_entries = @forum_issn_index[issn_l]
        api_entry = @api_issn_index[issn_l]
        next unless forum_entries&.any? && api_entry
        next if matched_api_ids.include?(api_entry[:api_id])

        fresh_forum = forum_entries.reject { |f| matched_forum_ids.include?(f[:topic_id]) }
        next if fresh_forum.empty?

        normalized_title = self.class.normalize(api_entry[:canonical_name])

        entry = {
          normalized_title: normalized_title,
          forum: fresh_forum,
          api: [api_entry],
        }

        if fresh_forum.size == 1
          @results[:exact_1to1] << entry
        else
          @results[:forum_n_to_api_1] << entry
        end

        fresh_forum.each { |f| matched_forum_ids.add(f[:topic_id]) }
        matched_api_ids.add(api_entry[:api_id])
      end

      Rails.logger.info(
        "[DiscourseJournals::TitleMatcher] ISSN-L phase: #{common_issns.size} matched " \
        "(#{matched_forum_ids.size} forum topics, #{matched_api_ids.size} API records)",
      )
    end

    def match_by_title(matched_forum_ids, matched_api_ids)
      all_normalized_titles = (@forum_index.keys.to_set | @api_index.keys).to_a
      total = all_normalized_titles.size

      all_normalized_titles.each_with_index do |normalized_title, idx|
        forum_entries = @forum_index[normalized_title]
          &.reject { |f| matched_forum_ids.include?(f[:topic_id]) }
        api_entries = @api_index[normalized_title]
          &.reject { |a| matched_api_ids.include?(a[:api_id]) }

        forum_entries = nil if forum_entries&.empty?
        api_entries = nil if api_entries&.empty?

        if forum_entries && api_entries
          forum_count = forum_entries.size
          api_count = api_entries.size

          entry = {
            normalized_title: normalized_title,
            forum: forum_entries,
            api: api_entries,
          }

          if forum_count == 1 && api_count == 1
            @results[:exact_1to1] << entry
          elsif forum_count == 1 && api_count > 1
            @results[:forum_1_to_api_n] << entry
          elsif forum_count > 1 && api_count == 1
            @results[:forum_n_to_api_1] << entry
          else
            @results[:forum_n_to_api_m] << entry
          end
        elsif forum_entries && api_entries.nil?
          # Already-outdated topics are excluded so they are not re-flagged; only
          # genuinely new orphans become forum_only.
          live_forum = forum_entries.reject { |f| f[:outdated] }
          if live_forum.any?
            @results[:forum_only] << {
              normalized_title: normalized_title,
              forum: live_forum,
            }
          end
        elsif forum_entries.nil? && api_entries
          @results[:api_only] << {
            normalized_title: normalized_title,
            api: api_entries,
          }
        end

        if (idx + 1) % 50_000 == 0 || idx + 1 == total
          check_cancelled!
          publish_progress(:match, idx + 1, total, "标题比对中... #{idx + 1}/#{total}")
        end
      end
    end
  end
end
