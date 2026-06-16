import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { fn } from "@ember/helper";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import didInsert from "@ember/render-modifiers/modifiers/did-insert";
import willDestroy from "@ember/render-modifiers/modifiers/will-destroy";
import concatClass from "discourse/helpers/concat-class";
import { eq, gt } from "discourse/truth-helpers";
import { i18n } from "discourse-i18n";

const IMAGE_BASE = "/plugins/discourse-journals/images/promo";
const ROTATE_INTERVAL = 5000;

// External entry points to scholay.com. Product names are brand names (kept
// literal); the surrounding UI strings are translatable.
const SLIDES = [
  {
    name: "Claw Agent",
    image: `${IMAGE_BASE}/claw-agent-flow.gif`,
    url: "https://www.scholay.com/claw",
  },
  {
    name: "Prism Writing",
    image: `${IMAGE_BASE}/prism-writing-flow.gif`,
    url: "https://www.scholay.com/prism",
  },
  {
    name: "Peer Review",
    image: `${IMAGE_BASE}/peer-review-flow.gif`,
    url: "https://www.scholay.com/peer-review",
  },
];

export default class JournalPromo extends Component {
  @tracked index = 0;

  _timer = null;

  get slides() {
    return SLIDES;
  }

  @action
  setup() {
    this._start();
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
    this.index = index;
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
      this.index = (this.index + 1) % this.slides.length;
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
      <div class="dj-journal-promo__title">{{i18n
          "discourse_journals.promo.title"
        }}</div>

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
                name=slide.name
              }}
            >
              <img
                class="dj-journal-promo__img"
                src={{slide.image}}
                alt={{slide.name}}
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
                name=slide.name
              }}
              {{on "click" (fn this.goTo i)}}
            ></button>
          {{/each}}
        </div>
      {{/if}}
    </div>
  </template>
}
