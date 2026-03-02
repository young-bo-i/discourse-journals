import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { service } from "@ember/service";
import { concat, fn } from "@ember/helper";
import { on } from "@ember/modifier";
import didInsert from "@ember/render-modifiers/modifiers/did-insert";
import willDestroy from "@ember/render-modifiers/modifiers/will-destroy";
import { eq } from "discourse/truth-helpers";
import concatClass from "discourse/helpers/concat-class";

export default class JournalToc extends Component {
  static shouldRender(outletArgs, helper) {
    const siteSettings = helper.siteSettings;

    if (!siteSettings.discourse_journals_enabled) {
      return false;
    }

    const categoryId = siteSettings.discourse_journals_category_id;
    if (!categoryId) {
      return false;
    }

    const topic = outletArgs?.topic;
    if (!topic || !topic.category_id) {
      return false;
    }

    return String(topic.category_id) === String(categoryId);
  }

  @service siteSettings;

  @tracked sections = [];
  @tracked activeId = null;

  _observer = null;
  _scanTimer = null;

  @action
  setup() {
    this._scanTimer = setTimeout(() => this._scanSections(), 300);
  }

  @action
  cleanup() {
    if (this._observer) {
      this._observer.disconnect();
      this._observer = null;
    }
    if (this._scanTimer) {
      clearTimeout(this._scanTimer);
      this._scanTimer = null;
    }
  }

  _scanSections() {
    const nodes = document.querySelectorAll("[data-dj-nav]");
    if (!nodes.length) {
      this._scanTimer = setTimeout(() => this._scanSections(), 500);
      return;
    }

    const items = [];
    nodes.forEach((node) => {
      items.push({
        id: node.id,
        label: node.getAttribute("data-dj-nav"),
      });
    });
    this.sections = items;

    if (items.length) {
      this.activeId = items[0].id;
    }

    this._setupObserver(nodes);
  }

  _setupObserver(nodes) {
    if (this._observer) {
      this._observer.disconnect();
    }

    this._observer = new IntersectionObserver(
      (entries) => {
        for (const entry of entries) {
          if (entry.isIntersecting) {
            this.activeId = entry.target.id;
            break;
          }
        }
      },
      { rootMargin: "-10% 0px -70% 0px", threshold: 0 }
    );

    nodes.forEach((node) => this._observer.observe(node));
  }

  @action
  scrollTo(sectionId, event) {
    event.preventDefault();
    const target = document.getElementById(sectionId);
    if (target) {
      target.scrollIntoView({ behavior: "smooth", block: "start" });
      this.activeId = sectionId;
    }
  }

  <template>
    <div
      class="dj-journal-nav"
      {{didInsert this.setup}}
      {{willDestroy this.cleanup}}
    >
      {{#if this.sections.length}}
        <ul class="dj-journal-nav__list">
          {{#each this.sections as |section|}}
            <li
              class={{concatClass
                "dj-journal-nav__item"
                (if (eq section.id this.activeId) "dj-journal-nav__item--active")
              }}
            >
              <a
                href={{concat "#" section.id}}
                {{on "click" (fn this.scrollTo section.id)}}
              >
                {{section.label}}
              </a>
            </li>
          {{/each}}
        </ul>
      {{/if}}
    </div>
  </template>
}
