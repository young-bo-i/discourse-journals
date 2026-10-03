import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { service } from "@ember/service";
import { cancel, later } from "@ember/runloop";
import { on } from "@ember/modifier";
import { fn } from "@ember/helper";
import { not } from "discourse/truth-helpers";
import icon from "discourse/helpers/d-icon";
import { ajax } from "discourse/lib/ajax";
import discourseDebounce from "discourse/lib/debounce";
import DiscourseURL from "discourse/lib/url";
import { i18n } from "discourse-i18n";

// Discourse can drop short terms while retaining the category filter, leaving a broad query.
const MIN_JOURNAL_SEARCH_TERM_LENGTH = 4;

export default class JournalSearchBox extends Component {
  static shouldRender(outletArgs, helper) {
    const siteSettings = helper.siteSettings;
    
    if (!siteSettings.discourse_journals_enabled) {
      return false;
    }

    const categoryId = siteSettings.discourse_journals_category_id;
    if (!categoryId) {
      return false;
    }

    const topic = outletArgs?.model;
    if (!topic || !topic.category_id) {
      return false;
    }

    return String(topic.category_id) === String(categoryId);
  }

  @service a11y;
  @service siteSettings;

  @tracked searchQuery = "";
  @tracked results = [];
  @tracked loading = false;
  @tracked showResults = false;
  @tracked showMinLengthHint = false;

  #searchGeneration = 0;
  #debouncedSearch;
  #activeSearch;
  #blurTimer;

  willDestroy() {
    this.#cancelSearch();
    cancel(this.#blurTimer);
    super.willDestroy(...arguments);
  }

  get categoryId() {
    return this.siteSettings.discourse_journals_category_id;
  }

  get minimumSearchTermLength() {
    return Math.max(
      MIN_JOURNAL_SEARCH_TERM_LENGTH,
      Number(this.siteSettings.min_search_term_length) || 0
    );
  }

  @action
  onInput(event) {
    this.#cancelSearch();
    this.searchQuery = event.target.value;
    this.results = [];
    this.loading = false;
    this.showResults = false;
    this.showMinLengthHint = false;

    if (this.#canSearch(this.searchQuery.trim())) {
      this.#debouncedSearch = discourseDebounce(this, this.performSearch, 600);
    }
  }

  @action
  onFocus() {
    cancel(this.#blurTimer);
    if (this.results.length > 0 || this.showMinLengthHint) {
      this.showResults = true;
    }
  }

  @action
  onBlur() {
    this.#blurTimer = later(this, () => {
      this.showResults = false;
    }, 200);
  }

  @action
  onKeyDown(event) {
    // 如果正在使用输入法组合，不触发搜索
    if (event.isComposing) {
      return;
    }

    if (event.key === "Enter" && this.searchQuery.trim()) {
      this.goToFullSearch(event);
    }
    if (event.key === "Escape") {
      this.showResults = false;
    }
  }

  @action
  async performSearch() {
    this.#debouncedSearch = null;
    const query = this.searchQuery.trim();
    if (!this.#canSearch(query)) {
      return;
    }

    const generation = this.#searchGeneration;
    this.loading = true;
    this.showResults = true;

    try {
      // A dedicated title/ISSN lookup: core full-text search over every journal
      // post takes seconds and holds a web worker for the whole time.
      const search = ajax("/journals/search", { data: { q: query } });
      this.#activeSearch = search;
      const results = await search;

      if (this.#searchGeneration !== generation) {
        return;
      }

      this.results = results?.topics || [];
    } catch (e) {
      if (this.#searchGeneration !== generation) {
        return;
      }
      this.results = [];
    } finally {
      if (this.#searchGeneration === generation) {
        this.#activeSearch = null;
        this.loading = false;
      }
    }
  }

  @action
  goToTopic(topic, event) {
    event.preventDefault();
    this.#cancelSearch();
    this.showResults = false;
    this.searchQuery = "";
    this.results = [];
    DiscourseURL.routeTo(`/t/${topic.slug}/${topic.id}`);
  }

