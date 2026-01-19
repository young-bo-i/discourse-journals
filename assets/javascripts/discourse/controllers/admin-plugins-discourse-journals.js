import { tracked } from "@glimmer/tracking";
import Controller from "@ember/controller";
import { action } from "@ember/object";
import { service } from "@ember/service";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";

export default class AdminPluginsDiscourseJournalsController extends Controller {
  @service dialog;
  @service messageBus;
  @service siteSettings;

  @tracked apiUrl = "";
  @tracked testing = false;
  @tracked testMessage = null;
  @tracked testSuccess = false;
  @tracked syncing = false;
  @tracked progress = 0;
  @tracked progressMessage = "";
  @tracked currentImportId = null;
  @tracked showProgress = false;
  @tracked importStats = null;
  @tracked errors = [];
  @tracked showErrors = false;
  @tracked importMessage = null;
  @tracked importSuccess = false;

  // 删除相关
  @tracked deleting = false;
  @tracked deleteMessage = null;
  @tracked deleteSuccess = false;

  // 筛选条件
  @tracked showFilters = false;
  @tracked filterQ = "";
  @tracked filterInDoaj = "";
  @tracked filterInNlm = "";
  @tracked filterHasWikidata = "";
  @tracked filterIsOpenAccess = "";

  constructor() {
    super(...arguments);
    this.apiUrl = this.siteSettings.discourse_journals_api_url || "";
  }

  get hasActiveFilters() {
    return !!(
      this.filterQ ||
      this.filterInDoaj ||
      this.filterInNlm ||
      this.filterHasWikidata ||
      this.filterIsOpenAccess
    );
  }

  get activeFiltersCount() {
    let count = 0;
    if (this.filterQ) {
      count++;
    }
    if (this.filterInDoaj) {
      count++;
    }
    if (this.filterInNlm) {
      count++;
    }
    if (this.filterHasWikidata) {
      count++;
    }
    if (this.filterIsOpenAccess) {
      count++;
    }
    return count;
  }

  get filtersData() {
    const filters = {};
    if (this.filterQ) {
      filters.q = this.filterQ;
    }
    if (this.filterInDoaj) {
      filters.in_doaj = this.filterInDoaj === "true";
    }
    if (this.filterInNlm) {
      filters.in_nlm = this.filterInNlm === "true";
    }
    if (this.filterHasWikidata) {
      filters.has_wikidata = this.filterHasWikidata === "true";
    }
    if (this.filterIsOpenAccess) {
      filters.is_open_access = this.filterIsOpenAccess === "true";
    }
    return filters;
  }

  @action
  updateApiUrl(event) {
    this.apiUrl = event.target.value;
  }

  @action
  toggleFilters() {
    this.showFilters = !this.showFilters;
  }

  @action
  updateFilterQ(event) {
    this.filterQ = event.target.value;
  }

  @action
  updateFilterInDoaj(event) {
    this.filterInDoaj = event.target.value;
  }

  @action
  updateFilterInNlm(event) {
    this.filterInNlm = event.target.value;
  }

  @action
  updateFilterHasWikidata(event) {
    this.filterHasWikidata = event.target.value;
  }

  @action
  updateFilterIsOpenAccess(event) {
    this.filterIsOpenAccess = event.target.value;
  }

  @action
  clearFilters() {
    this.filterQ = "";
    this.filterInDoaj = "";
    this.filterInNlm = "";
    this.filterHasWikidata = "";
    this.filterIsOpenAccess = "";
  }

  @action
  async testConnection() {
    if (!this.apiUrl) {
      this.dialog.alert("请输入 API URL");
      return;
    }

    this.testing = true;
    this.testMessage = null;

    try {
      const result = await ajax("/admin/journals/sync/test", {
        type: "POST",
        data: { api_url: this.apiUrl },
      });

      this.testSuccess = true;
      this.testMessage = result.message;
    } catch (e) {
      this.testSuccess = false;
      this.testMessage = e.jqXHR?.responseJSON?.errors?.[0] || "连接测试失败";
      popupAjaxError(e);
    } finally {
      this.testing = false;
    }
  }

  @action
  async syncFirstPage() {
    if (!this.apiUrl) {
      this.dialog.alert("请输入 API URL");
      return;
    }

    const confirmed = await this.dialog.yesNoConfirm({
      message: "确定要导入第一页数据吗？（约100个期刊）",
    });

    if (!confirmed) {
      return;
    }

    this.startSync("first_page");
  }

