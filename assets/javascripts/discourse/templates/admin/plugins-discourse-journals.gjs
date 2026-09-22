import { fn } from "@ember/helper";
import { on } from "@ember/modifier";
import { eq, gt, or } from "discourse/truth-helpers";
import DButton from "discourse/ui-kit/d-button";
import { i18n } from "discourse-i18n";
import JournalsPromoChart from "discourse/plugins/discourse-journals/discourse/components/journals-promo-chart";

export default <template>
  <div class="admin-container journals-admin-page">
    <div class="journals-header">
      <h2>{{i18n "discourse_journals.admin.heading"}}</h2>
      <p class="journals-subtitle">{{i18n
          "discourse_journals.admin.subtitle"
        }}</p>
    </div>

    <div class="journals-main">
      <section class="journals-section personas-section">
        <div class="section-header">
          <h3>{{i18n "discourse_journals.admin.personas.heading"}}</h3>
        </div>
        <div class="section-content">
          <p class="personas-desc">{{i18n
              "discourse_journals.admin.personas.description"
            }}</p>
          <p class="personas-template">
            <DButton
              class="btn-default btn-small"
              @action={{@controller.downloadTemplate}}
              @label="discourse_journals.admin.personas.download_template"
            />
          </p>
          <p class="personas-count">{{i18n
              "discourse_journals.admin.personas.current_count"
              count=@controller.personaCount
            }}</p>

          {{#unless @controller.personaImporting}}
            <div class="personas-upload">
              <input
                accept=".csv,.json"
                type="file"
                {{on "change" @controller.setPersonaFile}}
              />
              <DButton
                class="btn-primary"
                @action={{@controller.uploadPersonas}}
                @disabled={{@controller.personaUploadDisabled}}
                @label="discourse_journals.admin.personas.upload"
              />
            </div>
          {{/unless}}

          {{#if @controller.personaImporting}}
            <div class="personas-progress">
              <div class="progress-container">
                <div class="progress-track">
                  <div
                    class="progress-fill"
                    style={{@controller.personaProgressStyle}}
                  ></div>
                </div>
                <span
                  class="progress-percent"
                >{{@controller.personaProgress}}%</span>
              </div>
              <p class="progress-status">{{i18n
                  "discourse_journals.admin.personas.importing"
                }}</p>
            </div>
          {{/if}}

          {{#if @controller.personaStats}}
            <div class="stats-grid personas-stats-grid">
              <div class="stat-item stat-success">
                <span
                  class="stat-value"
                >{{@controller.personaStats.created}}</span>
                <span class="stat-label">{{i18n
                    "discourse_journals.admin.personas.created"
                  }}</span>
              </div>
              <div class="stat-item">
                <span
                  class="stat-value"
                >{{@controller.personaStats.skipped}}</span>
                <span class="stat-label">{{i18n
                    "discourse_journals.admin.personas.skipped"
                  }}</span>
              </div>
              <div class="stat-item stat-error">
                <span
                  class="stat-value"
                >{{@controller.personaStats.errors}}</span>
                <span class="stat-label">{{i18n
                    "discourse_journals.admin.personas.errors"
                  }}</span>
              </div>
            </div>
          {{/if}}

          {{#if @controller.personaMessage}}
            <div
              class="message-box
                {{if
                  @controller.personaFailed
                  'message-error'
                  'message-success'
                }}"
            >
              {{@controller.personaMessage}}
            </div>
          {{/if}}
        </div>
      </section>

      <section class="journals-section mapping-section">
        <div class="section-header">
          <h3>{{i18n "discourse_journals.admin.mapping.heading"}}</h3>
          <div class="header-actions">
            {{#if @controller.analyzing}}
              <DButton
                class="btn-danger"
                @action={{@controller.pauseMappingAnalysis}}
                @disabled={{@controller.analysisPausing}}
                @icon="pause"
                @isLoading={{@controller.analysisPausing}}
                @label="discourse_journals.admin.mapping.pause"
              />
            {{else}}
              <DButton
                class="btn-primary"
                @action={{@controller.startMappingAnalysis}}
                @disabled={{or @controller.analyzing @controller.applying}}
                @icon="exchange-alt"
                @label="discourse_journals.admin.mapping.start"
              />
              {{#if
                (or
                  @controller.analysisPaused
                  @controller.analysisFailed
                  @controller.analysisResult
                )
              }}
                <DButton
                  class="btn-default"
                  @action={{@controller.restartMappingAnalysis}}
                  @disabled={{@controller.applying}}
                  @icon="redo"
                  @label="discourse_journals.admin.mapping.restart"
                />
              {{/if}}
            {{/if}}
          </div>
        </div>

        <div class="section-content">
          <p class="mapping-desc">{{i18n
              "discourse_journals.admin.mapping.description"
            }}</p>

          {{#if @controller.analyzing}}
            <div class="mapping-progress">
              <div class="progress-container">
                <div class="progress-track">
                  <div
                    class="progress-fill"
                    style={{@controller.analysisProgressStyle}}
                  ></div>
                </div>
                <span
                  class="progress-percent"
                >{{@controller.analysisProgress}}%</span>
              </div>
              <p class="progress-status">{{@controller.analysisMessage}}</p>
            </div>
          {{/if}}

          {{#if @controller.analysisFailed}}
            <div class="mapping-failed-panel">
              <div class="mapping-progress">
                <div class="progress-container">
                  <div class="progress-track">
                    <div
                      class="progress-fill progress-fill-error"
                      style={{@controller.analysisProgressStyle}}
                    ></div>
                  </div>
                  <span
                    class="progress-percent"
                  >{{@controller.analysisProgress}}%</span>
                </div>
              </div>
              <div class="message-box message-error">
                <span class="error-icon">&#x26A0;</span>
                <div class="error-content">
                  <strong>{{i18n
                      "discourse_journals.admin.mapping.analysis_error_title"
                    }}</strong>
                  <p>{{@controller.analysisMessage}}</p>
                </div>
              </div>
              <p class="mapping-failed-hint">{{i18n
                  "discourse_journals.admin.mapping.analysis_error_hint"
                }}</p>
            </div>
          {{/if}}

          {{#if @controller.analysisPaused}}
            <div class="mapping-paused-panel">
              <div class="mapping-progress">
                <div class="progress-container">
                  <div class="progress-track">
                    <div
                      class="progress-fill progress-fill-paused"
                      style={{@controller.analysisProgressStyle}}
                    ></div>
                  </div>
                  <span
                    class="progress-percent"
                  >{{@controller.analysisProgress}}%</span>
                </div>
              </div>
              <div class="message-box message-warning">
                <span class="paused-icon">&#x23F8;</span>
                <div class="paused-content">
                  <strong>{{i18n
                      "discourse_journals.admin.mapping.analysis_paused_title"
                    }}</strong>
                  <p>{{@controller.analysisMessage}}</p>
                </div>
              </div>
              <p class="mapping-paused-hint">{{i18n
                  "discourse_journals.admin.mapping.analysis_paused_hint"
                }}</p>
            </div>
          {{/if}}

          {{#if @controller.analysisMessage}}
            {{#unless @controller.analyzing}}
              {{#unless @controller.analysisResult}}
                {{#unless @controller.analysisFailed}}
                  {{#unless @controller.analysisPaused}}
                    <div class="message-box message-error">
                      {{@controller.analysisMessage}}
                    </div>
                  {{/unless}}
                {{/unless}}
              {{/unless}}
            {{/unless}}
          {{/if}}

          {{#if @controller.analysisResult}}
            <div class="mapping-summary">
              <div class="mapping-totals">
                <div class="mapping-total-item">
                  <span
                    class="total-value"
                  >{{@controller.analysisResult.total_forum_topics}}</span>
                  <span class="total-label">{{i18n
                      "discourse_journals.admin.mapping.forum_topics"
                    }}</span>
                </div>
                <div class="mapping-total-item">
                  <span
                    class="total-value"
                  >{{@controller.analysisResult.total_api_records}}</span>
                  <span class="total-label">{{i18n
                      "discourse_journals.admin.mapping.api_records"
                    }}</span>
                </div>
              </div>

              <div class="mapping-categories">
                <div
                  class="mapping-cat-row clickable"
                  role="button"
                  {{on
                    "click"
                    (fn @controller.loadMappingDetails "exact_1to1")
                  }}
                >
                  <span class="cat-color cat-success"></span>
                  <span class="cat-label">{{i18n
                      "discourse_journals.admin.mapping.exact_1to1"
                    }}</span>
                  <span
                    class="cat-count"
                  >{{@controller.analysisResult.exact_1to1}}</span>
                  <div class="cat-bar-track">
                    <div
                      class="cat-bar-fill cat-bar-success"
                      style={{@controller.mappingBarStyles.exact_1to1}}
                    ></div>
                  </div>
                </div>

                <div
                  class="mapping-cat-row clickable"
                  role="button"
                  {{on
                    "click"
                    (fn @controller.loadMappingDetails "forum_1_to_api_n")
                  }}
                >
                  <span class="cat-color cat-warning"></span>
                  <span class="cat-label">{{i18n
                      "discourse_journals.admin.mapping.forum_1_to_api_n"
                    }}</span>
                  <span
                    class="cat-count"
                  >{{@controller.analysisResult.forum_1_to_api_n}}</span>
                  <div class="cat-bar-track">
                    <div
                      class="cat-bar-fill cat-bar-warning"
                      style={{@controller.mappingBarStyles.forum_1_to_api_n}}
                    ></div>
                  </div>
                </div>

                <div
                  class="mapping-cat-row clickable"
                  role="button"
                  {{on
                    "click"
                    (fn @controller.loadMappingDetails "forum_n_to_api_1")
                  }}
                >
                  <span class="cat-color cat-warning"></span>
                  <span class="cat-label">{{i18n
                      "discourse_journals.admin.mapping.forum_n_to_api_1"
                    }}</span>
                  <span
                    class="cat-count"
                  >{{@controller.analysisResult.forum_n_to_api_1}}</span>
                  <div class="cat-bar-track">
                    <div
                      class="cat-bar-fill cat-bar-warning"
                      style={{@controller.mappingBarStyles.forum_n_to_api_1}}
                    ></div>
                  </div>
                </div>

                <div
                  class="mapping-cat-row clickable"
                  role="button"
                  {{on
                    "click"
                    (fn @controller.loadMappingDetails "forum_n_to_api_m")
                  }}
                >
                  <span class="cat-color cat-danger"></span>
                  <span class="cat-label">{{i18n
                      "discourse_journals.admin.mapping.forum_n_to_api_m"
                    }}</span>
                  <span
                    class="cat-count"
                  >{{@controller.analysisResult.forum_n_to_api_m}}</span>
                  <div class="cat-bar-track">
                    <div
                      class="cat-bar-fill cat-bar-danger"
                      style={{@controller.mappingBarStyles.forum_n_to_api_m}}
                    ></div>
                  </div>
                </div>

                <div
                  class="mapping-cat-row clickable"
                  role="button"
                  {{on
                    "click"
                    (fn @controller.loadMappingDetails "forum_only")
                  }}
                >
                  <span class="cat-color cat-orphan"></span>
                  <span class="cat-label">{{i18n
                      "discourse_journals.admin.mapping.forum_only"
                    }}</span>
                  <span
                    class="cat-count"
                  >{{@controller.analysisResult.forum_only}}</span>
                  <div class="cat-bar-track">
                    <div
                      class="cat-bar-fill cat-bar-orphan"
                      style={{@controller.mappingBarStyles.forum_only}}
                    ></div>
                  </div>
                </div>

                <div
                  class="mapping-cat-row clickable"
                  role="button"
                  {{on "click" (fn @controller.loadMappingDetails "api_only")}}
                >
                  <span class="cat-color cat-new"></span>
                  <span class="cat-label">{{i18n
                      "discourse_journals.admin.mapping.api_only"
                    }}</span>
                  <span
                    class="cat-count"
                  >{{@controller.analysisResult.api_only}}</span>
                  <div class="cat-bar-track">
                    <div
                      class="cat-bar-fill cat-bar-new"
                      style={{@controller.mappingBarStyles.api_only}}
                    ></div>
                  </div>
                </div>
              </div>

              {{#if @controller.analysisResult.completed_at}}
                <p class="mapping-time">{{i18n
                    "discourse_journals.admin.mapping.completed_at"
                  }}
                  {{@controller.analysisResult.completed_at}}</p>
              {{/if}}
            </div>

            {{#if @controller.showAnalysisDetails}}
              <div class="mapping-details-panel">
                <div class="details-header">
                  <h4>{{@controller.analysisCategoryLabel}}
                    ({{@controller.analysisDetailsTotal}})</h4>
                  <DButton
                    class="btn-flat"
                    @action={{@controller.closeMappingDetails}}
                    @icon="times"
                  />
                </div>

                {{#if @controller.loadingDetails}}
                  <div class="details-loading">{{i18n
                      "discourse_journals.admin.mapping.loading"
                    }}</div>
                {{else}}
                  <div class="details-table-wrap">
                    <table class="mapping-details-table">
                      <thead>
                        <tr>
                          <th>{{i18n
                              "discourse_journals.admin.mapping.col_title"
                            }}</th>
                          {{#if @controller.isDetailsCategoryMatched}}
                            <th>{{i18n
                                "discourse_journals.admin.mapping.col_topic_id"
                              }}</th>
                            <th>{{i18n
                                "discourse_journals.admin.mapping.col_api_id"
                              }}</th>
                            <th>{{i18n
                                "discourse_journals.admin.mapping.col_issn_l"
                              }}</th>
                          {{/if}}
                          {{#if @controller.isDetailsCategoryForumOnly}}
                            <th>{{i18n
                                "discourse_journals.admin.mapping.col_topic_id"
                              }}</th>
                          {{/if}}
                          {{#if @controller.isDetailsCategoryApiOnly}}
                            <th>{{i18n
                                "discourse_journals.admin.mapping.col_api_id"
                              }}</th>
                            <th>{{i18n
                                "discourse_journals.admin.mapping.col_issn_l"
                              }}</th>
                          {{/if}}
                        </tr>
                      </thead>
                      <tbody>
                        {{#each @controller.analysisDetailsItems as |item|}}
                          <tr>
                            <td
                              class="detail-title"
                            >{{item.normalized_title}}</td>
                            {{#if item.forum}}
                              <td>
                                {{#each item.forum as |f|}}
                                  <a
                                    href="/t/{{f.topic_id}}"
                                    rel="noopener noreferrer"
                                    target="_blank"
                                  >{{f.topic_id}}</a>
                                {{/each}}
                              </td>
                            {{/if}}
                            {{#if item.api}}
                              <td>
                                {{#each item.api as |a|}}
                                  <span class="api-id-badge">{{a.api_id}}</span>
                                {{/each}}
                              </td>
                              <td>
                                {{#each item.api as |a|}}
                                  <span>{{a.issn_l}}</span>
                                {{/each}}
                              </td>
                            {{/if}}
                          </tr>
                        {{/each}}
                      </tbody>
                    </table>
                  </div>

                  {{#if @controller.hasMultipleDetailsPages}}
                    <div class="details-pagination">
                      <DButton
                        class="btn-default btn-small"
                        @action={{@controller.prevDetailsPage}}
                        @disabled={{@controller.prevDetailsPageDisabled}}
                        @icon="chevron-left"
                      />
                      <span
                        class="page-info"
                      >{{@controller.analysisDetailsPage}}
                        /
                        {{@controller.analysisDetailsTotalPages}}</span>
                      <DButton
                        class="btn-default btn-small"
                        @action={{@controller.nextDetailsPage}}
                        @disabled={{@controller.nextDetailsPageDisabled}}
                        @icon="chevron-right"
                      />
                    </div>
                  {{/if}}
                {{/if}}
              </div>
            {{/if}}
          {{/if}}
        </div>
      </section>

      {{#if @controller.analysisResult}}
        <section class="journals-section apply-section">
          <div class="section-header">
            <h3>{{i18n "discourse_journals.admin.mapping.apply_heading"}}</h3>
            <div class="header-actions apply-task-controls">
              {{#if @controller.applying}}
                <DButton
                  class="btn-danger"
                  @action={{@controller.pauseApplyMapping}}
                  @disabled={{@controller.applyPausing}}
                  @icon="pause"
                  @isLoading={{@controller.applyPausing}}
                  @label="discourse_journals.admin.mapping.apply_pause"
                />
              {{else}}
                {{#if @controller.canStartApply}}
                  <DButton
                    class="btn-primary"
                    @action={{@controller.startApplyMapping}}
                    @icon="check-double"
                    @label="discourse_journals.admin.mapping.apply_start"
                  />
                {{/if}}

                {{#if @controller.canResumeApply}}
                  <DButton
                    class="btn-primary"
                    @action={{@controller.resumeApplyMapping}}
                    @icon="play"
                    @label="discourse_journals.admin.mapping.apply_resume"
                  />
                {{/if}}
              {{/if}}
            </div>
          </div>

          <div class="section-content">
            <p class="apply-desc">{{i18n
                "discourse_journals.admin.mapping.apply_description"
              }}</p>

            {{#if @controller.applying}}
              <div class="mapping-apply-progress">
                <div class="progress-container">
                  <div class="progress-track">
                    <div
                      class="progress-fill"
                      style={{@controller.applyProgressStyle}}
                    ></div>
                  </div>
                  <span
                    class="progress-percent"
                  >{{@controller.applyProgress}}%</span>
                </div>
                <p class="progress-status">{{@controller.applyMessage}}</p>
                {{#if @controller.applyStats}}
                  <div class="stats-grid apply-stats-grid">
                    {{#if @controller.applyStats.deleted}}
                      <div class="stat-item stat-error">
                        <span
                          class="stat-value"
                        >{{@controller.applyStats.deleted}}</span>
                        <span class="stat-label">{{i18n
                            "discourse_journals.admin.mapping.apply_stats_deleted"
                          }}</span>
                      </div>
                    {{/if}}
                    <div class="stat-item stat-info">
                      <span
                        class="stat-value"
                      >{{@controller.applyStats.updated}}</span>
                      <span class="stat-label">{{i18n
                          "discourse_journals.admin.mapping.apply_stats_updated"
                        }}</span>
                    </div>
                    <div class="stat-item stat-success">
                      <span
                        class="stat-value"
                      >{{@controller.applyStats.created}}</span>
                      <span class="stat-label">{{i18n
                          "discourse_journals.admin.mapping.apply_stats_created"
                        }}</span>
                    </div>
                    {{#if @controller.applyStats.errors}}
                      <div class="stat-item stat-warning">
                        <span
                          class="stat-value"
                        >{{@controller.applyStats.errors}}</span>
                        <span class="stat-label">{{i18n
                            "discourse_journals.admin.mapping.apply_stats_errors"
                          }}</span>
                      </div>
                    {{/if}}
                  </div>
                {{/if}}
              </div>
            {{/if}}

            {{#if @controller.applyCompleted}}
              <div class="message-box message-success mapping-apply-result">
                <strong>{{i18n
                    "discourse_journals.admin.mapping.apply_completed"
                  }}</strong>
                {{#if @controller.applyStats}}
                  <p>{{i18n
                      "discourse_journals.admin.mapping.apply_stats_deleted"
                    }}:
                    {{@controller.applyStats.deleted}},
                    {{i18n
                      "discourse_journals.admin.mapping.apply_stats_updated"
                    }}:
                    {{@controller.applyStats.updated}},
                    {{i18n
                      "discourse_journals.admin.mapping.apply_stats_created"
                    }}:
                    {{@controller.applyStats.created}}</p>
                {{/if}}
                <p class="apply-completed-hint">{{i18n
                    "discourse_journals.admin.mapping.apply_completed_hint"
                  }}</p>
              </div>
            {{/if}}

            {{#if @controller.applyFailed}}
              <div class="message-box message-error mapping-apply-result">
                <strong>{{i18n
                    "discourse_journals.admin.mapping.apply_failed"
                  }}</strong>
                <p>{{@controller.applyMessage}}</p>
                {{#if @controller.applyStats}}
                  <div class="stats-grid apply-stats-grid stats-grid-inline">
                    {{#if @controller.applyStats.deleted}}
                      <div class="stat-item stat-error">
                        <span
                          class="stat-value"
                        >{{@controller.applyStats.deleted}}</span>
                        <span class="stat-label">{{i18n
                            "discourse_journals.admin.mapping.apply_stats_deleted"
                          }}</span>
                      </div>
                    {{/if}}
                    <div class="stat-item stat-info">
                      <span
                        class="stat-value"
                      >{{@controller.applyStats.updated}}</span>
                      <span class="stat-label">{{i18n
                          "discourse_journals.admin.mapping.apply_stats_updated"
                        }}</span>
                    </div>
                    <div class="stat-item stat-success">
                      <span
                        class="stat-value"
                      >{{@controller.applyStats.created}}</span>
                      <span class="stat-label">{{i18n
                          "discourse_journals.admin.mapping.apply_stats_created"
                        }}</span>
                    </div>
                  </div>
                {{/if}}
              </div>
            {{/if}}

            {{#if @controller.applyPaused}}
              <div class="message-box message-warning mapping-apply-result">
                <strong>{{i18n
                    "discourse_journals.admin.mapping.apply_paused_title"
                  }}</strong>
                <p>{{@controller.applyMessage}}</p>
                {{#if @controller.applyStats}}
                  <div class="stats-grid apply-stats-grid stats-grid-inline">
                    {{#if @controller.applyStats.deleted}}
                      <div class="stat-item stat-error">
                        <span
                          class="stat-value"
                        >{{@controller.applyStats.deleted}}</span>
                        <span class="stat-label">{{i18n
                            "discourse_journals.admin.mapping.apply_stats_deleted"
                          }}</span>
                      </div>
                    {{/if}}
                    <div class="stat-item stat-info">
                      <span
                        class="stat-value"
                      >{{@controller.applyStats.updated}}</span>
                      <span class="stat-label">{{i18n
                          "discourse_journals.admin.mapping.apply_stats_updated"
                        }}</span>
                    </div>
                    <div class="stat-item stat-success">
                      <span
                        class="stat-value"
                      >{{@controller.applyStats.created}}</span>
                      <span class="stat-label">{{i18n
                          "discourse_journals.admin.mapping.apply_stats_created"
                        }}</span>
                    </div>
                  </div>
                {{/if}}
              </div>
            {{/if}}
          </div>
        </section>
      {{/if}}

      <section class="journals-section stats-section">
        <div class="section-header">
          <h3>{{i18n "discourse_journals.admin.stats.heading"}}</h3>
          <div class="header-actions promo-range-controls">
            {{#each @controller.promoRangeOptions as |opt|}}
              <DButton
                class={{if
                  (eq @controller.promoRange opt.days)
                  "btn-primary"
                  "btn-default"
                }}
                @action={{fn @controller.setPromoRange opt.days}}
                @translatedLabel={{opt.label}}
              />
            {{/each}}
          </div>
        </div>

        <div class="section-content">
          <p class="stats-desc">{{i18n
              "discourse_journals.admin.stats.description"
            }}</p>

          {{#if @controller.loadingPromoStats}}
            <div class="details-loading">{{i18n
                "discourse_journals.admin.stats.loading"
              }}</div>
          {{else if @controller.hasPromoData}}
            <div class="promo-summary-cards">
              {{#each @controller.promoSummaryCards as |card|}}
                <div class="promo-summary-card">
                  <div class="promo-card-label">{{card.label}}</div>
                  <div class="promo-card-metrics">
                    <div class="promo-metric">
                      <span
                        class="promo-metric-value"
                      >{{card.impressions}}</span>
                      <span class="promo-metric-label">{{i18n
                          "discourse_journals.admin.stats.impressions"
                        }}</span>
                    </div>
                    <div class="promo-metric">
                      <span class="promo-metric-value">{{card.clicks}}</span>
                      <span class="promo-metric-label">{{i18n
                          "discourse_journals.admin.stats.clicks"
                        }}</span>
                    </div>
                    <div class="promo-metric">
                      <span class="promo-metric-value">{{card.ctr}}%</span>
                      <span class="promo-metric-label">{{i18n
                          "discourse_journals.admin.stats.ctr"
                        }}</span>
                    </div>
                  </div>
                </div>
              {{/each}}
            </div>

            <div class="promo-chart-tabs">
              {{#each @controller.promoSlideTabs as |tab|}}
                <button
                  class="promo-chart-tab
                    {{if
                      (eq @controller.promoSlide tab.key)
                      'promo-chart-tab--active'
                    }}"
                  type="button"
                  {{on "click" (fn @controller.setPromoSlide tab.key)}}
                >{{tab.label}}</button>
              {{/each}}
            </div>

            <JournalsPromoChart @config={{@controller.promoChartConfig}} />
          {{else}}
            <div class="message-box">{{i18n
                "discourse_journals.admin.stats.no_data"
              }}</div>
          {{/if}}
        </div>
      </section>

      <section class="journals-section danger-section">
        <div class="section-header">
          <h3>{{i18n "discourse_journals.admin.danger.heading"}}</h3>
        </div>
        <div class="section-content">
          <div class="danger-action">
            <div class="danger-info">
              <span class="danger-title">{{i18n
                  "discourse_journals.admin.danger.delete_all_title"
                }}</span>
              <span class="danger-desc">{{i18n
                  "discourse_journals.admin.danger.delete_all_desc"
                }}</span>
            </div>
            <DButton
              class="btn-danger"
              @action={{@controller.deleteAllJournals}}
              @disabled={{@controller.deleteDisabled}}
              @icon="trash-alt"
              @isLoading={{@controller.deleting}}
              @label="discourse_journals.admin.danger.delete_all"
            />
          </div>

          {{#if @controller.showDeleteProgress}}
            <div class="delete-progress-section">
              <div class="progress-container">
                <div class="progress-track">
                  <div
                    class="progress-fill progress-danger"
                    style={{@controller.deleteProgressStyle}}
                  ></div>
                </div>
                <span
                  class="progress-percent"
                >{{@controller.deleteProgress}}%</span>
                {{#if @controller.deleteEta}}
                  <span class="progress-eta">{{i18n
                      "discourse_journals.admin.danger.eta_prefix"
                    }}
                    {{@controller.deleteEta}}</span>
                {{/if}}
              </div>

              <p class="progress-status">{{@controller.deleteMessage}}</p>

              {{#if @controller.deleteStats}}
                <div class="stats-grid">
                  <div class="stat-item">
                    <span
                      class="stat-value"
                    >{{@controller.deleteStats.deleted}}</span>
                    <span class="stat-label">{{i18n
                        "discourse_journals.admin.danger.deleted_of"
                      }}
                      {{@controller.deleteStats.total}}</span>
                  </div>
                  {{#if (gt @controller.deleteStats.errors 0)}}
                    <div class="stat-item stat-error">
                      <span
                        class="stat-value"
                      >{{@controller.deleteStats.errors}}</span>
                      <span class="stat-label">{{i18n
                          "discourse_journals.admin.danger.delete_errors_label"
                        }}</span>
                    </div>
                  {{/if}}
                </div>
              {{/if}}
            </div>
          {{else if @controller.deleteMessage}}
            <div
              class="message-box
                {{if
                  @controller.deleteSuccess
                  'message-success'
                  'message-error'
                }}"
            >
              {{@controller.deleteMessage}}
            </div>
          {{/if}}
        </div>
      </section>
    </div>
  </div>
</template>
