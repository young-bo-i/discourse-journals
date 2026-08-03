import Component from "@glimmer/component";
import { service } from "@ember/service";

const BANNER_SRC = "/plugins/discourse-journals/images/banner/scholay-banner.svg";

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

  get onAdminRoute() {
    return this.router.currentRouteName?.startsWith("admin");
  }

  get url() {
    return this.siteSettings.discourse_journals_banner_url;
  }

  <template>
    {{#unless this.onAdminRoute}}
      {{#if this.url}}
        <a
          class="dj-site-banner"
          href={{this.url}}
          target="_blank"
          rel="noopener noreferrer"
        >
          <img class="dj-site-banner__img" src={{BANNER_SRC}} alt="SCHOLAY" />
        </a>
      {{else}}
        <div class="dj-site-banner">
          <img class="dj-site-banner__img" src={{BANNER_SRC}} alt="SCHOLAY" />
        </div>
      {{/if}}
    {{/unless}}
  </template>
}
