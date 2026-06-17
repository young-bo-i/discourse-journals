import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { fn } from "@ember/helper";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import didInsert from "@ember/render-modifiers/modifiers/did-insert";
import willDestroy from "@ember/render-modifiers/modifiers/will-destroy";
import concatClass from "discourse/helpers/concat-class";
import { ajax } from "discourse/lib/ajax";
import { eq, gt } from "discourse/truth-helpers";
import { i18n } from "discourse-i18n";

const IMAGE_BASE = "/plugins/discourse-journals/images/promo";
const ROTATE_INTERVAL = 5000;
const TRACK_URL = "/journals/promo/track";

// External entry points to scholay.com. Each slide shows its own (translatable)
// title above the animation and links to the matching product page. `key`
// identifies the slide for impression/click analytics (see PromoStat).
const SLIDES = [
  {
    key: "peer_review",
    titleKey: "discourse_journals.promo.titles.peer_review",
    image: `${IMAGE_BASE}/peer-review-flow.webp`,
    url: "https://www.scholay.com/peer-review",
  },
  {
    key: "prism",
    titleKey: "discourse_journals.promo.titles.prism",
    image: `${IMAGE_BASE}/prism-writing-flow.webp`,
    url: "https://www.scholay.com/prism",
  },
  {
    key: "claw",
    titleKey: "discourse_journals.promo.titles.claw",
    image: `${IMAGE_BASE}/claw-agent-flow.webp`,
    url: "https://www.scholay.com/claw",
  },
];

export default class JournalPromo extends Component {
  @tracked index = 0;

  _timer = null;
  // slide keys already counted as an impression this page view (dedup)
  _seenImpressions = new Set();

  get slides() {
    return SLIDES;
  }

  get current() {
    return this.slides[this.index];
  }

  @action
  setup() {
    this._start();
    this._trackImpression();
  }

  @action
  cleanup() {
    this._stop();
  }

  @action
  pause() {
    this._stop();
  }

  @action
  resume() {
    this._start();
  }

  @action
  goTo(index) {
    // Clicking a dot happens while hovering (auto-rotation already paused);
    // just switch the slide and let mouseleave resume rotation.
    this._setIndex(index);
  }

  @action
  trackClick(slide) {
    this._track("click", slide.key);
  }

  _setIndex(index) {
    this.index = index;
    this._trackImpression();
  }

  _trackImpression() {
    const slide = this.current;
    if (!slide || this._seenImpressions.has(slide.key)) {
      return;
    }
    this._seenImpressions.add(slide.key);
    this._track("impression", slide.key);
  }

  _track(event, slide) {
    // Analytics is best-effort: never surface errors to the visitor.
    ajax(TRACK_URL, { type: "POST", data: { event, slide } }).catch(() => {});
  }

  _start() {
    this._stop();

    if (this.slides.length <= 1) {
      return;
    }

    const reducedMotion = window.matchMedia(
      "(prefers-reduced-motion: reduce)"
    ).matches;
    if (reducedMotion) {
      return;
    }

    this._timer = setInterval(() => {
      this._setIndex((this.index + 1) % this.slides.length);
    }, ROTATE_INTERVAL);
  }

  _stop() {
    if (this._timer) {
      clearInterval(this._timer);
      this._timer = null;
    }
  }

  <template>
    <div
      class="dj-journal-promo"
      {{didInsert this.setup}}
      {{willDestroy this.cleanup}}
      {{on "mouseenter" this.pause}}
      {{on "mouseleave" this.resume}}
    >
      <div class="dj-journal-promo__title">{{i18n this.current.titleKey}}</div>

      <div class="dj-journal-promo__viewport">
        {{#each this.slides as |slide i|}}
          {{#if (eq i this.index)}}
            <a
              class="dj-journal-promo__slide"
              href={{slide.url}}
              target="_blank"
              rel="noopener noreferrer"
              aria-label={{i18n
                "discourse_journals.promo.visit"
                name=(i18n slide.titleKey)
              }}
              {{on "click" (fn this.trackClick slide)}}
            >
              <img
                class="dj-journal-promo__img"
                src={{slide.image}}
                alt={{i18n slide.titleKey}}
              />
            </a>
          {{/if}}
        {{/each}}
      </div>

      {{#if (gt this.slides.length 1)}}
        <div class="dj-journal-promo__dots">
          {{#each this.slides as |slide i|}}
            <button
              type="button"
              class={{concatClass
                "dj-journal-promo__dot"
                (if (eq i this.index) "dj-journal-promo__dot--active")
              }}
              aria-label={{i18n
                "discourse_journals.promo.go_to"
                name=(i18n slide.titleKey)
              }}
              {{on "click" (fn this.goTo i)}}
            ></button>
          {{/each}}
        </div>
      {{/if}}
    </div>
  </template>
}
