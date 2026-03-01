import { withPluginApi } from "discourse/lib/plugin-api";

export default {
  name: "journal-sidebar",

  initialize(container) {
    try {
      if (!sessionStorage.getItem("dj_sidebar_was_open")) return;
    } catch (e) {
      return;
    }

    const siteSettings = container.lookup("service:site-settings");
    if (!siteSettings.discourse_journals_enabled) return;

    withPluginApi("1.2.0", (api) => {
      let isFirstPage = true;

      api.onPageChange(() => {
        if (isFirstPage) {
          isFirstPage = false;
          return;
        }

        try {
          if (!sessionStorage.getItem("dj_sidebar_was_open")) return;
          sessionStorage.removeItem("dj_sidebar_was_open");

          if (localStorage.getItem("discourse_sidebar-hidden")) {
            localStorage.removeItem("discourse_sidebar-hidden");
            const appController =
              api.container.lookup("controller:application");
            if (appController && !appController.showSidebar) {
              appController.set("showSidebar", true);
            }
          }
        } catch (e) {}
      });
    });
  },
};
