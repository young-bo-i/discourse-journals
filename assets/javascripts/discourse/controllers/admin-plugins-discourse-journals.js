import { tracked } from "@glimmer/tracking";
import Controller from "@ember/controller";
import { action } from "@ember/object";
import { service } from "@ember/service";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import { i18n } from "discourse-i18n";

export default class AdminPluginsDiscourseJournalsController extends Controller {
  @service dialog;
  @service messageBus;

  // 映射分析
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
  @tracked analysisFailed = false;
  @tracked analysisPaused = false;
  @tracked analysisPausing = false;

  // 映射应用
  @tracked applying = false;
  @tracked applyProgress = 0;
  @tracked applyMessage = null;
  @tracked applyStats = null;
  @tracked applyCompleted = false;
  @tracked applyFailed = false;
  @tracked applyPaused = false;
  @tracked applyPausing = false;

  // 删除
  @tracked deleting = false;
  @tracked deleteMessage = null;
  @tracked deleteSuccess = false;
  @tracked deleteProgress = 0;
  @tracked deleteStats = null;
  @tracked showDeleteProgress = false;
  @tracked deleteStartTime = null;
  @tracked deleteEta = null;

  // 跳转入口统计
  @tracked promoStats = null;
  @tracked promoRange = 30;
  @tracked promoSlide = "total";
  @tracked loadingPromoStats = false;

  // 账号池
  @tracked personaCount = 0;
  @tracked personaFile = null;
  @tracked personaImporting = false;
  @tracked personaProgress = 0;
  @tracked personaStats = null;
  @tracked personaMessage = null;
  @tracked personaFailed = false;

  constructor() {
    super(...arguments);
    this.checkMappingStatus();
    this.loadPromoStats();
    this.loadPersonaStatus();
  }

  // ============ 账号池 ============

  get personaUploadDisabled() {
    return !this.personaFile || this.personaImporting;
  }

  @action
  async downloadTemplate() {
    // Fetch + blob download so the SPA router never intercepts the click and no
    // extra tab opens; the static file is served at /plugins/discourse-journals/.
    try {
      const response = await fetch(
        "/plugins/discourse-journals/personas-template.csv"
      );
      const blob = await response.blob();
      const url = URL.createObjectURL(blob);
      const link = document.createElement("a");
      link.href = url;
      link.download = "personas-template.csv";
      link.click();
      URL.revokeObjectURL(url);
    } catch {
      // ignore — link is best-effort
    }
  }

  @action
  setPersonaFile(event) {
    this.personaFile = event.target.files?.[0] || null;
  }

  @action
  async uploadPersonas() {
    if (!this.personaFile) {
      return;
    }
    const formData = new FormData();
    formData.append("file", this.personaFile);

    this.personaImporting = true;
    this.personaFailed = false;
    this.personaProgress = 0;
    this.personaStats = null;
    this.personaMessage = null;

    try {
      const result = await ajax("/admin/journals/personas/import", {
        type: "POST",
        data: formData,
        processData: false,
        contentType: false,
      });
      this.personaMessage = result.message;
      this.personaFile = null; // avoid re-uploading the same file from an empty picker
      this.subscribeToPersonaProgress();
    } catch (e) {
      this.personaImporting = false;
      popupAjaxError(e);
    }
  }

  subscribeToPersonaProgress() {
    const channel = "/journals/persona-import";
    this.messageBus.subscribe(channel, (data) => {
      this.personaProgress = Math.round(data.progress || 0);
      this.personaStats = data.stats;
      if (data.status === "completed") {
        this.personaImporting = false;
        this.personaProgress = 100;
        this.personaMessage = i18n(
          "discourse_journals.admin.personas.completed"
        );
        this.loadPersonaStatus();
        this.messageBus.unsubscribe(channel);
      } else if (data.status === "failed") {
        this.personaImporting = false;
        this.personaFailed = true;
        this.personaMessage = i18n("discourse_journals.admin.personas.failed");
        this.messageBus.unsubscribe(channel);
      }
    });
  }

  async loadPersonaStatus() {
    try {
      const result = await ajax("/admin/journals/personas/status", {
        type: "GET",
      });
      this.personaCount = result.persona_count || 0;
      const imp = result.import;
      if (imp && (imp.status === "processing" || imp.status === "pending")) {
        this.personaImporting = true;
        this.personaStats = {
          created: imp.created,
          skipped: imp.skipped,
          errors: imp.errors,
        };
        this.subscribeToPersonaProgress();
      }
    } catch {
      // Silently fail on initial load
    }
  }

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

