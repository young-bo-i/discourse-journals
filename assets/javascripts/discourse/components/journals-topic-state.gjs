import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { cancel } from "@ember/runloop";
import { service } from "@ember/service";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import discourseLater from "discourse/lib/later";
import DButton from "discourse/ui-kit/d-button";
import { i18n } from "discourse-i18n";

const POLL_INTERVAL = 3000;
// The job opens ~340K topics in well under a minute; stop asking after five minutes.
const MAX_POLLS = 100;

export default class JournalsTopicState extends Component {
  @service dialog;

  @tracked opening = false;
  @tracked topics = null;

  #polls = 0;
  #pollTimer = null;

  constructor() {
    super(...arguments);
    this.#loadStatus();
  }

  willDestroy() {
    super.willDestroy(...arguments);
    cancel(this.#pollTimer);
  }

  get openDisabled() {
    return (
      !this.topics ||
      this.opening ||
      (this.topics.closed === 0 && !this.topics.close_setting)
    );
  }

  get statusText() {
    const { closed, total } = this.topics;
    if (this.opening && closed > 0) {
      return i18n("discourse_journals.admin.topics.opening", { closed });
    }
    if (closed === 0) {
      return i18n("discourse_journals.admin.topics.all_open", { total });
    }

    return i18n("discourse_journals.admin.topics.closed_count", {
      closed,
      total,
    });
  }

  @action
  async openAll() {
    const confirmed = await this.dialog.yesNoConfirm({
      message: i18n("discourse_journals.admin.topics.confirm_open_all", {
        closed: this.topics.closed,
      }),
    });
    if (!confirmed) {
      return;
    }

    try {
      const result = await ajax("/admin/journals/topics/open_all", {
        type: "POST",
      });
      this.topics = result.topics;
      this.opening = true;
      this.#polls = 0;
      this.#schedulePoll();
    } catch (e) {
      popupAjaxError(e);
    }
  }

  async #loadStatus() {
    try {
      const result = await ajax("/admin/journals/topics/status");
      this.topics = result.topics;
    } catch {
      // Same as the other sections: a failed status read leaves the panel idle.
    }
  }

  #schedulePoll() {
    this.#pollTimer = discourseLater(async () => {
      await this.#loadStatus();
      this.#polls += 1;
      if (this.topics?.closed > 0 && this.#polls < MAX_POLLS) {
        this.#schedulePoll();
      } else {
        this.opening = false;
      }
    }, POLL_INTERVAL);
  }

  <template>
    <section class="journals-section journals-topic-state">
      <div class="section-header">
        <h3>{{i18n "discourse_journals.admin.topics.heading"}}</h3>
        <div class="header-actions">
          <DButton
            class="btn-primary"
            @action={{this.openAll}}
            @disabled={{this.openDisabled}}
            @icon="unlock"
            @isLoading={{this.opening}}
            @label="discourse_journals.admin.topics.open_all"
          />
        </div>
      </div>

      <div class="section-content">
        <p class="journals-topic-state__desc">{{i18n
            "discourse_journals.admin.topics.description"
          }}</p>

        {{#if this.topics}}
          <p class="journals-topic-state__status">{{this.statusText}}</p>
          {{#if this.topics.close_setting}}
            <p class="journals-topic-state__warning">{{i18n
                "discourse_journals.admin.topics.setting_closed"
              }}</p>
          {{/if}}
        {{/if}}
      </div>
    </section>
  </template>
}
