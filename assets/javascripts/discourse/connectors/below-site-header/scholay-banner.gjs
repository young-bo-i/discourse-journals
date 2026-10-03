import Component from "@glimmer/component";
import { action } from "@ember/object";
import { on } from "@ember/modifier";
import didInsert from "@ember/render-modifiers/modifiers/did-insert";
import { service } from "@ember/service";

const BASE = "/plugins/discourse-journals/images/banner";
const TRACK_URL = "/journals/promo/track";

export default class ScholayBanner extends Component {
  static shouldRender(outletArgs, helper) {
    const siteSettings = helper.siteSettings;
    return (
      siteSettings.discourse_journals_enabled &&
      siteSettings.discourse_journals_banner_enabled
    );
  }

  @service siteSettings;
  @service router;

  _impressionTracked = false;

  get onAdminRoute() {
    return this.router.currentRouteName?.startsWith("admin");
  }

  get url() {
    const value = this.siteSettings.discourse_journals_banner_url;
    // undefined => glimmer omits the href, so a blank setting renders a
    // non-clickable banner instead of a link to the current page.
    return value && value.trim() ? value : undefined;
  }

  _track(event) {
    // The endpoint skips CSRF, but Discourse's ajax() would still fetch a CSRF
    // token first — two requests per impression. A beacon is one, and it
    // survives the navigation a banner click starts. Best-effort: never throw.
    const body = new URLSearchParams({ event, slide: "banner" });
    try {
      if (navigator.sendBeacon?.(TRACK_URL, body)) {
        return;
      }
    } catch {
      // fall through to fetch
    }
    fetch(TRACK_URL, { method: "POST", body, keepalive: true }).catch(() => {});
  }

  @action
  trackImpression() {
    // Once per hard page load (the connector persists across SPA navigation).
    if (this._impressionTracked || this.onAdminRoute) {
      return;
    }
    this._impressionTracked = true;
    this._track("impression");
  }

  @action
  trackClick() {
    if (this.url) {
      this._track("click");
    }
  }

  <template>
    {{#unless this.onAdminRoute}}
      {{! .wrap follows the site's content width; the banner itself has a
          smaller maximum width so it stays visually subordinate to the page }}
      <div class="wrap dj-site-banner-wrap">
        <a
          class="dj-site-banner"
          href={{this.url}}
          target="_blank"
          rel="noopener noreferrer"
          {{didInsert this.trackImpression}}
          {{on "click" this.trackClick}}
        >
          <img
            class="dj-site-banner__img"
            src="{{BASE}}/scholay-banner-1940.webp"
            srcset="{{BASE}}/scholay-banner-1200.webp 1200w, {{BASE}}/scholay-banner-1940.webp 1940w, {{BASE}}/scholay-banner-3234.webp 3234w"
            sizes="(max-width: 56rem) 100vw, 56rem"
            width="1940"
            height="180"
            alt="SCHOLAY"
          />
        </a>
      </div>
    {{/unless}}
  </template>
}
