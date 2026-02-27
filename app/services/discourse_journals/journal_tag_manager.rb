# frozen_string_literal: true

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
      if_range: {
        name: "影响因子",
        one_per_topic: true,
        predefined: %w[if:0~1 if:1~3 if:3~5 if:5~10 if:10~20 if:20以上],
      },
      h_index_range: {
        name: "H指数",
        one_per_topic: true,
        predefined: %w[h:0~20 h:20~50 h:50~100 h:100~200 h:200以上],
      },
      sjr_range: {
        name: "SJR值",
        one_per_topic: true,
        predefined: %w[sjr:0~1 sjr:1~2 sjr:2~5 sjr:5以上],
      },
      cpd_range: {
        name: "篇均被引",
        one_per_topic: true,
        predefined: %w[cpd:0~1 cpd:1~3 cpd:3~5 cpd:5~10 cpd:10以上],
      },
      review_speed: {
        name: "审稿速度",
        one_per_topic: true,
        predefined: %w[审稿:0~1月 审稿:1~3月 审稿:3~6月 审稿:6~12月 审稿:12月以上],
      },
      works_range: {
        name: "年发文量",
        one_per_topic: true,
        predefined: %w[发文:0~100 发文:100~500 发文:500~2000 发文:2000以上],
      },
    }.freeze

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
      extract_if_range(normalized, assignments)
      extract_h_index_range(normalized, assignments)
      extract_sjr_range(normalized, assignments)
      extract_cpd_range(normalized, assignments)
      extract_review_speed(normalized, assignments)
      extract_works_range(normalized, assignments)

      assignments
    end

    # ── Cache management ──

    def self.warm_caches!
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

      @_caches_warm = true
    end

    def self.ensure_tag_cached!(name)
      cleaned = DiscourseTagging.clean_tag(name.to_s)
      return nil if cleaned.blank?

      unless @_tag_cache.key?(cleaned)
        tag = Tag.find_by(name: cleaned)
        unless tag
          tag = Tag.create!(name: cleaned)
        end
        @_tag_cache[cleaned] = tag
      end
      @_tag_cache[cleaned]
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
      tag = Tag.find_by(name: cleaned)
      @_tag_cache[cleaned] = tag if tag
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

      TagGroupMembership.create!(tag_group_id: group.id, tag_id: tag.id)
      @_membership_set.add(pair)
    rescue ActiveRecord::RecordNotUnique
      @_membership_set.add(pair)
    end

    def self.reset_cache!
      @_caches_warm = nil
      @_tag_cache = nil
      @_group_cache = nil
      @_membership_set = nil
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

    def self.extract_if_range(normalized, assignments)
      val = normalized.dig(:jcr, :data)&.first&.dig(:impact_factor)
      return unless val
      v = val.to_f
      return if v <= 0

      tag = if v < 1 then "if:0~1"
            elsif v < 3 then "if:1~3"
            elsif v < 5 then "if:3~5"
            elsif v < 10 then "if:5~10"
            elsif v < 20 then "if:10~20"
            else "if:20以上"
            end
      assignments[:if_range] = [tag]
    end

    def self.extract_h_index_range(normalized, assignments)
      val = normalized.dig(:scimago, :data)&.first&.dig(:h_index)
      val = normalized.dig(:metrics, :h_index) if val.nil?
      return unless val
      v = val.to_i
      return if v < 0

      tag = if v < 20 then "h:0~20"
            elsif v < 50 then "h:20~50"
            elsif v < 100 then "h:50~100"
            elsif v < 200 then "h:100~200"
            else "h:200以上"
            end
      assignments[:h_index_range] = [tag]
    end

    def self.extract_sjr_range(normalized, assignments)
      val = normalized.dig(:scimago, :data)&.first&.dig(:sjr)
      return unless val
      v = val.to_f
      return if v <= 0

      tag = if v < 1 then "sjr:0~1"
            elsif v < 2 then "sjr:1~2"
            elsif v < 5 then "sjr:2~5"
            else "sjr:5以上"
            end
      assignments[:sjr_range] = [tag]
    end

    def self.extract_cpd_range(normalized, assignments)
      val = normalized.dig(:scimago, :data)&.first&.dig(:citations_per_doc_2years)
      return unless val
      v = val.to_f
      return if v < 0

      tag = if v < 1 then "cpd:0~1"
            elsif v < 3 then "cpd:1~3"
            elsif v < 5 then "cpd:3~5"
            elsif v < 10 then "cpd:5~10"
            else "cpd:10以上"
            end
      assignments[:cpd_range] = [tag]
    end

    def self.extract_review_speed(normalized, assignments)
      val = normalized.dig(:scirev, :first_review_months)
      return unless val
      v = val.to_f
      return if v <= 0

      tag = if v < 1 then "审稿:0~1月"
            elsif v < 3 then "审稿:1~3月"
            elsif v < 6 then "审稿:3~6月"
            elsif v < 12 then "审稿:6~12月"
            else "审稿:12月以上"
            end
      assignments[:review_speed] = [tag]
    end

    def self.extract_works_range(normalized, assignments)
      val = normalized.dig(:scimago, :data)&.first&.dig(:total_docs_year)
      if val.nil?
        latest = normalized.dig(:metrics, :counts_by_year)&.first
        val = latest&.dig(:works_count)
      end
      return unless val
      v = val.to_i
      return if v <= 0

      tag = if v < 100 then "发文:0~100"
            elsif v < 500 then "发文:100~500"
            elsif v < 2000 then "发文:500~2000"
            else "发文:2000以上"
            end
      assignments[:works_range] = [tag]
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
                         :extract_if_range,
                         :extract_h_index_range,
                         :extract_sjr_range,
                         :extract_cpd_range,
                         :extract_review_speed,
                         :extract_works_range,
                         :match_major_publisher,
                         :major_publisher_list,
                         :sanitize_tag_name,
                         :ensure_tag_cached!,
                         :ensure_membership_cached!
  end
end
