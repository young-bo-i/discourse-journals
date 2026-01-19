import { withPluginApi } from "discourse/lib/plugin-api";

export default {
  name: "journals-title-suffix",

  initialize(container) {
    const siteSettings = container.lookup("service:site-settings");
    
    if (!siteSettings.discourse_journals_enabled) {
      return;
    }

    withPluginApi("0.8.7", (api) => {
      // 修改话题标题
      api.modifyClass("controller:topic", {
        pluginId: "discourse-journals",

        get documentTitle() {
          const topic = this.model;
          const categoryId = siteSettings.discourse_journals_category_id;

          // 检查是否是期刊分类的话题
          if (topic && topic.category_id && categoryId) {
            const topicCategoryId = parseInt(topic.category_id, 10);
            const journalsCategoryId = parseInt(categoryId, 10);

            if (topicCategoryId === journalsCategoryId) {
              // 是期刊话题，添加后缀
              const suffix = siteSettings.discourse_journals_title_suffix;
              if (suffix) {
                // 获取原始标题
                const originalTitle = this._super(...arguments);
                // 添加后缀（如果还没有）
                if (!originalTitle.includes(suffix)) {
                  return `${originalTitle} - ${suffix}`;
                }
                return originalTitle;
              }
            }
          }

          // 不是期刊话题，使用默认标题
          return this._super(...arguments);
        },
      });
    });
  },
};
