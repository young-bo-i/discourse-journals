import Controller from "@ember/controller";
import { action } from "@ember/object";
import { service } from "@ember/service";
import { tracked } from "@glimmer/tracking";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";

export default class AdminPluginsDiscourseJournalsController extends Controller {
  @service dialog;
  @tracked importing = false;
  @tracked importMessage = null;
  @tracked importSuccess = false;

  @action
  async startImport() {
    const input = document.getElementById("journals-import-file");
    const file = input?.files?.[0];
    
    if (!file) {
      this.dialog.alert("Please select a JSON file first");
      return;
    }

    const body = new FormData();
    body.append("file", file);

    this.importing = true;
    this.importMessage = null;

    try {
      const result = await ajax("/admin/journals/imports", {
        type: "POST",
        data: body,
        processData: false,
        contentType: false,
      });

      this.importSuccess = true;
      this.importMessage = result.message || "Import started successfully. Check server logs for progress.";
      input.value = "";
    } catch (e) {
      this.importSuccess = false;
      this.importMessage = e.jqXHR?.responseJSON?.errors?.[0] || "An error occurred during import";
      popupAjaxError(e);
    } finally {
      this.importing = false;
    }
  }
}
