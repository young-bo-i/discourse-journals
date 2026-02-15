import { tracked } from "@glimmer/tracking";
import Controller from "@ember/controller";
import { action } from "@ember/object";
import { service } from "@ember/service";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import I18n from "discourse-i18n";

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
  @tracked importStartTime = null;
  @tracked importEta = null;
  @tracked errors = [];
  @tracked showErrors = false;
  @tracked importMessage = null;
  @tracked importSuccess = false;
  @tracked canPause = false;
  @tracked canResume = false;
  @tracked canCancel = false;
  @tracked pausing = false;
  @tracked resuming = false;
  @tracked cancelling = false;
  @tracked hasIncompleteImport = false;

  // 映射分析相关
  @tracked analyzing = false;
  @tracked analysisProgress = 0;
  @tracked analysisMessage = null;
  @tracked analysisResult = null;
  @tracked showAnalysisDetails = false;
  @tracked analysisDetailsCategory = null;
  @tracked analysisDetailsItems = [];
  @tracked analysisDetailsPage = 1;
  @tracked analysisDetailsTotalPages = 1;
  @tracked analysisDetailsTotal = 0;
  @tracked loadingDetails = false;

  // 删除相关
  @tracked deleting = false;
  @tracked deleteMessage = null;
  @tracked deleteSuccess = false;
  @tracked deleteProgress = 0;
  @tracked deleteStats = null;
  @tracked showDeleteProgress = false;
  @tracked deleteStartTime = null;
  @tracked deleteEta = null;

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

    // 检查是否有可恢复的导入任务
    this.checkResumableImport();
    // 检查映射分析状态
    this.checkMappingStatus();
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

  // 导入按钮禁用状态：正在同步、正在删除
  get importDisabled() {
    return this.syncing || this.deleting;
  }

  // 删除按钮禁用状态：正在同步、有未完成任务、正在删除
  get deleteDisabled() {
    return this.syncing || this.hasIncompleteImport || this.deleting;
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

  // 格式化剩余时间
  formatEta(seconds) {
    if (!seconds || seconds <= 0 || !isFinite(seconds)) {
      return null;
    }

    if (seconds < 60) {
      return `${Math.round(seconds)}秒`;
    } else if (seconds < 3600) {
      const minutes = Math.floor(seconds / 60);
      const secs = Math.round(seconds % 60);
      return secs > 0 ? `${minutes}分${secs}秒` : `${minutes}分钟`;
    } else {
      const hours = Math.floor(seconds / 3600);
      const minutes = Math.round((seconds % 3600) / 60);
      return minutes > 0 ? `${hours}小时${minutes}分` : `${hours}小时`;
    }
  }

  // 计算预估剩余时间
  calculateEta(startTime, processed, total) {
    if (!startTime || processed <= 0 || total <= 0) {
      return null;
    }

    const elapsed = (Date.now() - startTime) / 1000; // 已用时间（秒）
    const speed = processed / elapsed; // 每秒处理数量
    const remaining = total - processed; // 剩余数量
    const etaSeconds = remaining / speed; // 预估剩余秒数

    return this.formatEta(etaSeconds);
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
    this.importStartTime = Date.now();
    this.importEta = null;

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

      // 计算预估剩余时间
      if (data.status === "processing" && this.importStartTime) {
        this.importEta = this.calculateEta(
          this.importStartTime,
          data.processed,
          data.total
        );
      }

      // 更新暂停/恢复/取消状态
      this.canPause = data.status === "processing";
      this.canResume = data.status === "paused" || data.status === "failed";
      this.canCancel = data.status === "processing" || data.status === "paused";
      this.hasIncompleteImport =
        data.status === "processing" ||
        data.status === "paused" ||
        data.status === "pending";

      // 完成、失败、暂停或取消
      if (
        data.status === "completed" ||
        data.status === "failed" ||
        data.status === "paused" ||
        data.status === "cancelled"
      ) {
        this.syncing = false;
        this.pausing = false;
        this.cancelling = false;
        this.importEta = null;

        if (data.status === "completed") {
          this.importSuccess = true;
          this.canResume = false;
          this.canCancel = false;
          this.hasIncompleteImport = false;
          const skippedMsg =
            data.skipped > 0 ? `，跳过 ${data.skipped} 个` : "";
          this.importMessage = `✅ 同步完成！新建 ${data.created} 个，更新 ${data.updated} 个${skippedMsg}`;
          this.messageBus.unsubscribe(channel);
        } else if (data.status === "cancelled") {
          this.importSuccess = false;
          this.canResume = false;
          this.canCancel = false;
          this.hasIncompleteImport = false;
          this.importMessage = `🚫 已取消：本次导入 ${data.created} 新建，${data.updated} 更新`;
          this.messageBus.unsubscribe(channel);
        } else if (data.status === "paused") {
          this.importSuccess = false;
          this.canResume = true;
          this.canCancel = true;
          this.hasIncompleteImport = true;
          this.importMessage = `⏸️ 已暂停：已处理 ${data.processed}/${data.total}，可点击"恢复"继续`;
        } else {
          this.importSuccess = false;
          this.canResume = true;
          this.canCancel = true;
          this.hasIncompleteImport = true;
          this.importMessage = `❌ 同步失败（可尝试恢复）`;
        }

        // 获取错误日志
        if (data.errors > 0) {
          this.loadErrors(importLogId);
        }
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
  async pauseImport() {
    if (!this.currentImportId) {
      return;
    }

    this.pausing = true;

    try {
      await ajax("/admin/journals/sync/pause", {
        type: "POST",
        data: { import_log_id: this.currentImportId },
      });
      this.progressMessage = "正在暂停...";
    } catch (e) {
      this.pausing = false;
      popupAjaxError(e);
    }
  }

  @action
  async resumeImport() {
    if (!this.currentImportId) {
      return;
    }

    this.resuming = true;
    this.syncing = true;
    this.canResume = false;
    this.importMessage = null;
    this.importStartTime = Date.now();
    this.importEta = null;

    try {
      const result = await ajax("/admin/journals/sync/resume", {
        type: "POST",
        data: { import_log_id: this.currentImportId },
      });

      this.progressMessage = result.message;
      this.resuming = false;

      // 重新订阅进度
      this.subscribeToProgress(this.currentImportId);
    } catch (e) {
      this.resuming = false;
      this.syncing = false;
      this.canResume = true;
      popupAjaxError(e);
    }
  }

  @action
  async cancelImport() {
    if (!this.currentImportId) {
      return;
    }

    const confirmed = await this.dialog.yesNoConfirm({
      message:
        "确定要取消本次导入吗？\n\n取消后断点数据将被清除，下次需要重新开始。\n（已导入的期刊数据会保留）",
    });

    if (!confirmed) {
      return;
    }

    this.cancelling = true;
    this.progressMessage = "正在取消...";

    try {
      const result = await ajax("/admin/journals/sync/cancel", {
        type: "POST",
        data: { import_log_id: this.currentImportId },
      });

      // 如果返回成功且状态已是 cancelled，直接更新 UI
      if (result.success && result.status === "cancelled") {
        this.cancelling = false;
        this.syncing = false;
        this.pausing = false;
        this.canResume = false;
        this.canCancel = false;
        this.canPause = false;
        this.hasIncompleteImport = false;
        this.importEta = null;
        this.importSuccess = false;
        this.importMessage = `🚫 已取消：本次导入 ${this.importStats?.created || 0} 新建，${this.importStats?.updated || 0} 更新`;

        // 取消订阅 MessageBus
        if (this.currentImportId) {
          this.messageBus.unsubscribe(`/journals/import/${this.currentImportId}`);
        }
      }
    } catch (e) {
      this.cancelling = false;
      popupAjaxError(e);
    }
  }

  @action
  async checkResumableImport() {
    try {
      const result = await ajax("/admin/journals/sync/status", {
        type: "GET",
      });

      // 设置是否有未完成的导入任务
      this.hasIncompleteImport = result.has_incomplete || false;

      if ((result.has_resumable || result.has_active) && result.current) {
        this.currentImportId = result.current.id;
        this.showProgress = true;
        this.progress = Math.round(result.current.progress || 0);
        this.canResume = result.current.resumable;
        this.canPause = result.current.status === "processing";
        this.canCancel = result.current.cancellable;
        this.syncing = result.current.status === "processing";

        this.importStats = {
          processed: result.current.processed || 0,
          total: result.current.total || 0,
          created: result.current.created || 0,
          updated: result.current.updated || 0,
          skipped: result.current.skipped || 0,
          errors: result.current.errors || 0,
        };

        if (result.current.status === "paused") {
          this.importMessage = `⏸️ 上次导入已暂停：已处理 ${result.current.processed}/${result.current.total}，可点击"恢复"继续或"取消"重新开始`;
        } else if (result.current.status === "failed") {
          this.importMessage = `❌ 上次导入失败，可点击"恢复"重试或"取消"重新开始`;
        } else if (result.current.status === "processing") {
          this.progressMessage = "导入进行中...";
          this.subscribeToProgress(result.current.id);
        }
      }
    } catch {
      // Silently fail
    }
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
    this.deleteProgress = 0;
    this.deleteStats = null;
    this.showDeleteProgress = true;
    this.deleteStartTime = Date.now();
    this.deleteEta = null;

    try {
      const result = await ajax("/admin/journals/delete_all", {
        type: "DELETE",
      });

      this.deleteMessage = result.message;
      this.deleteStats = { total: result.total, deleted: 0, errors: 0 };

      // 订阅删除进度
      this.subscribeToDeleteProgress();
    } catch (e) {
      this.deleting = false;
      this.showDeleteProgress = false;
      this.deleteSuccess = false;
      this.deleteMessage = e.jqXHR?.responseJSON?.errors?.[0] || "删除失败";
      popupAjaxError(e);
    }
  }

  // ============ 映射分析 ============

  @action
  async startMappingAnalysis() {
    const confirmed = await this.dialog.yesNoConfirm({
      message: I18n.t("discourse_journals.admin.mapping.confirm_start"),
    });

    if (!confirmed) {
      return;
    }

    this.analyzing = true;
    this.analysisProgress = 0;
    this.analysisMessage = "正在启动分析...";
    this.analysisResult = null;
    this.showAnalysisDetails = false;

    try {
      const result = await ajax("/admin/journals/mapping/analyze", {
        type: "POST",
      });

      this.analysisMessage = result.message;
      this.subscribeToMappingProgress();
    } catch (e) {
      this.analyzing = false;
      this.analysisMessage =
        e.jqXHR?.responseJSON?.errors?.[0] ||
        I18n.t("discourse_journals.admin.mapping.start_failed");
      popupAjaxError(e);
    }
  }

  subscribeToMappingProgress() {
    const channel = "/journals/mapping";

    this.messageBus.subscribe(channel, (data) => {
      this.analysisProgress = Math.round(data.progress || 0);
      this.analysisMessage = data.message || "处理中...";

      if (data.status === "completed") {
        this.analyzing = false;
        this.analysisProgress = 100;
        this.loadMappingStatus();
        this.messageBus.unsubscribe(channel);
      } else if (data.status === "failed") {
        this.analyzing = false;
        this.analysisProgress = 0;
        this.messageBus.unsubscribe(channel);
      }
    });
  }

  @action
  async checkMappingStatus() {
    try {
      const result = await ajax("/admin/journals/mapping/status", {
        type: "GET",
      });

      if (result.has_analysis && result.analysis) {
        const a = result.analysis;
        if (a.status === "processing") {
          this.analyzing = true;
          this.analysisMessage = "映射分析进行中...";
          this.subscribeToMappingProgress();
        } else if (a.status === "completed") {
          this.analysisResult = a;
        } else if (a.status === "failed") {
          this.analysisMessage = `${I18n.t("discourse_journals.admin.mapping.analysis_failed")}: ${a.error_message || ""}`;
        }
      }
    } catch {
      // Silently fail
    }
  }

  @action
  async loadMappingStatus() {
    try {
      const result = await ajax("/admin/journals/mapping/status", {
        type: "GET",
      });

      if (result.has_analysis && result.analysis) {
        this.analysisResult = result.analysis;
      }
    } catch {
      // Silently fail
    }
  }

  @action
  async loadMappingDetails(category) {
    this.analysisDetailsCategory = category;
    this.analysisDetailsPage = 1;
    this.showAnalysisDetails = true;
    await this.fetchMappingDetails(category, 1);
  }

  @action
  async loadMappingDetailsPage(page) {
    await this.fetchMappingDetails(this.analysisDetailsCategory, page);
  }

  async fetchMappingDetails(category, page) {
    this.loadingDetails = true;
    try {
      const result = await ajax("/admin/journals/mapping/details", {
        type: "GET",
        data: { category, page, per_page: 50 },
      });

      this.analysisDetailsItems = result.items;
      this.analysisDetailsPage = result.page;
      this.analysisDetailsTotalPages = result.total_pages;
      this.analysisDetailsTotal = result.total;
    } catch (e) {
      popupAjaxError(e);
    } finally {
      this.loadingDetails = false;
    }
  }

  @action
  closeMappingDetails() {
    this.showAnalysisDetails = false;
    this.analysisDetailsCategory = null;
    this.analysisDetailsItems = [];
  }

  get analysisCategoryLabel() {
    const key = `discourse_journals.admin.mapping.${this.analysisDetailsCategory}`;
    return I18n.t(key);
  }

  get mappingBarWidths() {
    const r = this.analysisResult;
    if (!r) {
      return {};
    }
    const forumTotal = r.total_forum_topics || 1;
    const apiTotal = r.total_api_records || 1;
    return {
      exact_1to1: Math.round((r.exact_1to1 / forumTotal) * 100),
      forum_1_to_api_n: Math.round((r.forum_1_to_api_n / forumTotal) * 100),
      forum_n_to_api_1: Math.round((r.forum_n_to_api_1 / forumTotal) * 100),
      forum_n_to_api_m: Math.round((r.forum_n_to_api_m / forumTotal) * 100),
      forum_only: Math.round((r.forum_only / forumTotal) * 100),
      api_only: Math.round((r.api_only / apiTotal) * 100),
    };
  }

  get isDetailsCategoryMatched() {
    return [
      "exact_1to1",
      "forum_1_to_api_n",
      "forum_n_to_api_1",
      "forum_n_to_api_m",
    ].includes(this.analysisDetailsCategory);
  }

  get isDetailsCategoryForumOnly() {
    return this.analysisDetailsCategory === "forum_only";
  }

  get isDetailsCategoryApiOnly() {
    return this.analysisDetailsCategory === "api_only";
  }

  get prevDetailsPageDisabled() {
    return this.analysisDetailsPage <= 1;
  }

  get nextDetailsPageDisabled() {
    return this.analysisDetailsPage >= this.analysisDetailsTotalPages;
  }

  get hasMultipleDetailsPages() {
    return this.analysisDetailsTotalPages > 1;
  }

  @action
  prevDetailsPage() {
    if (this.analysisDetailsPage > 1) {
      this.loadMappingDetailsPage(this.analysisDetailsPage - 1);
    }
  }

  @action
  nextDetailsPage() {
    if (this.analysisDetailsPage < this.analysisDetailsTotalPages) {
      this.loadMappingDetailsPage(this.analysisDetailsPage + 1);
    }
  }

  subscribeToDeleteProgress() {
    const channel = "/journals/delete";

    this.messageBus.subscribe(channel, (data) => {
      this.deleteProgress = data.progress || 0;
      this.deleteMessage = data.message;

      this.deleteStats = {
        total: data.total || 0,
        deleted: data.deleted || 0,
        errors: data.errors || 0,
      };

      // 计算预估剩余时间
      if (!data.completed && this.deleteStartTime && data.deleted > 0) {
        this.deleteEta = this.calculateEta(
          this.deleteStartTime,
          data.deleted,
          data.total
        );
      }

      if (data.completed) {
        this.deleting = false;
        this.deleteSuccess = data.errors === 0;
        this.deleteEta = null;

        if (data.errors > 0) {
          this.deleteMessage = `${data.message}（${data.errors} 个删除失败）`;
        }

        this.messageBus.unsubscribe(channel);
      }
    });
  }
}
