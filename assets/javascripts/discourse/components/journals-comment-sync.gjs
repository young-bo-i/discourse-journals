import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { service } from "@ember/service";
import { trustHTML } from "@ember/template";
import Form from "discourse/components/form";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import { duration } from "discourse/lib/formatter";
import { or } from "discourse/truth-helpers";
import DButton from "discourse/ui-kit/d-button";
import { i18n } from "discourse-i18n";

const CHANNEL = "/journals/comment-sync";

const STATS = [
  { key: "journals", className: "stat-info" },
  { key: "created", className: "stat-success" },
  { key: "updated", className: "stat-success" },
  { key: "deleted", className: "stat-info" },
  { key: "unchanged", className: "stat-info" },
  { key: "skipped", className: "stat-info", hideWhenZero: true },
  { key: "held", className: "stat-error", hideWhenZero: true },
  { key: "errors", className: "stat-error", hideWhenZero: true },
];

const RESULTS = {
  completed: "message-success",
  failed: "message-error",
  paused: "message-warning",
};

export default class JournalsCommentSync extends Component {
  @service dialog;
  @service messageBus;

  @tracked commentSync = null;
  @tracked pausing = false;
  @tracked progress = null;

  formData = { topic_ids: "", limit: 5 };

  #onMessage = (data) => {
    this.progress = data;

    if (data.status !== "processing") {
      this.pausing = false;
      this.messageBus.unsubscribe(CHANNEL, this.#onMessage);
      this.#loadStatus();
    }
  };

  constructor() {
    super(...arguments);
    this.#loadStatus();
  }

  willDestroy() {
    super.willDestroy(...arguments);
    this.messageBus.unsubscribe(CHANNEL, this.#onMessage);
  }

  get canResume() {
    return ["paused", "failed"].includes(this.commentSync?.status);
  }

  get isRunning() {
    return ["pending", "processing"].includes(this.commentSync?.status);
  }

  get modeLabel() {
    const mode = this.progress?.mode || this.commentSync?.mode || "test";
    return i18n(`discourse_journals.admin.comments.mode_${mode}`);
  }

  get percent() {
    const total = this.progress?.total ?? this.commentSync?.total ?? 0;
    const processed =
      this.progress?.processed ?? this.commentSync?.processed ?? 0;
    if (total <= 0) {
      return 0;
    }

    // One decimal: a full run takes hours, so whole percents sit still for minutes.
    return Math.min(100, Math.round((processed * 1000) / total) / 10);
  }

  get progressMessage() {
    const total = this.progress?.total ?? this.commentSync?.total;
    if (!total) {
      return i18n("discourse_journals.admin.comments.starting");
    }

    const values = {
      processed: this.progress?.processed ?? this.commentSync?.processed ?? 0,
      total,
    };
    if (!this.progress?.eta_seconds) {
      return i18n("discourse_journals.admin.comments.progress", values);
    }

    return i18n("discourse_journals.admin.comments.progress_with_eta", {
      ...values,
      speed: this.progress.speed,
      eta: duration(this.progress.eta_seconds, { format: "medium" }),
    });
  }

  get progressStyle() {
    return trustHTML(`width: ${this.percent}%`);
  }

  get result() {
    const status = this.commentSync?.status;
    if (!RESULTS[status]) {
      return null;
    }

    return {
      className: RESULTS[status],
      title: i18n(`discourse_journals.admin.comments.${status}`),
    };
  }

  get statItems() {
    const stats = this.progress?.stats || this.commentSync?.stats;
    if (!stats || Object.keys(stats).length === 0) {
      return [];
    }

    return STATS.filter(
      ({ key, hideWhenZero }) => !hideWhenZero || stats[key]
    ).map(({ key, className }) => ({
      className,
      label: i18n(`discourse_journals.admin.comments.stats.${key}`),
      value: stats[key] || 0,
    }));
  }

  @action
  async pause() {
    this.pausing = true;

    try {
      const result = await ajax("/admin/journals/comments/pause", {
        type: "POST",
      });
      this.commentSync = result.comment_sync;
    } catch (e) {
      this.pausing = false;
      popupAjaxError(e);
    }
  }

  @action
  async restartFull() {
    await this.#startRun(
      { mode: "full" },
      "discourse_journals.admin.comments.confirm_restart"
    );
  }

  @action
  async resume() {
    try {
      const result = await ajax("/admin/journals/comments/resume", {
        type: "POST",
      });
      this.progress = null;
      this.commentSync = result.comment_sync;
      this.#subscribe();
    } catch (e) {
      popupAjaxError(e);
    }
  }

