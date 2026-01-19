import Controller from "@ember/controller";
import { action } from "@ember/object";
import { service } from "@ember/service";
import { tracked } from "@glimmer/tracking";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";

export default class AdminPluginsDiscourseJournalsController extends Controller {
  @service dialog;
  @service messageBus;
  @tracked importing = false;
  @tracked importMessage = null;
  @tracked importSuccess = false;
  @tracked progress = 0;
  @tracked progressMessage = "";
  @tracked currentImportId = null;
  @tracked showProgress = false;
  @tracked importStats = null;
  @tracked errors = [];
  @tracked showErrors = false;

  @action
  async startImport() {
    const input = document.getElementById("journals-import-file");
    const file = input?.files?.[0];

    if (!file) {
      this.dialog.alert("请先选择一个 JSON 文件");
      return;
    }

    const body = new FormData();
    body.append("file", file);

    this.importing = true;
    this.importMessage = null;
    this.showProgress = true;
    this.progress = 0;
    this.progressMessage = "准备上传...";
    this.errors = [];
    this.showErrors = false;

    try {
      const result = await ajax("/admin/journals/imports", {
        type: "POST",
        data: body,
        processData: false,
        contentType: false,
      });

      this.currentImportId = result.import_log_id;
      this.progressMessage = "导入已开始，正在处理...";
      
      // 订阅 MessageBus 获取实时进度
      this.subscribeToProgress(result.import_log_id);
      
      input.value = "";
    } catch (e) {
      this.importing = false;
      this.showProgress = false;
      this.importSuccess = false;
      this.importMessage =
        e.jqXHR?.responseJSON?.errors?.[0] || "导入失败";
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
        errors: data.errors || 0,
      };

      // 完成或失败时停止订阅
      if (data.status === "completed" || data.status === "failed") {
        this.importing = false;
        this.importSuccess = data.status === "completed";
        
        if (data.status === "completed") {
          this.importMessage = `✅ 导入完成！新建 ${data.created} 个，更新 ${data.updated} 个`;
        } else {
          this.importMessage = `❌ 导入失败`;
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
      const result = await ajax(`/admin/journals/imports/${importLogId}/status`);
      if (result.errors && result.errors.length > 0) {
        this.errors = result.errors;
        this.showErrors = true;
      }
    } catch (e) {
      console.error("Failed to load errors:", e);
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
}