  @action
  goToFullSearch(event) {
    if (event) {
      event.preventDefault();
    }
    this.#cancelSearch();
    const term = this.searchQuery.trim();
    if (!this.#canSearch(term)) {
      this.showMinLengthHint = Boolean(term);
      this.showResults = Boolean(term);
      if (term) {
        this.a11y.announce(
          i18n("discourse_journals.search.min_length", {
            min: this.minimumSearchTermLength,
          }),
          "polite"
        );
      }
      return;
    }

    const query = `${term} category:${this.categoryId}`;
    this.showResults = false;
    this.searchQuery = "";
    this.results = [];
    DiscourseURL.routeTo(`/search?q=${encodeURIComponent(query)}`);
  }

  #canSearch(query) {
    // Search operators do not count as journal terms.
    return query.split(/\s+/).some(
      (part) =>
        !part.includes(":") &&
        !/^[#@]/u.test(part) &&
        part
          .match(/[\p{L}\p{N}]+/gu)
          ?.some((term) => term.length >= this.minimumSearchTermLength)
    );
  }

  #cancelSearch() {
    this.#searchGeneration++;
    cancel(this.#debouncedSearch);
    this.#debouncedSearch = null;
    this.#activeSearch?.abort();
    this.#activeSearch = null;
  }

  <template>
    <div class="journal-search-box">
      <div class="journal-search-container">
        <div class="journal-search-input-wrapper">
          {{icon "magnifying-glass" class="search-icon"}}
          <input
            type="text"
            class="journal-search-input"
            placeholder={{i18n "discourse_journals.search.placeholder"}}
            value={{this.searchQuery}}
            autocomplete="off"
            {{on "input" this.onInput}}
            {{on "focus" this.onFocus}}
            {{on "blur" this.onBlur}}
            {{on "keydown" this.onKeyDown}}
          />
          {{#if this.loading}}
            <span class="loading-spinner">{{icon "spinner" class="fa-spin"}}</span>
          {{/if}}
        </div>

        {{#if this.showResults}}
          <div class="journal-search-results">
            {{#if this.showMinLengthHint}}
              <div class="journal-search-no-results">
                {{i18n "discourse_journals.search.min_length" min=this.minimumSearchTermLength}}
              </div>
            {{else if this.results.length}}
              <ul class="journal-search-list">
                {{#each this.results as |topic|}}
                  <li class="journal-search-item">
                    <a
                      class="search-link"
                      href="/t/{{topic.slug}}/{{topic.id}}"
                      {{on "click" (fn this.goToTopic topic)}}
                    >
                      <span class="topic">
                        <span class="first-line">
                          <span class="topic-title">{{topic.title}}</span>
                        </span>
                        {{! The lookup returns plain objects; core's tag
                            helper only accepts topic models. }}
                        {{#if this.siteSettings.tagging_enabled}}
                          <span class="second-line">
                            <span class="discourse-tags">
                              {{#each topic.tags as |tag|}}
                                <span class="discourse-tag simple">{{tag}}</span>
                              {{/each}}
                            </span>
                          </span>
                        {{/if}}
                      </span>
                      {{#if topic.excerpt}}
                        <span class="blurb">
                          <span class="blurb-text">{{topic.excerpt}}</span>
                        </span>
                      {{/if}}
                    </a>
                  </li>
                {{/each}}
              </ul>
              <a
                class="journal-search-more search-link"
                href="/search?q={{this.searchQuery}} category:{{this.categoryId}}"
                {{on "click" this.goToFullSearch}}
              >
                {{icon "magnifying-glass"}}
                <span>{{i18n "discourse_journals.search.more"}}</span>
              </a>
            {{else if (not this.loading)}}
              <div class="journal-search-no-results">
                {{i18n "discourse_journals.search.no_results"}}
              </div>
            {{/if}}
          </div>
        {{/if}}
      </div>
    </div>
  </template>
}