  @action
  async startFull() {
    await this.#startRun(
      { mode: "full" },
      "discourse_journals.admin.comments.confirm_full"
    );
  }

  @action
  async startTest(data) {
    await this.#startRun(
      { mode: "test", topic_ids: data.topic_ids, limit: data.limit },
      "discourse_journals.admin.comments.confirm_test"
    );
  }

  async #loadStatus() {
    try {
      const result = await ajax("/admin/journals/comments/status");
      this.commentSync = result.comment_sync;
      if (this.isRunning) {
        this.#subscribe();
      }
    } catch {
      // Same as the other sections: a failed status read leaves the panel idle.
    }
  }

  async #startRun(params, confirmKey) {
    const confirmed = await this.dialog.yesNoConfirm({
      message: i18n(confirmKey),
    });
    if (!confirmed) {
      return;
    }

    try {
      const result = await ajax("/admin/journals/comments/sync", {
        type: "POST",
        data: params,
      });
      this.progress = null;
      this.commentSync = result.comment_sync;
      this.#subscribe();
    } catch (e) {
      popupAjaxError(e);
    }
  }

  #subscribe() {
    this.messageBus.unsubscribe(CHANNEL, this.#onMessage);
    this.messageBus.subscribe(CHANNEL, this.#onMessage);
  }

  <template>
    <section class="journals-section journals-comment-sync">
      <div class="section-header">
        <h3>{{i18n "discourse_journals.admin.comments.heading"}}</h3>
        <div class="header-actions journals-comment-sync__actions">
          {{#if this.isRunning}}
            <DButton
              class="btn-danger"
              @action={{this.pause}}
              @disabled={{this.pausing}}
              @icon="pause"
              @isLoading={{this.pausing}}
              @label="discourse_journals.admin.comments.pause"
            />
          {{else if this.canResume}}
            <DButton
              class="btn-primary"
              @action={{this.resume}}
              @disabled={{@applying}}
              @icon="play"
              @label="discourse_journals.admin.comments.resume"
            />
            <DButton
              class="btn-default"
              @action={{this.restartFull}}
              @disabled={{@applying}}
              @icon="arrows-rotate"
              @label="discourse_journals.admin.comments.restart_full"
            />
          {{else}}
            <DButton
              class="btn-primary"
              @action={{this.startFull}}
              @disabled={{@applying}}
              @icon="comments"
              @label="discourse_journals.admin.comments.start_full"
            />
          {{/if}}
        </div>
      </div>

      <div class="section-content">
        <p class="journals-comment-sync__desc">{{i18n
            "discourse_journals.admin.comments.description"
          }}</p>

        {{#if this.isRunning}}
          <div class="journals-comment-sync__progress">
            <div class="progress-container">
              <div class="progress-track">
                <div class="progress-fill" style={{this.progressStyle}}></div>
              </div>
              <span class="progress-percent">{{this.percent}}%</span>
            </div>
            <p class="progress-status">
              <span
                class="journals-comment-sync__mode"
              >{{this.modeLabel}}</span>
              {{this.progressMessage}}
            </p>
          </div>
        {{else if this.result}}
          <div class="message-box {{this.result.className}}">
            <strong>{{this.modeLabel}} · {{this.result.title}}</strong>
            {{#if this.commentSync.error_message}}
              <p>{{this.commentSync.error_message}}</p>
            {{/if}}
          </div>
        {{/if}}

        {{#if this.statItems.length}}
          <div class="stats-grid journals-comment-sync__stats">
            {{#each this.statItems as |item|}}
              <div class="stat-item {{item.className}}">
                <span class="stat-value">{{item.value}}</span>
                <span class="stat-label">{{item.label}}</span>
              </div>
            {{/each}}
          </div>
        {{/if}}

        <details class="journals-comment-sync__test">
          <summary>{{i18n
              "discourse_journals.admin.comments.test_heading"
            }}</summary>
          <p class="journals-comment-sync__desc">{{i18n
              "discourse_journals.admin.comments.test_description"
            }}</p>

          <Form @data={{this.formData}} @onSubmit={{this.startTest}} as |form|>
            <form.Field
              @format="large"
              @name="topic_ids"
              @title={{i18n "discourse_journals.admin.comments.topic_ids"}}
              @type="input"
              as |field|
            >
              <field.Control
                placeholder={{i18n
                  "discourse_journals.admin.comments.topic_ids_placeholder"
                }}
              />
            </form.Field>

            <form.Field
              @format="small"
              @name="limit"
              @title={{i18n "discourse_journals.admin.comments.limit"}}
              @type="input-number"
              @validation="required|integer|between:1,200"
              as |field|
            >
              <field.Control />
            </form.Field>

            <form.Submit
              @disabled={{or this.isRunning @applying}}
              @icon="flask"
              @label="discourse_journals.admin.comments.start_test"
            />
          </Form>
        </details>
      </div>
    </section>
  </template>
}
