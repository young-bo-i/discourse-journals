import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { service } from "@ember/service";
import { on } from "@ember/modifier";
import icon from "discourse/helpers/d-icon";
import I18n from "discourse-i18n";

export default class JournalSearchBox extends Component {
  static shouldRender(outletArgs, helper) {
    const siteSettings = helper.siteSettings;
    
    // 检查插件是否启用
    if (!siteSettings.discourse_journals_enabled) {
      return false;
    }

    // 检查是否配置了期刊分类
    const categoryId = siteSettings.discourse_journals_category_id;
    if (!categoryId) {
      return false;
    }

    // 检查当前话题是否属于期刊分类
    const topic = outletArgs?.model;
    if (!topic || !topic.category_id) {
      return false;
    }

    return String(topic.category_id) === String(categoryId);
  }

  @service siteSettings;
  @service router;

  @tracked searchQuery = "";

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
    if (!this.searchQuery.trim()) {
      return;
    }

    const categoryId = this.siteSettings.discourse_journals_category_id;
    
    this.router.transitionTo("full-page-search", {
      queryParams: {
        q: `${this.searchQuery} category:${categoryId}`,
      },
    });
  }

  <template>
    <div class="journal-search-box">
      <div class="journal-search-input-wrapper">
        {{icon "search" class="search-icon"}}
        <input
          type="text"
          class="journal-search-input"
          placeholder="搜索期刊（输入名称、ISSN、出版商...）"
          value={{this.searchQuery}}
          {{on "input" this.updateQuery}}
          {{on "keypress" this.handleKeyPress}}
        />
        <button
          type="button"
          class="btn btn-primary journal-search-btn"
          {{on "click" this.performSearch}}
        >
          搜索
        </button>
      </div>
    </div>
  </template>
}
