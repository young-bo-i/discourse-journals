import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { service } from "@ember/service";
import { on } from "@ember/modifier";
import icon from "discourse/helpers/d-icon";
import i18n from "discourse/helpers/i18n";

export default class JournalSearchBox extends Component {
  @service siteSettings;
  @service router;

  @tracked searchQuery = "";

  get isJournalCategory() {
    const categoryId = this.siteSettings.discourse_journals_category_id;
    if (!categoryId) return false;

    const topic = this.args.outletArgs?.model;
    if (!topic) return false;

    return topic.category_id === parseInt(categoryId, 10);
  }

  @action
  updateQuery(event) {
    this.searchQuery = event.target.value;
  }

  @action
  handleKeyPress(event) {
    if (event.key === "Enter") {
      this.performSearch();
    }
  }

  @action
  performSearch() {
    if (!this.searchQuery.trim()) return;

    const categoryId = this.siteSettings.discourse_journals_category_id;
    const searchUrl = `/search?q=${encodeURIComponent(this.searchQuery)}%20%23${categoryId}`;
    
    this.router.transitionTo("full-page-search", {
      queryParams: {
        q: `${this.searchQuery} category:${categoryId}`,
      },
    });
  }

  <template>
    {{#if this.isJournalCategory}}
      <div class="journal-search-box">
        <div class="journal-search-input-wrapper">
          {{icon "search" class="search-icon"}}
          <input
            type="text"
            class="journal-search-input"
            placeholder={{i18n "discourse_journals.search.placeholder"}}
            value={{this.searchQuery}}
            {{on "input" this.updateQuery}}
            {{on "keypress" this.handleKeyPress}}
          />
          <button
            type="button"
            class="btn btn-primary journal-search-btn"
            {{on "click" this.performSearch}}
          >
            {{i18n "discourse_journals.search.button"}}
          </button>
        </div>
      </div>
    {{/if}}
  </template>
}
