import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import { service } from "@ember/service";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import { i18n } from "discourse-i18n";

export default class JournalsImport extends Component {
  @service toasts;
  @service siteSettings;

  @tracked importing = false;

  get shouldShow() {
    return this.args.outletArgs.model?.id === "discourse-journals";
  }

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

      // Clear the file input
      input.value = "";
    } catch (e) {
      popupAjaxError(e);
    } finally {
      this.importing = false;
    }
  }

  <template>
    {{#if this.shouldShow}}
      <div class="admin-config-area journals-import-section">
        <h3>{{i18n "discourse_journals.admin.imports.title"}}</h3>
        
        <div class="journals-import-description">
          <p>{{i18n "discourse_journals.admin.imports.description"}}</p>
        </div>

        <div class="control-group">
          <label class="control-label">
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
          <div class="journals-import-note">
            <p>{{i18n "discourse_journals.admin.imports.note"}}</p>
          </div>
        {{/if}}

        <hr style="margin: 30px 0;" />
      </div>
    {{/if}}
  </template>
}
