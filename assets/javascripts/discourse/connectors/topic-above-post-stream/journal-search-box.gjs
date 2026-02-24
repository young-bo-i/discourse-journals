import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { service } from "@ember/service";
import { on } from "@ember/modifier";
import { fn } from "@ember/helper";
import { not } from "discourse/truth-helpers";
import { htmlSafe } from "@ember/template";
import icon from "discourse/helpers/d-icon";
import categoryLink from "discourse/helpers/category-link";
import discourseTags from "discourse/helpers/discourse-tags";
import ageWithTooltip from "discourse/helpers/age-with-tooltip";
import discourseDebounce from "discourse/lib/debounce";
import { searchForTerm } from "discourse/lib/search";
import DiscourseURL from "discourse/lib/url";
import { i18n } from "discourse-i18n";

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

  @service siteSettings;

  @tracked searchQuery = "";
  @tracked results = [];
  @tracked loading = false;
  @tracked showResults = false;

  get categoryId() {
    return this.siteSettings.discourse_journals_category_id;
  }

  @action
  onInput(event) {
    this.searchQuery = event.target.value;
    if (this.searchQuery.trim().length >= 2) {
      discourseDebounce(this, this.performSearch, 300);
    } else {
      this.results = [];
      this.showResults = false;
    }
  }

  @action
  onFocus() {
    // 只有当搜索框有内容且有结果时才显示
    if (this.searchQuery.trim().length >= 2 && this.results.length > 0) {
      this.showResults = true;
    }
  }

  @action
  onBlur() {
    setTimeout(() => {
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
      this.goToFullSearch();
    }
    if (event.key === "Escape") {
      this.showResults = false;
    }
  }

  @action
  async performSearch() {
    if (!this.searchQuery.trim()) {
      return;
    }

    this.loading = true;
    this.showResults = true;

    try {
      // 使用 searchForTerm 来正确处理数据，自动关联 topic 到 post
      const results = await searchForTerm(`${this.searchQuery} category:${this.categoryId}`, {
        typeFilter: "topic",
      });

      this.results = (results?.posts || []).slice(0, 8);
    } catch (e) {
      this.results = [];
    } finally {
      this.loading = false;
    }
  }

  @action
  goToTopic(post, event) {
    event.preventDefault();
    this.showResults = false;
    this.searchQuery = "";
    this.results = [];  // 清空历史结果
    const topic = post.topic;
    DiscourseURL.routeTo(`/t/${topic.slug}/${topic.id}`);
  }

  @action
  goToFullSearch(event) {
    if (event) {
      event.preventDefault();
    }
    const query = `${this.searchQuery} category:${this.categoryId}`;
    this.showResults = false;
    this.searchQuery = "";
    this.results = [];  // 清空历史结果
    DiscourseURL.routeTo(`/search?q=${encodeURIComponent(query)}`);
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
            {{#if this.results.length}}
              <ul class="journal-search-list">
                {{#each this.results as |post|}}
                  <li class="journal-search-item">
                    <a
                      class="search-link"
                      href="/t/{{post.topic.slug}}/{{post.topic.id}}"
                      {{on "click" (fn this.goToTopic post)}}
                    >
                      <span class="topic">
                        <span class="first-line">
                          <span class="topic-title">{{post.topic.title}}</span>
                        </span>
                        <span class="second-line">
                          {{categoryLink post.topic.category link=false}}
                          {{#if this.siteSettings.tagging_enabled}}
                            {{discourseTags post.topic tagName="span"}}
                          {{/if}}
                        </span>
                      </span>
                      {{#if post.blurb}}
                        <span class="blurb">
                          {{ageWithTooltip post.created_at}}
                          <span class="blurb-separator"> - </span>
                          <span class="blurb-text">{{htmlSafe post.blurb}}</span>
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
