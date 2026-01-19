import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import { service } from "@ember/service";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import { i18n } from "discourse-i18n";

export default class JournalsAdminImport extends Component {
  @service toasts;
  @tracked importing = false;

  @action
  async startImport(event) {
    event?.preventDefault();

    const input = document.getElementById("journals-import-file");
    const file = input?.files?.[0];
    if (!file) {
      this.toasts.error({
        data: { message: i18n("discourse_journals.admin.imports.no_file") },
      });
      return;
    }

    const body = new FormData();
    body.append("file", file);

    this.importing = true;
    try {
      const result = await ajax("/admin/plugins/journals/imports.json", {
        type: "POST",
        data: body,
        processData: false,
        contentType: false,
      });

      this.toasts.success({
        duration: 5000,
        data: {
          message: result.message || i18n("discourse_journals.admin.imports.started")
        },
      });

      input.value = "";
    } catch (e) {
      popupAjaxError(e);
    } finally {
      this.importing = false;
    }
  }

  <template>
    <div class="journals-import-page">
      <h2>{{i18n "discourse_journals.admin.heading"}}</h2>

      <div class="journals-import-description">
        <p>{{i18n "discourse_journals.admin.imports.description"}}</p>
      </div>

      <div class="control-group">
        <label class="control-label" for="journals-import-file">
          {{i18n "discourse_journals.admin.imports.file"}}
        </label>
        <div class="controls">
          <input
            id="journals-import-file"
            type="file"
            accept=".json"
            disabled={{this.importing}}
          />
        </div>
      </div>

      <div class="control-group">
        <div class="controls">
          <button
            class="btn btn-primary"
            type="button"
            disabled={{this.importing}}
            {{on "click" this.startImport}}
          >
            {{#if this.importing}}
              {{i18n "discourse_journals.admin.imports.importing"}}
            {{else}}
              {{i18n "discourse_journals.admin.imports.start"}}
            {{/if}}
          </button>
        </div>
      </div>

      {{#if this.importing}}
        <div class="alert alert-info">
          <p>{{i18n "discourse_journals.admin.imports.note"}}</p>
        </div>
      {{/if}}
    </div>
  </template>
}
