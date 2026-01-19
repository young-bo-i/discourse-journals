import { withPluginApi } from "discourse/lib/plugin-api";

export default {
  name: "journal-seo-title",

  initialize(container) {
    const siteSettings = container.lookup("service:site-settings");

    if (!siteSettings.discourse_journals_enabled) {
      return;
    }

    const suffix = siteSettings.discourse_journals_title_suffix;
    if (!suffix) {
      return;
    }

    withPluginApi("1.2.0", (api) => {
      // 在话题页面加载时修改标题
      api.modifyClass("controller:topic", {
        pluginId: "discourse-journals",

        _modifyTitleWithSuffix() {
          const topic = this.model;
          const categoryId = parseInt(
            siteSettings.discourse_journals_category_id,
            10
          );

          if (
            topic &&
            topic.category_id === categoryId &&
            suffix &&
            !document.title.includes(suffix)
          ) {
            // 修改 document.title
            document.title = `${document.title} - ${suffix}`;

            // 也修改 og:title meta 标签（如果存在）
            const ogTitle = document.querySelector('meta[property="og:title"]');
            if (ogTitle && !ogTitle.content.includes(suffix)) {
              ogTitle.content = `${ogTitle.content} - ${suffix}`;
            }

            // 修改 twitter:title meta 标签（如果存在）
            const twitterTitle = document.querySelector(
              'meta[name="twitter:title"]'
            );
            if (twitterTitle && !twitterTitle.content.includes(suffix)) {
              twitterTitle.content = `${twitterTitle.content} - ${suffix}`;
            }
          }
        },

        onShow() {
          this._super(...arguments);
          // 延迟一点执行，确保原始标题已经设置
          setTimeout(() => {
            this._modifyTitleWithSuffix();
          }, 100);
        },
      });

      // 监听页面变化
      api.onPageChange(() => {
        const topicController = container.lookup("controller:topic");
        if (topicController && topicController.model) {
          setTimeout(() => {
            const topic = topicController.model;
            const categoryId = parseInt(
              siteSettings.discourse_journals_category_id,
              10
            );

            if (
              topic &&
              topic.category_id === categoryId &&
              suffix &&
              !document.title.includes(suffix)
            ) {
              document.title = `${document.title} - ${suffix}`;
            }
          }, 100);
        }
      });
    });

    // 立即执行一次（用于页面刷新的情况）
    setTimeout(() => {
      const topicController = container.lookup("controller:topic");
      if (topicController && topicController.model) {
        const topic = topicController.model;
        const categoryId = parseInt(
          siteSettings.discourse_journals_category_id,
          10
        );

        if (
          topic &&
          topic.category_id === categoryId &&
          suffix &&
          !document.title.includes(suffix)
        ) {
          document.title = `${document.title} - ${suffix}`;
        }
      }
    }, 200);
  },
};
