# frozen_string_literal: true

require "monitor"

module DiscourseJournals
  class JournalTagManager
    MAJOR_PUBLISHERS_DEFAULT = [
      "Elsevier",
      "Springer Nature",
      "Wiley",
      "Taylor & Francis",
      "SAGE",
      "Oxford University Press",
      "Cambridge University Press",
      "IEEE",
      "ACM",
      "MDPI",
      "Frontiers",
      "PLOS",
      "BMJ",
      "Wolters Kluwer",
      "American Chemical Society",
      "Royal Society of Chemistry",
      "De Gruyter",
      "Emerald",
      "IOP Publishing",
      "Nature Publishing Group",
    ].freeze

    PUBLISHER_TAG_NAMES = {
      "Oxford University Press" => "oxford-univ-press",
      "Cambridge University Press" => "cambridge-univ-press",
      "American Chemical Society" => "acs",
      "Royal Society of Chemistry" => "rsc",
      "Nature Publishing Group" => "nature-pub-group",
    }.freeze

    TAG_GROUP_DEFS = {
      jcr_quartile: {
        name: "JCR Quartile",
        one_per_topic: true,
        predefined: %w[jcr:q1 jcr:q2 jcr:q3 jcr:q4],
      },
      sjr_quartile: {
        name: "SJR Quartile",
        one_per_topic: true,
        predefined: %w[sjr:q1 sjr:q2 sjr:q3 sjr:q4],
      },
      cas_zone: {
        name: "中科院分区",
        one_per_topic: true,
        predefined: %w[中科院:1区 中科院:2区 中科院:3区 中科院:4区],
      },
      cas_top: {
        name: "中科院Top",
        one_per_topic: true,
        predefined: %w[中科院:top],
      },
      ccf_rank: {
        name: "CCF Rank",
        one_per_topic: true,
        predefined: %w[ccf:a ccf:b ccf:c],
      },
      wos_index: {
        name: "WoS Index",
        one_per_topic: true,
        predefined: %w[scie ssci esci ahci],
      },
      oa_status: {
        name: "Open Access",
        one_per_topic: true,
        predefined: %w[diamond-oa oa 非oa],
      },
      doaj: {
        name: "DOAJ",
        one_per_topic: true,
        predefined: %w[doaj收录],
      },
      warning: {
        name: "期刊预警",
        one_per_topic: true,
        predefined: [],
      },
      subject: {
        name: "学科分类",
        one_per_topic: true,
        predefined: [],
      },
      country: {
        name: "国家/地区",
        one_per_topic: true,
        predefined: [],
      },
      publisher: {
        name: "出版商",
        one_per_topic: true,
        predefined: [],
      },
    }.freeze

    RETIRED_TAG_GROUPS = %w[影响因子 H指数 SJR值 篇均被引 审稿速度 年发文量].freeze

    @_cache_mutex = Monitor.new

    def self.apply_tags!(topic, normalized)
      return unless SiteSetting.tagging_enabled

      assignments = build_tag_assignments(normalized)
      all_tag_names = assignments.values.flatten.compact.uniq
      return if all_tag_names.empty?

      warm_caches!

      all_tag_names.each { |name| ensure_tag_cached!(name) }
      assignments.each do |group_key, tag_names|
        tag_names.each { |name| ensure_membership_cached!(group_key, name) }
      end

      DiscourseTagging.add_or_create_tags_by_name(topic, all_tag_names, unlimited: true)
    end

    def self.build_tag_assignments(normalized)
      assignments = {}

      extract_jcr_quartile(normalized, assignments)
      extract_sjr_quartile(normalized, assignments)
      extract_cas_zone(normalized, assignments)
      extract_cas_top(normalized, assignments)
      extract_ccf_rank(normalized, assignments)
      extract_wos_index(normalized, assignments)
      extract_oa_status(normalized, assignments)
      extract_doaj(normalized, assignments)
      extract_warning(normalized, assignments)
      extract_subject(normalized, assignments)
      extract_country(normalized, assignments)
      extract_publisher(normalized, assignments)

      assignments
    end

    # ── Cache management ──

    def self.warm_caches!
      return if @_caches_warm

      @_cache_mutex.synchronize do
        return if @_caches_warm

        @_tag_cache = {}
        Tag.find_each { |t| @_tag_cache[t.name] = t }

        @_group_cache = {}
        TagGroup.all.each { |g| @_group_cache[g.name] = g }

        @_membership_set = Set.new
        TagGroupMembership.pluck(:tag_group_id, :tag_id).each do |gid, tid|
          @_membership_set.add([gid, tid])
        end

        TAG_GROUP_DEFS.each do |_key, defn|
          group = @_group_cache[defn[:name]]
          unless group
            group = TagGroup.find_or_create_by!(name: defn[:name]) do |g|
              g.one_per_topic = defn[:one_per_topic]
            end
            @_group_cache[group.name] = group
          end
          if group.one_per_topic != defn[:one_per_topic]
            group.update!(one_per_topic: defn[:one_per_topic])
          end

          defn[:predefined].each do |tag_name|
            ensure_tag_cached!(tag_name)
            ensure_membership_cached!(_key, tag_name)
          end
        end

        cleanup_retired_tag_groups!

        @_caches_warm = true
      end
    end

    def self.ensure_tag_cached!(name)
      cleaned = DiscourseTagging.clean_tag(name.to_s)
      return nil if cleaned.blank?

      return @_tag_cache[cleaned] if @_tag_cache.key?(cleaned)

      @_cache_mutex.synchronize do
        return @_tag_cache[cleaned] if @_tag_cache.key?(cleaned)

        tag = Tag.find_by(name: cleaned) || Tag.create!(name: cleaned)
        @_tag_cache[cleaned] = tag
      end
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
      tag = Tag.find_by(name: cleaned)
      @_cache_mutex.synchronize { @_tag_cache[cleaned] = tag } if tag
      tag
    end

    def self.ensure_membership_cached!(group_key, tag_name)
      cleaned = DiscourseTagging.clean_tag(tag_name.to_s)
      return if cleaned.blank?

      tag = @_tag_cache[cleaned]
      return unless tag

      defn = TAG_GROUP_DEFS[group_key]
      return unless defn

      group = @_group_cache[defn[:name]]
      return unless group

      pair = [group.id, tag.id]
      return if @_membership_set.include?(pair)

      @_cache_mutex.synchronize do
        return if @_membership_set.include?(pair)

        TagGroupMembership.create!(tag_group_id: group.id, tag_id: tag.id)
        @_membership_set.add(pair)
      end
    rescue ActiveRecord::RecordNotUnique
      @_cache_mutex.synchronize { @_membership_set.add(pair) }
    end

    def self.reset_cache!
      @_cache_mutex.synchronize do
        @_caches_warm = nil
        @_tag_cache = nil
        @_group_cache = nil
        @_membership_set = nil
      end
    end

    def self.cleanup_retired_tag_groups!
      RETIRED_TAG_GROUPS.each do |group_name|
        group = @_group_cache.delete(group_name)
        group ||= TagGroup.find_by(name: group_name)
        next unless group

        TagGroupMembership.where(tag_group_id: group.id).delete_all
        group.destroy
        Rails.logger.info("[DiscourseJournals] Removed retired tag group: #{group_name}")
      rescue ActiveRecord::RecordNotDestroyed, ActiveRecord::StatementInvalid => e
        Rails.logger.warn("[DiscourseJournals] Failed to remove retired tag group #{group_name}: #{e.message}")
      end
    end

    # --- Tag extraction methods ---

    def self.extract_jcr_quartile(normalized, assignments)
      quartile = normalized.dig(:jcr, :data)&.first&.dig(:quartile)
      return unless quartile.present?

      tag = case quartile.to_s.upcase
            when "Q1" then "jcr:q1"
            when "Q2" then "jcr:q2"
            when "Q3" then "jcr:q3"
            when "Q4" then "jcr:q4"
            end
      assignments[:jcr_quartile] = [tag] if tag
    end

    def self.extract_sjr_quartile(normalized, assignments)
      quartile = normalized.dig(:scimago, :data)&.first&.dig(:best_quartile)
      return unless quartile.present?

      tag = case quartile.to_s.upcase
            when "Q1" then "sjr:q1"
            when "Q2" then "sjr:q2"
            when "Q3" then "sjr:q3"
            when "Q4" then "sjr:q4"
            end
      assignments[:sjr_quartile] = [tag] if tag
    end

    def self.extract_cas_zone(normalized, assignments)
      quartile = normalized.dig(:cas_partition, :data)&.first&.dig(:major_quartile)
      return unless quartile.present?

      num = quartile.to_s.match(/(\d+)/)&.captures&.first
      return unless num && (1..4).cover?(num.to_i)

      assignments[:cas_zone] = ["中科院:#{num}区"]
    end

    def self.extract_cas_top(normalized, assignments)
      top = normalized.dig(:cas_partition, :data)&.first&.dig(:top)
      return unless top.present?

      is_top = top == true || top == "是" || top == "yes" || top == 1 || top == "1"
      assignments[:cas_top] = ["中科院:top"] if is_top
    end

    def self.extract_ccf_rank(normalized, assignments)
      rank = normalized.dig(:ccf, :rank)
      return unless rank.present?

      tag = case rank.to_s.upcase.gsub(/\s+/, "")
            when "A" then "ccf:a"
            when "B" then "ccf:b"
            when "C" then "ccf:c"
            end
      assignments[:ccf_rank] = [tag] if tag
    end

    def self.extract_wos_index(normalized, assignments)
      wos = normalized.dig(:cas_partition, :data)&.first&.dig(:web_of_science)
      return unless wos.present?

      tag = wos.to_s.strip.downcase
      assignments[:wos_index] = [tag] if TAG_GROUP_DEFS[:wos_index][:predefined].include?(tag)
    end

    def self.extract_oa_status(normalized, assignments)
      oa = normalized.dig(:open_access)
      return unless oa

      if oa[:diamond_oa] == true
        assignments[:oa_status] = ["diamond-oa"]
      elsif oa[:is_oa] == true
        assignments[:oa_status] = ["oa"]
      elsif oa[:is_oa] == false
        assignments[:oa_status] = ["非oa"]
      end
    end

    def self.extract_doaj(normalized, assignments)
      in_doaj = normalized.dig(:open_access, :is_in_doaj)
      assignments[:doaj] = ["doaj收录"] if in_doaj == true
    end

    def self.extract_warning(normalized, assignments)
      level = normalized.dig(:warning, :data)&.first&.dig(:level)
      return unless level.present?

      tag_name = sanitize_tag_name("预警:#{level.to_s.strip}")
      assignments[:warning] = [tag_name] if tag_name
    end

    def self.extract_subject(normalized, assignments)
      category = normalized.dig(:cas_partition, :data)&.first&.dig(:major_category)
      return unless category.present?

      tag_name = sanitize_tag_name(category.to_s.strip)
      assignments[:subject] = [tag_name] if tag_name
    end

    def self.extract_country(normalized, assignments)
      country = normalized.dig(:publication, :country_name)
      country = normalized.dig(:publication, :country_code) if country.blank?
      return unless country.present?

      tag_name = sanitize_tag_name(country.to_s.strip)
      assignments[:country] = [tag_name] if tag_name
    end

    def self.extract_publisher(normalized, assignments)
      publisher = normalized.dig(:publication, :publisher_name)
      return unless publisher.present?

      matched = match_major_publisher(publisher.to_s)
      return unless matched

      tag_name = PUBLISHER_TAG_NAMES[matched] || sanitize_tag_name(matched)
      assignments[:publisher] = [tag_name] if tag_name
    end

    def self.match_major_publisher(publisher_name)
      publishers = major_publisher_list
      downcased = publisher_name.downcase

      publishers.find { |p| downcased.include?(p.downcase) }
    end

    def self.sanitize_tag_name(name)
      return nil if name.blank?
      DiscourseTagging.clean_tag(name.to_s).presence
    end

    def self.major_publisher_list
      custom = SiteSetting.discourse_journals_major_publishers
      if custom.present?
        custom.split(",").map(&:strip).reject(&:blank?)
      else
        MAJOR_PUBLISHERS_DEFAULT
      end
    end

    private_class_method :extract_jcr_quartile,
                         :extract_sjr_quartile,
                         :extract_cas_zone,
                         :extract_cas_top,
                         :extract_ccf_rank,
                         :extract_wos_index,
                         :extract_oa_status,
                         :extract_doaj,
                         :extract_warning,
                         :extract_subject,
                         :extract_country,
                         :extract_publisher,
                         :match_major_publisher,
                         :major_publisher_list,
                         :sanitize_tag_name,
                         :ensure_tag_cached!,
                         :ensure_membership_cached!,
                         :cleanup_retired_tag_groups!
  end
end