  calculateEta(startTime, processed, total) {
    if (!startTime || processed <= 0 || total <= 0) {
      return null;
    }
    const elapsed = (Date.now() - startTime) / 1000;
    const speed = processed / elapsed;
    const remaining = total - processed;
    const etaSeconds = remaining / speed;
    return this.formatEta(etaSeconds);
  }

  // ============ Computed: Apply Task States ============

  get canStartApply() {
    return (
      this.analysisResult &&
      this.analysisResult.status === "completed" &&
      this.analysisResult.apply_status === "not_applied" &&
      !this.applying &&
      !this.applyCompleted &&
      !this.applyFailed &&
      !this.applyPaused
    );
  }

  get canResumeApply() {
    return !this.applying && (this.applyPaused || this.applyFailed);
  }

  // ============ 映射分析 ============

  @action
  async startMappingAnalysis() {
    const confirmed = await this.dialog.yesNoConfirm({
      message: i18n("discourse_journals.admin.mapping.confirm_start"),
    });
    if (!confirmed) {
      return;
    }

    this.analyzing = true;
    this.analysisProgress = 0;
    this.analysisMessage = i18n(
      "discourse_journals.admin.mapping.starting_analysis"
    );
    this.analysisResult = null;
    this.analysisFailed = false;
    this.analysisPaused = false;
    this.analysisPausing = false;
    this.showAnalysisDetails = false;
    this._resetApplyUI();

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
        i18n("discourse_journals.admin.mapping.start_failed");
      popupAjaxError(e);
    }
  }

  @action
  async pauseMappingAnalysis() {
    this.analysisPausing = true;
    this.analysisMessage = i18n("discourse_journals.admin.mapping.pausing");

    try {
      await ajax("/admin/journals/mapping/pause", { type: "POST" });
    } catch (e) {
      this.analysisPausing = false;
      popupAjaxError(e);
    }
  }

  @action
  async restartMappingAnalysis() {
    const confirmed = await this.dialog.yesNoConfirm({
      message: i18n("discourse_journals.admin.mapping.confirm_restart"),
    });
    if (!confirmed) {
      return;
    }

    this.analyzing = true;
    this.analysisProgress = 0;
    this.analysisMessage = i18n(
      "discourse_journals.admin.mapping.restarting_analysis"
    );
    this.analysisResult = null;
    this.analysisFailed = false;
    this.analysisPaused = false;
    this.analysisPausing = false;
    this.showAnalysisDetails = false;
    this._resetApplyUI();

    try {
      const result = await ajax("/admin/journals/mapping/restart", {
        type: "POST",
      });
      this.analysisMessage = result.message;
      this.subscribeToMappingProgress();
    } catch (e) {
      this.analyzing = false;
      this.analysisMessage =
        e.jqXHR?.responseJSON?.errors?.[0] ||
        i18n("discourse_journals.admin.mapping.start_failed");
      popupAjaxError(e);
    }
  }

  subscribeToMappingProgress() {
    const channel = "/journals/mapping";
    this.messageBus.subscribe(channel, (data) => {
      this.analysisProgress = Math.round(data.progress || 0);
      this.analysisMessage =
        data.message || i18n("discourse_journals.admin.mapping.processing");

      if (data.status === "completed") {
        this.analyzing = false;
        this.analysisPausing = false;
        this.analysisProgress = 100;
        this.analysisMessage = null;
        this.loadMappingStatus();
        this.messageBus.unsubscribe(channel);
      } else if (data.status === "failed") {
        this.analyzing = false;
        this.analysisPausing = false;
        this.analysisFailed = true;
        this.messageBus.unsubscribe(channel);
      } else if (data.status === "paused") {
        this.analyzing = false;
        this.analysisPausing = false;
        this.analysisPaused = true;
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
          this.analysisMessage = i18n(
            "discourse_journals.admin.mapping.processing"
          );
          this.subscribeToMappingProgress();
        } else if (a.status === "completed") {
          this.analysisResult = a;
          this.restoreApplyState(a);
        } else if (a.status === "paused") {
          this.analysisPaused = true;
          this.analysisMessage = i18n(
            "discourse_journals.admin.mapping.analysis_paused_msg"
          );
          this.analysisProgress = a.progress || 0;
        } else if (a.status === "failed") {
          this.analysisFailed = true;
          this.analysisMessage = `${i18n("discourse_journals.admin.mapping.analysis_failed")}: ${a.error_message || ""}`;
          this.analysisProgress = a.progress || 0;
        }
      }
    } catch {
      // Silently fail on initial load
    }
  }

  restoreApplyState(analysis) {
    const as = analysis.apply_status;
    if (as === "sync_processing") {
      this.applying = true;
      this.applyMessage = i18n(
        "discourse_journals.admin.mapping.apply_in_progress"
      );
      this.applyStats = analysis.apply_stats || {};
      this.subscribeToApplyProgress();
    } else if (as === "sync_completed") {
      this.applyCompleted = true;
      this.applyStats = analysis.apply_stats || {};
    } else if (as === "sync_failed") {
      this.applyFailed = true;
      this.applyMessage = `${i18n("discourse_journals.admin.mapping.apply_failed")}: ${analysis.apply_error_message || ""}`;
      this.applyStats = analysis.apply_stats || {};
    } else if (as === "sync_paused") {
      this.applyPaused = true;
      this.applyMessage = i18n(
        "discourse_journals.admin.mapping.apply_paused_msg"
      );
      this.applyStats = analysis.apply_stats || {};
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
    return i18n(key);
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

  // ============ 映射应用 ============

  @action
  async startApplyMapping() {
    const confirmed = await this.dialog.yesNoConfirm({
      message: i18n("discourse_journals.admin.mapping.apply_confirm"),
    });
    if (!confirmed) {
      return;
    }

    this._startApplyUI(i18n("discourse_journals.admin.mapping.apply_starting"));

    try {
      const result = await ajax("/admin/journals/mapping/apply", {
        type: "POST",
      });
      this.applyMessage = result.message;
      this.subscribeToApplyProgress();
    } catch (e) {
      this.applying = false;
      this.applyMessage =
        e.jqXHR?.responseJSON?.errors?.[0] ||
        i18n("discourse_journals.admin.mapping.apply_start_failed");
      popupAjaxError(e);
    }
  }

  @action
  async resumeApplyMapping() {
    const confirmed = await this.dialog.yesNoConfirm({
      message: i18n("discourse_journals.admin.mapping.apply_resume_confirm"),
    });
    if (!confirmed) {
      return;
    }

    this.applying = true;
    this.applyPaused = false;
    this.applyFailed = false;
    this.applyMessage = i18n("discourse_journals.admin.mapping.apply_resuming");

    try {
      const result = await ajax("/admin/journals/mapping/apply_resume", {
        type: "POST",
      });
      this.applyMessage = result.message;
      this.subscribeToApplyProgress();
    } catch (e) {
      this.applying = false;
      this.applyPaused = true;
      this.applyMessage =
        e.jqXHR?.responseJSON?.errors?.[0] ||
        i18n("discourse_journals.admin.mapping.apply_start_failed");
      popupAjaxError(e);
    }
  }

  @action
  async pauseApplyMapping() {
    this.applyPausing = true;

    try {
      await ajax("/admin/journals/mapping/apply_pause", { type: "POST" });
    } catch (e) {
      this.applyPausing = false;
      popupAjaxError(e);
    }
  }

  subscribeToApplyProgress() {
    const channel = "/journals/mapping-apply";
    this.messageBus.subscribe(channel, (data) => {
      this.applyProgress = Math.round(data.progress || 0);
      this.applyMessage =
        data.message || i18n("discourse_journals.admin.mapping.processing");

      if (data.stats) {
        this.applyStats = data.stats;
      }

      if (data.status === "completed") {
        this.applying = false;
        this.applyPausing = false;
        this.applyCompleted = true;
        this.applyProgress = 100;
        this.messageBus.unsubscribe(channel);
      } else if (data.status === "failed") {
        this.applying = false;
        this.applyPausing = false;
        this.applyFailed = true;
        this.messageBus.unsubscribe(channel);
      } else if (data.status === "paused") {
        this.applying = false;
        this.applyPausing = false;
        this.applyPaused = true;
        this.messageBus.unsubscribe(channel);
      }
    });
  }

  _startApplyUI(message) {
    this.applying = true;
    this.applyProgress = 0;
    this.applyMessage = message;
    this.applyStats = null;
    this.applyCompleted = false;
    this.applyFailed = false;
    this.applyPaused = false;
    this.applyPausing = false;
  }

  _resetApplyUI() {
    this.applying = false;
    this.applyProgress = 0;
    this.applyMessage = null;
    this.applyStats = null;
    this.applyCompleted = false;
    this.applyFailed = false;
    this.applyPaused = false;
    this.applyPausing = false;
  }

  // ============ 删除所有期刊 ============

  get deleteDisabled() {
    return this.deleting;
  }

  @action
  async deleteAllJournals() {
    const confirmed = await this.dialog.yesNoConfirm({
      message: i18n("discourse_journals.admin.danger.delete_confirm"),
    });
    if (!confirmed) {
      return;
    }

    const doubleConfirmed = await this.dialog.yesNoConfirm({
      message: i18n("discourse_journals.admin.danger.delete_confirm_final"),
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
      this.subscribeToDeleteProgress();
    } catch (e) {
      this.deleting = false;
      this.showDeleteProgress = false;
      this.deleteSuccess = false;
      this.deleteMessage =
        e.jqXHR?.responseJSON?.errors?.[0] ||
        i18n("discourse_journals.admin.danger.delete_failed");
      popupAjaxError(e);
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
          this.deleteMessage = `${data.message}（${data.errors} ${i18n("discourse_journals.admin.danger.delete_errors_suffix")}）`;
        }

        this.messageBus.unsubscribe(channel);
      }
    });
  }

  // ============ 跳转入口统计 ============

  async loadPromoStats() {
    this.loadingPromoStats = true;
    try {
      this.promoStats = await ajax("/admin/journals/promo_stats", {
        data: { days: this.promoRange },
      });
    } catch {
      this.promoStats = null;
    } finally {
      this.loadingPromoStats = false;
    }
  }

  @action
  setPromoRange(days) {
    if (this.promoRange === days) {
      return;
    }
    this.promoRange = days;
    this.loadPromoStats();
  }

  @action
  setPromoSlide(slide) {
    this.promoSlide = slide;
  }

  get promoRangeOptions() {
    return [
      { days: 7, label: i18n("discourse_journals.admin.stats.range_7") },
      { days: 30, label: i18n("discourse_journals.admin.stats.range_30") },
      { days: 90, label: i18n("discourse_journals.admin.stats.range_90") },
    ];
  }

  get promoSlideTabs() {
    return [
      { key: "total", label: i18n("discourse_journals.admin.stats.total") },
      {
        key: "peer_review",
        label: i18n("discourse_journals.promo.titles.peer_review"),
      },
      { key: "prism", label: i18n("discourse_journals.promo.titles.prism") },
      { key: "claw", label: i18n("discourse_journals.promo.titles.claw") },
    ];
  }

  get promoSummaryCards() {
    const totals = this.promoStats?.totals;
    if (!totals) {
      return [];
    }
    return this.promoSlideTabs.map((tab) => {
      const t = totals[tab.key] || { impressions: 0, clicks: 0, ctr: 0 };
      return {
        key: tab.key,
        label: tab.label,
        impressions: t.impressions,
        clicks: t.clicks,
        ctr: t.ctr,
      };
    });
  }

  get hasPromoData() {
    const total = this.promoStats?.totals?.total;
    return !!total && (total.impressions > 0 || total.clicks > 0);
  }

  get promoChartConfig() {
    const stats = this.promoStats;
    if (!stats) {
      return null;
    }
    const series = stats.series[this.promoSlide] || stats.series.total;

    return {
      type: "line",
      data: {
        labels: stats.days,
        datasets: [
          {
            label: i18n("discourse_journals.admin.stats.impressions"),
            data: series.impressions,
            yAxisID: "y",
            borderColor: "#4a90d9",
            backgroundColor: "rgba(74, 144, 217, 0.12)",
            tension: 0.3,
            fill: true,
          },
          {
            label: i18n("discourse_journals.admin.stats.clicks"),
            data: series.clicks,
            yAxisID: "y",
            borderColor: "#3cc99b",
            backgroundColor: "rgba(60, 201, 155, 0.12)",
            tension: 0.3,
            fill: true,
          },
          {
            label: i18n("discourse_journals.admin.stats.ctr"),
            data: series.ctr,
            yAxisID: "y1",
            borderColor: "#f2683a",
            borderDash: [5, 4],
            tension: 0.3,
            fill: false,
          },
        ],
      },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        interaction: { mode: "index", intersect: false },
        plugins: { legend: { position: "bottom" } },
        scales: {
          y: {
            beginAtZero: true,
            position: "left",
            title: {
              display: true,
              text: i18n("discourse_journals.admin.stats.axis_count"),
            },
          },
          y1: {
            beginAtZero: true,
            position: "right",
            grid: { drawOnChartArea: false },
            title: { display: true, text: "CTR %" },
            ticks: { callback: (value) => `${value}%` },
          },
        },
      },
    };
  }
}
