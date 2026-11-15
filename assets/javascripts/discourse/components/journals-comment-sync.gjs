import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { service } from "@ember/service";
import { trustHTML } from "@ember/template";
import Form from "discourse/components/form";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import { or } from "discourse/truth-helpers";
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
};

export default class JournalsCommentSync extends Component {
  @service dialog;
  @service messageBus;

  @tracked commentSync = null;
  @tracked progress = null;

  formData = { topic_ids: "", limit: 5 };

  #onMessage = (data) => {
    this.progress = data;

    if (data.status !== "processing") {
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

  get isRunning() {
    return ["pending", "processing"].includes(this.commentSync?.status);
  }

  get percent() {
    const total = this.progress?.total ?? this.commentSync?.total ?? 0;
    const processed =
      this.progress?.processed ?? this.commentSync?.processed ?? 0;
    if (total <= 0) {
      return 0;
    }

    return Math.min(100, Math.round((processed * 100) / total));
  }

  get progressMessage() {
    const total = this.progress?.total ?? this.commentSync?.total;
    if (!total) {
      return i18n("discourse_journals.admin.comments.starting");
    }

    return i18n("discourse_journals.admin.comments.progress", {
      processed: this.progress?.processed ?? this.commentSync?.processed ?? 0,
      total,
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
  async start(data) {
    const confirmed = await this.dialog.yesNoConfirm({
      message: i18n("discourse_journals.admin.comments.confirm_start"),
    });
    if (!confirmed) {
      return;
    }

    try {
      const result = await ajax("/admin/journals/comments/sync", {
        type: "POST",
        data: { topic_ids: data.topic_ids, limit: data.limit },
      });
      this.progress = null;
      this.commentSync = result.comment_sync;
      this.#subscribe();
    } catch (e) {
      popupAjaxError(e);
    }
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

  #subscribe() {
    this.messageBus.unsubscribe(CHANNEL, this.#onMessage);
    this.messageBus.subscribe(CHANNEL, this.#onMessage);
  }

  <template>
    <section class="journals-section journals-comment-sync">
      <div class="section-header">
        <h3>{{i18n "discourse_journals.admin.comments.heading"}}</h3>
      </div>

      <div class="section-content">
        <p class="journals-comment-sync__desc">{{i18n
            "discourse_journals.admin.comments.description"
          }}</p>

        <Form @data={{this.formData}} @onSubmit={{this.start}} as |form|>
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
            @icon="comments"
            @label="discourse_journals.admin.comments.start"
          />
        </Form>

        {{#if this.isRunning}}
          <div class="journals-comment-sync__progress">
            <div class="progress-container">
              <div class="progress-track">
                <div class="progress-fill" style={{this.progressStyle}}></div>
              </div>
              <span class="progress-percent">{{this.percent}}%</span>
            </div>
            <p class="progress-status">{{this.progressMessage}}</p>
          </div>
        {{else if this.result}}
          <div class="message-box {{this.result.className}}">
            <strong>{{this.result.title}}</strong>
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
      </div>
    </section>
  </template>
}
