# frozen_string_literal: true

module DiscourseJournals
  # Meta description built from the synced journal record. It leads with the
  # metrics people search for and stops at the length search results display.
  class JournalSummary
    MAX_LENGTH = 160
    MAX_SUBJECTS = 3
    EMPTY_VALUES = %w[none null nan].freeze

    def initialize(title:, issn: nil, publisher: nil, country: nil, data: nil)
      @data = data || {}
      @title = title.to_s.strip
      @issn = present(issn)
      @publisher = present(publisher) || present(@data.dig(:publication, :publisher_name))
      @country = present(@data.dig(:publication, :country_name)) || present(country)
    end

    def to_s
      sentences = [ranking, identity, access, output, research].compact
      return "" if @title.empty? || sentences.empty?

      text = +"#{@title}#{t(:title_separator)}#{sentence(sentences.shift)}"
      sentences.each do |clause|
        next_sentence = sentence(clause)
        break if text.length + next_sentence.length > MAX_LENGTH
        text << next_sentence
      end
      text.strip
    end

    private

    def ranking
      jcr = latest(:jcr)
      impact = present(jcr&.dig(:impact_factor))
      return clauses(sjr, cas_partition, cas_top) if impact.nil?

      year = present(jcr[:year])
      quartile = present(jcr[:quartile])
      clauses(
        year ? t(:impact_factor_year, year: year, value: impact) : t(:impact_factor, value: impact),
        quartile && t(:jcr_quartile, quartile: quartile),
        cas_partition,
        cas_top,
      )
    end

    def sjr
      scimago = latest(:scimago)
      value = present(scimago&.dig(:sjr))
      return if value.nil?

      quartile = present(scimago[:best_quartile])
      quartile ? t(:sjr_with_quartile, value: value, quartile: quartile) : t(:sjr, value: value)
    end

    def cas_partition
      cas = latest(:cas_partition)
      category = present(cas&.dig(:major_category))
      zone = present(cas&.dig(:major_quartile))&.slice(/\d/)
      t(:cas_partition, category: category, zone: zone) if category && zone
    end

    def cas_top
      t(:cas_top) if truthy?(latest(:cas_partition)&.dig(:top))
    end

    def identity
      clauses(
        @issn && t(:issn, issn: @issn),
        @publisher && t(:publisher, publisher: @publisher),
        @country && t(:country, country: @country),
      )
    end

    def access
      open_access = @data[:open_access] || {}
      clauses(
        truthy?(open_access[:is_oa]) && t(:open_access),
        truthy?(open_access[:is_in_doaj]) && t(:doaj),
      )
    end

    def output
      metrics = @data[:metrics] || {}
      works = present(metrics[:works_count])
      citations = present(metrics[:cited_by_count])
      h_index = present(metrics[:h_index])
      clauses(
        works && t(:works, number: works),
        citations && t(:citations, number: citations),
        h_index && t(:h_index, value: h_index),
      )
    end

    def research
      subjects = Array(@data.dig(:subjects_topics, :subjects)).filter_map { |s| present(s) }
      return if subjects.empty?

      t(:subjects, subjects: subjects.first(MAX_SUBJECTS).join(t(:list_separator)))
    end

    def latest(source)
      Array(@data.dig(source, :data)).first
    end

    def clauses(*parts)
      parts.grep(String).join(t(:clause_separator)).presence
    end

    def sentence(clause)
      "#{clause.upcase_first}#{t(:sentence_end)}"
    end

    def present(value)
      string = value.to_s.strip
      string unless string.empty? || EMPTY_VALUES.include?(string.downcase)
    end

    def truthy?(value)
      value == true || %w[true 是].include?(value.to_s.strip.downcase)
    end

    def t(key, **args)
      I18n.t("discourse_journals.summary.#{key}", **args)
    end
  end
end
