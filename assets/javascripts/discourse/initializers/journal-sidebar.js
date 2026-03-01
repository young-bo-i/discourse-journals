import { withPluginApi } from "discourse/lib/plugin-api";

export default {
  name: "journal-sidebar",

  initialize(container) {
    const siteSettings = container.lookup("service:site-settings");
    if (!siteSettings.discourse_journals_enabled) return;

    const categoryId = parseInt(siteSettings.discourse_journals_category_id, 10);
    if (!categoryId) return;

    const meta = document.querySelector('meta[name="dj-journal-page"]');
    const isExternalToJournal = !!meta;
    if (meta) {
      meta.remove();
    }

    withPluginApi("1.2.0", (api) => {
      let weHidSidebar = false;

      if (isExternalToJournal) {
        try {
          const appController =
            api.container.lookup("controller:application");
          if (appController && appController.showSidebar) {
            appController.set("showSidebar", false);
            weHidSidebar = true;
          }
          const style = document.getElementById("dj-hide-sidebar");
          if (style) {
            style.remove();
          }
        } catch (e) {}
      }

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
            const appController =
              api.container.lookup("controller:application");
            if (appController && !appController.showSidebar) {
              appController.set("showSidebar", true);
            }
          } catch (e) {}
        }
      });
    });
  },
};
