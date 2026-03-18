import { withPluginApi } from "discourse/lib/plugin-api";

export default {
  name: "journal-seo-title",

  initialize(container) {
    const siteSettings = container.lookup("service:site-settings");

    if (!siteSettings.discourse_journals_enabled) {
      return;
    }

    withPluginApi("1.2.0", (api) => {
      // Server-side meta/title hooks handle SEO-relevant title updates.
      // Keep this initializer as a no-op to avoid client/server divergence.
      api.onPageChange(() => {});
    });
  },
};
