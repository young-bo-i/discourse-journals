import { withPluginApi } from "discourse/lib/plugin-api";

export default {
  name: "journal-sidebar",

  initialize(container) {
    const siteSettings = container.lookup("service:site-settings");
    if (!siteSettings.discourse_journals_enabled) {
      return;
    }

    const categoryId = parseInt(siteSettings.discourse_journals_category_id, 10);
    if (!categoryId) {
      return;
    }

    const meta = document.querySelector('meta[name="dj-journal-page"]');
    const isExternalToJournal = !!meta;
    if (meta) {
      meta.remove();
    }

    withPluginApi((api) => {
      let weHidSidebar = false;

      if (isExternalToJournal) {
        const navEntry = performance.getEntriesByType("navigation")[0];
        const isReload = navEntry && navEntry.type === "reload";

        try {
          const appController =
            api.container.lookup("controller:application");

          if (isReload) {
            if (sessionStorage.getItem("dj_external_journal")) {
              if (appController && appController.showSidebar) {
                appController.set("showSidebar", false);
              }
              weHidSidebar = true;
            }
          } else {
            if (appController && appController.showSidebar) {
              appController.set("showSidebar", false);
              weHidSidebar = true;
              sessionStorage.setItem("dj_external_journal", "1");
            }
          }

          const style = document.getElementById("dj-hide-sidebar");
          if (style) {
            style.remove();
          }
        } catch {
          // ignore
        }
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
          sessionStorage.removeItem("dj_external_journal");
          try {
            const appController =
              api.container.lookup("controller:application");
            if (appController && !appController.showSidebar) {
              appController.set("showSidebar", true);
            }
          } catch {
            // ignore
          }
        }
      });
    });
  },
};
