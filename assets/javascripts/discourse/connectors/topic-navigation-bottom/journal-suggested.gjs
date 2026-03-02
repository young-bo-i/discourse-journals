import Component from "@glimmer/component";
import { service } from "@ember/service";
import { on } from "@ember/modifier";
import { fn } from "@ember/helper";
import DiscourseURL from "discourse/lib/url";
import { i18n } from "discourse-i18n";

export default class JournalSuggested extends Component {
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

  get topics() {
    const suggested = this.args.outletArgs?.model?.suggestedTopics;
    if (!suggested) {
      return [];
    }
    const max = this.siteSettings.discourse_journals_suggested_count || 5;
    return suggested.slice(0, max);
  }

  get title() {
    return i18n("discourse_journals.suggested_title");
  }

  navigateTo = (topic, event) => {
    event.preventDefault();
    DiscourseURL.routeTo(`/t/${topic.slug}/${topic.id}`);
  };

  <template>
    {{#if this.topics.length}}
      <div class="dj-journal-suggested">
        <div class="dj-journal-suggested__title">{{this.title}}</div>
        <ul class="dj-journal-suggested__list">
          {{#each this.topics as |topic|}}
            <li class="dj-journal-suggested__item">
              <a
                href="/t/{{topic.slug}}/{{topic.id}}"
                title={{topic.title}}
                {{on "click" (fn this.navigateTo topic)}}
              >
                {{topic.title}}
              </a>
            </li>
          {{/each}}
        </ul>
      </div>
    {{/if}}
  </template>
}
