import { withPluginApi } from "discourse/lib/plugin-api";

export default {
  name: "journal-sidebar",

  initialize(container) {
    const siteSettings = container.lookup("service:site-settings");
    if (!siteSettings.discourse_journals_enabled) return;

    const categoryId = parseInt(siteSettings.discourse_journals_category_id, 10);
    if (!categoryId) return;

    withPluginApi("1.2.0", (api) => {
      let weHidSidebar = false;

      try {
        if (sessionStorage.getItem("dj_sidebar_was_open")) {
          weHidSidebar = true;
        }
      } catch (e) {}

      api.onPageChange(() => {
        const topicController = api.container.lookup("controller:topic");
        const topic = topicController?.model;
        const isJournalTopic =
          topic && parseInt(topic.category_id, 10) === categoryId;

        if (isJournalTopic) {
          return;
        }

        if (weHidSidebar) {
          weHidSidebar = false;
          try {
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
        }
      });
    });
  },
};
