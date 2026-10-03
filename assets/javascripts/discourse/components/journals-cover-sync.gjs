import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { service } from "@ember/service";
import { trustHTML } from "@ember/template";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import { duration } from "discourse/lib/formatter";
import DButton from "discourse/ui-kit/d-button";
import { i18n } from "discourse-i18n";

const CHANNEL = "/journals/cover-sync";

const STATS = [
  { key: "scanned", className: "stat-info" },
  { key: "with_cover", className: "stat-success" },
  { key: "updated", className: "stat-success" },
  { key: "purged", className: "stat-info" },
  { key: "cleared", className: "stat-info" },
  { key: "unchanged", className: "stat-info" },
  { key: "legacy_cleaned", className: "stat-info" },
  { key: "skipped", className: "stat-info" },
  { key: "errors", className: "stat-error", hideWhenZero: true },
];

const RESULTS = {
  completed: "message-success",
  failed: "message-error",
  paused: "message-warning",
};

export default class JournalsCoverSync extends Component {
  @service dialog;
  @service messageBus;

  @tracked coverSync = null;
  @tracked pausing = false;
  @tracked progress = null;

  #onMessage = (data) => {
    this.progress = data;

    if (data.status === "processing") {
      // The batch in flight when a pause lands still reports progress.
      if (this.coverSync?.status !== "paused") {
        this.coverSync = { ...this.coverSync, status: "processing" };
      }
    } else {
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
    return ["paused", "failed"].includes(this.coverSync?.status);
  }

  get isRunning() {
    return ["pending", "processing"].includes(this.coverSync?.status);
  }

  get percent() {
    const total = this.progress?.total || this.coverSync?.total || 0;
    const processed = this.progress?.processed ?? this.coverSync?.processed ?? 0;
    if (total <= 0) {
      return 0;
    }

    // One decimal: a full run takes hours, so whole percents sit still for minutes.
    return Math.min(100, Math.round((processed * 1000) / total) / 10);
  }

  get progressMessage() {
    const progress = this.progress;
    if (!progress?.total) {
      if (this.coverSync?.processed) {
        return i18n("discourse_journals.admin.covers.processed", {
          processed: this.coverSync.processed,
          total: this.coverSync.total,
        });
      }
      return i18n("discourse_journals.admin.covers.starting");
    }

    const values = {
      processed: progress.processed,
      total: progress.total,
      speed: progress.speed,
    };
    if (!progress.eta_seconds) {
      return i18n("discourse_journals.admin.covers.progress", values);
    }

    return i18n("discourse_journals.admin.covers.progress_with_eta", {
      ...values,
      eta: duration(progress.eta_seconds, { format: "medium" }),
    });
  }

  get progressStyle() {
    const width = Math.min(100, Math.max(0, this.percent));
    return trustHTML(`width: ${width}%`);
  }

  get result() {
    const status = this.coverSync?.status;
    if (!RESULTS[status]) {
      return null;
    }

    return {
      className: RESULTS[status],
      title: i18n(`discourse_journals.admin.covers.${status}`),
    };
  }

  get startLabel() {
    return this.canResume
      ? "discourse_journals.admin.covers.restart"
      : "discourse_journals.admin.covers.start";
  }

  get statItems() {
    const stats = this.progress?.stats || this.coverSync?.stats;
    if (!stats || Object.keys(stats).length === 0) {
      return [];
    }

    return STATS.filter(({ key, hideWhenZero }) => !hideWhenZero || stats[key]).map(
      ({ key, className }) => ({
        className,
        label: i18n(`discourse_journals.admin.covers.stats.${key}`),
        value: stats[key] || 0,
      })
    );
  }

  @action
  async pause() {
    this.pausing = true;

    try {
      await ajax("/admin/journals/covers/pause", { type: "POST" });
      // A run still waiting in the queue never reports back, so read the
      // paused state directly instead of waiting for the job.
      await this.#loadStatus();
    } catch (e) {
      popupAjaxError(e);
    } finally {
      this.pausing = false;
    }
  }

  @action
  async resume() {
    try {
      const result = await ajax("/admin/journals/covers/resume", {
        type: "POST",
      });
      this.progress = null;
      this.coverSync = result.cover_sync;
      this.#subscribe();
    } catch (e) {
      popupAjaxError(e);
    }
  }

  @action
  async start() {
    const confirmed = await this.dialog.yesNoConfirm({
      message: i18n("discourse_journals.admin.covers.confirm_start"),
    });
    if (!confirmed) {
      return;
    }

    try {
      const result = await ajax("/admin/journals/covers/sync", {
        type: "POST",
      });
      this.progress = null;
      this.coverSync = result.cover_sync;
      this.#subscribe();
    } catch (e) {
      popupAjaxError(e);
    }
  }

  async #loadStatus() {
    try {
      const result = await ajax("/admin/journals/covers/status");
      this.coverSync = result.cover_sync;
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
    <section class="journals-section journals-cover-sync">
      <div class="section-header">
        <h3>{{i18n "discourse_journals.admin.covers.heading"}}</h3>
        <div class="header-actions journals-cover-sync__actions">
          {{#if this.isRunning}}
            <DButton
              class="btn-danger"
              @action={{this.pause}}
              @disabled={{this.pausing}}
              @icon="pause"
              @isLoading={{this.pausing}}
              @label="discourse_journals.admin.covers.pause"
            />
          {{else}}
            {{#if this.canResume}}
              <DButton
                class="btn-primary"
                @action={{this.resume}}
                @disabled={{@applying}}
                @icon="play"
                @label="discourse_journals.admin.covers.resume"
              />
            {{/if}}
            <DButton
              class={{if this.canResume "btn-default" "btn-primary"}}
              @action={{this.start}}
              @disabled={{@applying}}
              @icon="image"
              @label={{this.startLabel}}
            />
          {{/if}}
        </div>
      </div>

      <div class="section-content">
        <p class="journals-cover-sync__desc">{{i18n
            "discourse_journals.admin.covers.description"
          }}</p>

        {{#if this.isRunning}}
          <div class="journals-cover-sync__progress">
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
            {{#if this.coverSync.error_message}}
              <p>{{this.coverSync.error_message}}</p>
            {{/if}}
          </div>
        {{/if}}

        {{#if this.statItems.length}}
          <div class="stats-grid journals-cover-sync__stats">
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
