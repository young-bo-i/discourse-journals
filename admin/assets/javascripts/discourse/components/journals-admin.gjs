import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import didInsert from "@ember/render-modifiers/modifiers/did-insert";
import { service } from "@ember/service";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import { i18n } from "discourse-i18n";

export default class JournalsAdmin extends Component {
  @service toasts;

  @tracked loading = false;
  @tracked importing = false;

  @action
  async startImport(event) {
    event?.preventDefault();

    const input = document.getElementById("journals-import-file");
    const file = input?.files?.[0];
    if (!file) {
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
        duration: 3000,
        data: { message: result.message || i18n("discourse_journals.admin.imports.started") },
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
    <div>
      <h2>{{i18n "discourse_journals.admin.heading"}}</h2>

      <div class="journals-import-section">
        <h3>{{i18n "discourse_journals.admin.imports.title"}}</h3>

        <p>{{i18n "discourse_journals.admin.imports.description"}}</p>

        <div class="form-kit">
          <div class="form-kit__row">
            <label class="form-kit__label" for="journals-import-file">
              {{i18n "discourse_journals.admin.imports.file"}}
            </label>
            <input
              id="journals-import-file"
              class="form-kit__control"
              type="file"
              accept=".json"
            />
          </div>

          <div class="form-kit__row">
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

          {{#if this.importing}}
            <div class="journals-import-note">
              {{i18n "discourse_journals.admin.imports.note"}}
            </div>
          {{/if}}
        </div>
      </div>
    </div>
  </template>
}