  @action
  async syncAllPages() {
    if (!this.apiUrl) {
      this.dialog.alert("请输入 API URL");
      return;
    }

    const confirmed = await this.dialog.yesNoConfirm({
      message:
        "确定要导入所有数据吗？\n\n这可能需要较长时间（15万期刊约50分钟）。\n\n导入过程会在后台运行，您可以安全关闭此页面。",
    });

    if (!confirmed) {
      return;
    }

    this.startSync("all_pages");
  }

  async startSync(mode) {
    this.syncing = true;
    this.showProgress = true;
    this.progress = 0;
    this.progressMessage = "准备开始...";
    this.errors = [];
    this.showErrors = false;
    this.importMessage = null;

    try {
      const data = {
        api_url: this.apiUrl,
        mode,
      };

      // 添加筛选条件
      if (this.hasActiveFilters) {
        data.filters = this.filtersData;
      }

      const result = await ajax("/admin/journals/sync", {
        type: "POST",
        data,
      });

      this.currentImportId = result.import_log_id;
      this.progressMessage = result.message;

      // 订阅 MessageBus
      this.subscribeToProgress(result.import_log_id);
    } catch (e) {
      this.syncing = false;
      this.showProgress = false;
      this.importSuccess = false;
      this.importMessage = e.jqXHR?.responseJSON?.errors?.[0] || "启动同步失败";
      popupAjaxError(e);
    }
  }

  subscribeToProgress(importLogId) {
    const channel = `/journals/import/${importLogId}`;

    this.messageBus.subscribe(channel, (data) => {
      this.progress = Math.round(data.progress || 0);
      this.progressMessage = data.message || "处理中...";

      this.importStats = {
        processed: data.processed || 0,
        total: data.total || 0,
        created: data.created || 0,
        updated: data.updated || 0,
        skipped: data.skipped || 0,
        errors: data.errors || 0,
      };

      // 完成或失败
      if (data.status === "completed" || data.status === "failed") {
        this.syncing = false;
        this.importSuccess = data.status === "completed";

        if (data.status === "completed") {
          const skippedMsg =
            data.skipped > 0 ? `，跳过 ${data.skipped} 个` : "";
          this.importMessage = `✅ 同步完成！新建 ${data.created} 个，更新 ${data.updated} 个${skippedMsg}`;
        } else {
          this.importMessage = `❌ 同步失败`;
        }

        // 获取错误日志
        if (data.errors > 0) {
          this.loadErrors(importLogId);
        }

        this.messageBus.unsubscribe(channel);
      }
    });
  }

  async loadErrors(importLogId) {
    try {
      const result = await ajax(
        `/admin/journals/imports/${importLogId}/status`
      );
      if (result.errors && result.errors.length > 0) {
        this.errors = result.errors;
        this.showErrors = true;
      }
    } catch {
      // Silently fail - errors will be shown in the UI
    }
  }

  @action
  toggleErrors() {
    this.showErrors = !this.showErrors;
  }

  @action
  copyErrors() {
    const errorText = this.errors
      .map((e, i) => `${i + 1}. ${e.message}\n   ${e.details || ""}`)
      .join("\n\n");

    navigator.clipboard.writeText(errorText).then(() => {
      this.dialog.alert("错误日志已复制到剪贴板");
    });
  }

  @action
  async deleteAllJournals() {
    const confirmed = await this.dialog.yesNoConfirm({
      message:
        "⚠️ 确定要删除所有期刊帖子吗？\n\n此操作不可撤销！所有导入的期刊帖子将被永久删除。",
    });

    if (!confirmed) {
      return;
    }

    // 二次确认
    const doubleConfirmed = await this.dialog.yesNoConfirm({
      message:
        "🚨 最后确认：真的要永久删除所有期刊帖子吗？\n\n这将删除所有通过此插件导入的期刊数据，且无法恢复！",
    });

    if (!doubleConfirmed) {
      return;
    }

    this.deleting = true;
    this.deleteMessage = null;

    try {
      const result = await ajax("/admin/journals/delete_all", {
        type: "DELETE",
      });

      this.deleteSuccess = true;
      this.deleteMessage = result.message;

      if (result.errors && result.errors.length > 0) {
        this.deleteMessage += `\n\n部分错误：\n${result.errors.join("\n")}`;
      }
    } catch (e) {
      this.deleteSuccess = false;
      this.deleteMessage = e.jqXHR?.responseJSON?.errors?.[0] || "删除失败";
      popupAjaxError(e);
    } finally {
      this.deleting = false;
    }
  }
}
