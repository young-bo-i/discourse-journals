import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { service } from "@ember/service";
import { on } from "@ember/modifier";
import { fn } from "@ember/helper";
import { not } from "discourse/truth-helpers";
import { ajax } from "discourse/lib/ajax";
import icon from "discourse/helpers/d-icon";
import discourseDebounce from "discourse/lib/debounce";
import DiscourseURL from "discourse/lib/url";

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
    if (this.results.length > 0) {
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
      const response = await ajax("/search.json", {
        data: {
          q: `${this.searchQuery} category:${this.categoryId}`,
        },
      });

      // 使用 posts 数据源，包含 blurb 摘要信息
      this.results = (response.posts || []).slice(0, 8);
    } catch (e) {
      this.results = [];
    } finally {
      this.loading = false;
    }
  }

  @action
  goToTopic(post) {
    this.showResults = false;
    this.searchQuery = "";
    const topic = post.topic;
    DiscourseURL.routeTo(`/t/${topic.slug}/${topic.id}`);
  }

  @action
  goToFullSearch() {
    this.showResults = false;
    const query = `${this.searchQuery} category:${this.categoryId}`;
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
            placeholder="搜索期刊..."
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
              {{#each this.results as |post|}}
                <div
                  class="journal-search-result-item"
                  role="button"
                  {{on "click" (fn this.goToTopic post)}}
                >
                  <div class="result-title">{{post.topic.title}}</div>
                  {{#if post.blurb}}
                    <div class="result-blurb">{{post.blurb}}</div>
                  {{/if}}
                </div>
              {{/each}}
              <div
                class="journal-search-more"
                role="button"
                {{on "click" this.goToFullSearch}}
              >
                {{icon "magnifying-glass"}}
                <span>查看所有搜索结果</span>
              </div>
            {{else if (not this.loading)}}
              <div class="journal-search-no-results">
                没有找到相关期刊
              </div>
            {{/if}}
          </div>
        {{/if}}
      </div>
    </div>
  </template>
}
