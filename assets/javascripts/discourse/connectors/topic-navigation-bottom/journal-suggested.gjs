import Component from "@glimmer/component";
import { service } from "@ember/service";
import { on } from "@ember/modifier";
import { fn } from "@ember/helper";
import DiscourseURL from "discourse/lib/url";
import { i18n } from "discourse-i18n";

const COVER_BASE = "https://journal.scholay.com";

const HIGHLIGHT_PREFIXES = [
  "jcr:",
  "sjr:",
  "ccf:",
  "中科院:",
];

const HIGHLIGHT_EXACT = new Set([
  "scie",
  "ssci",
  "esci",
  "ahci",
]);

const MAX_TAGS = 3;

function isHighlightTag(tag) {
  if (HIGHLIGHT_EXACT.has(tag)) {
    return true;
  }
  return HIGHLIGHT_PREFIXES.some((p) => tag.startsWith(p));
}

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
    return suggested.slice(0, max).map((t) => ({
      id: t.id,
      slug: t.slug,
      title: t.title,
      initial: (t.title || "?")[0],
      coverUrl: this._resolveCover(t),
      tags: this._filterTags(t.tags),
    }));
  }

  get title() {
    return i18n("discourse_journals.suggested_title");
  }

  _resolveCover(topic) {
    if (topic.image_url) {
      return topic.image_url;
    }
    const raw = topic.discourse_journals_cover_url;
    if (!raw) {
      return null;
    }
    if (raw.startsWith("http")) {
      return raw;
    }
    return `${COVER_BASE}${raw}`;
  }

  _filterTags(tags) {
    if (!tags || !tags.length) {
      return [];
    }
    const result = [];
    for (const tag of tags) {
      if (result.length >= MAX_TAGS) {
        break;
      }
      if (isHighlightTag(tag)) {
        result.push(tag);
      }
    }
    return result;
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
                {{#if topic.coverUrl}}
                  <img
                    class="dj-journal-suggested__cover"
                    src={{topic.coverUrl}}
                    alt=""
                    loading="lazy"
                  />
                {{else}}
                  <span class="dj-journal-suggested__cover-placeholder">
                    {{topic.initial}}
                  </span>
                {{/if}}
                <div class="dj-journal-suggested__info">
                  <span class="dj-journal-suggested__name">{{topic.title}}</span>
                  {{#if topic.tags.length}}
                    <div class="dj-journal-suggested__tags">
                      {{#each topic.tags as |tag|}}
                        <span class="dj-journal-suggested__tag">{{tag}}</span>
                      {{/each}}
                    </div>
                  {{/if}}
                </div>
              </a>
            </li>
          {{/each}}
        </ul>
      </div>
    {{/if}}
  </template>
}
