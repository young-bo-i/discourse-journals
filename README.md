# 📚 Discourse Journals Plugin

学术期刊统一档案系统 —— 把上游期刊数据库（`journal.scholay.com` 的开放 API）镜像为 Discourse 某个分类下的话题：**一本期刊 = 一个话题**，首帖是服务端渲染的结构化期刊档案页，并叠加 SEO 增强与站内推广位。

> ⚠️ 本插件为 scholay 站点定制，面向单一中文站运行；后台进度/错误文案目前为硬编码中文。

---

## 核心概念（先读这三条）

1. **数据真理源是 custom field，不是帖子 raw。** 每本期刊的归一化 JSON 存在话题 custom field `discourse_journals_data` 里；首帖 cooked HTML 由 `MasterRecordRenderer` 从该 JSON 渲染后用 `update_columns` **直写 cooked**，完全绕过 markdown/sanitize 管线（因为页面含 `<svg>`、CSS checkbox 切换等会被 sanitizer 剥掉的结构）。帖子 raw 只是一行纯文本占位。任何 rebake 都会触发 `before_post_process_cooked` 钩子从 JSON 重新渲染自愈。
   - 含义：XSS 防护完全依赖渲染器自身的 `h()`（HTML escape）纪律，core 的 sanitize 不再兜底——改渲染器时务必保持转义。

2. **同步 = 后台三阶段流水线，状态存单表 `discourse_journals_mapping_analyses`（一行，三个独立 enum 状态机）。**
   - **分析（Analyze）** `Jobs::DiscourseJournals::AnalyzeMapping` → `TitleMatcher`：游标分页拉取 API 全量 + 扫描论坛全量，按 **ISSN-L → api_id → 归一化标题** 三级交叉匹配，产出 6 个桶（`exact_1to1` / `forum_1_to_api_n` / `forum_n_to_api_1` / `forum_n_to_api_m` / `forum_only` / `api_only`）与一份完整 `_action_plan`（updates / creates / deletes）。
   - **应用（Apply）** `Jobs::DiscourseJournals::ApplyMapping` → `MappingApplier`：先把「论坛有、API 没有」的话题**软删除**（标过时，不是硬删），再流水线拉详情（每请求 50 id × 4 并发 + 预取）、4 线程 transform、并行 upsert，写话题/custom fields/tags。每批落 `apply_checkpoint`（含心跳），支持暂停 / 失败 / 进程崩溃（15 分钟无心跳判定为可恢复）后**断点续传**。收尾 `reconcile_counts!` 重算 tag 计数。
   - 一次「分析 → 应用」是全量对账：首次全落在 `api_only` 桶（→ 新建），之后是增量更新 / 去重 / 软删。

3. **SEO 是一等公民，很多「怪」设计都是为它。** 软删除保 URL 不 404（`OutdatedMarker`：打 `discourse_journals_outdated` 标记 + 渲染「已过时」横幅 + 关帖，期刊回到 API 后自动复活）；更新时「cooked 无条件重写、但 `updated_at`/搜索索引仅在内容 MD5 真变化时才动、永不 bump」防止 sitemap 抖动；`plugin.rb` 还 monkey-patch 了 core 的 `Sitemap`（顺带修了一个 core 的 `LIMIT/OFFSET` + 聚合分页 bug）。

---

## 快速开始

1. 启用插件：`Admin → Settings → Plugins → discourse_journals_enabled = true`
2. 配置期刊分类：`discourse_journals_category_id`
3. 配置上游 API 域名（默认 `https://journal.scholay.com`）：`discourse_journals_api_base_url`
4. **配置上游 API 密钥：`discourse_journals_api_key`（必填）**。上游 `/api/open` 下的**全部**接口都要求
   `X-API-Key` 请求头，密钥形如 `jk_…`，在期刊平台管理控制台「API 密钥」页生成、只显示一次。
   留空时分析/同步会立刻以「请先在站点设置中填写上游 API 密钥」失败（不会浪费重试）。
5. 进入 `Admin → Plugins → discourse-journals`，点击「开始分析」，分析完成后「应用映射」。

---

## 站点设置（`config/settings.yml`）

| 设置 | 默认 | 说明 |
|---|---|---|
| `discourse_journals_enabled` | false | 插件总开关 |
| `discourse_journals_category_id` | "" | 期刊分类（所有同步/删除的作用域） |
| `discourse_journals_api_base_url` | `https://journal.scholay.com` | 上游 API 基础地址（协议+域名），也用于拼接封面绝对 URL；`client: true` 前端可读 |
| `discourse_journals_api_key` | "" | **必填**，上游 API 密钥（`jk_…`）。`secret: true`，后台不回显 |
| `discourse_journals_api_rate_limit` | 5 | 调用上游的每秒请求数上限（分析、同步各一个限流器） |
| `discourse_journals_submission_proxy_enabled` | true | 由论坛代理下载投稿须知 / LaTeX 模板（上游这两个地址要密钥，浏览器发不出请求头） |
| `discourse_journals_title_suffix` | 期刊详情 \| … | SEO 标题后缀（仅 HTML title） |
| `discourse_journals_meta_description` / `_meta_keywords` | 模板 | meta 模板，占位符 `{{title}}/{{issn}}/{{publisher}}/{{category}}/{{tags}}/{{site_name}}` |
| `discourse_journals_close_topics` | true | upsert 后关闭话题 |
| `discourse_journals_suggested_mode` / `_criteria` / `_count` | custom_first / `tags\|publisher` / 5 | 「相关期刊」推荐 |
| `discourse_journals_performance_logging` | false | 结构化性能日志（`PerformanceLogger`） |
| `discourse_journals_major_publishers` | 20 家 | 仅这些出版商的期刊打 publisher tag |

---

## 话题 custom fields

真理源 `discourse_journals_data`（归一化 JSON）。匹配键：`discourse_journals_issn_l`、`discourse_journals_api_id`、`discourse_journals_normalized_title_key`（前两者有 `topic_custom_fields` 部分索引）。其余：`discourse_journals_publisher`、`discourse_journals_country`、`discourse_journals_cover_url`、`discourse_journals_outdated`（软删标记，值为 ISO8601 时间）。

> 匹配键的规范列表在 `JournalUpserter::CUSTOM_FIELD_NAMES`（唯一读写方）。
>
> ⚠️ `discourse_journals_api_id` 在 2026-09 之前从未被真正写入过（`JournalUpserter` 读的是
> `normalized[:unified][:id]`，而 `FieldNormalizer#normalize` 根本不产出 `:unified` 键），因此
> `TitleMatcher#match_api_id` 这一整个匹配阶段是空转的。现已改为读 `identity[:api_id]`，并补上
> `idx_tcf_journal_api_id` 部分索引 —— 存量话题要跑完一次「分析 → 应用」才会回填上这个键。

---

## 归一化 JSON 的分区（`discourse_journals_data`）

`FieldNormalizer#normalize` 的输出即真理源，也是渲染器与 JSON-LD 的唯一输入：

| key | 来源 | 说明 |
|---|---|---|
| `identity` | unified / wikidata / openalex | 刊名、**`api_id`**、ISSN 全家桶、缩写、多语言别名、外部标识（Scopus/NLM/VIAF…）、封面 |
| `publication` | crossref / doaj / openalex / wikidata | 出版商、国家、起止年、`is_preprint_repository` |
| `metrics` | openalex + **cwts** | 发文/被引/h/i10、2yr、**SNIP / IPP / 自引率** |
| `jcr` `scimago` `cas_partition` `xinrui_partition` `ccf` `warning` | 各榜单 | 历年数组，新年份在前 |
| **`cwts`** | cwts | SNIP / IPP / 自引率 / 统计文献数，近 15 年 |
| **`jufo`** | jufo | 芬兰/挪威/丹麦三国等级 + 渠道类型 / OA 类型 / 自存档 + 逐年等级（⚠ 上游键叫 `levels` 不是 `all_years`） |
| **`reviews`** | comments | 投稿体验聚合：评分与可信度、质量/速度/沟通/难度/费用 5 个 0-5 维度、录用/拒稿/秒拒/返修率、首审与总处理天数、正负向标签 |
| **`submission`** | submission | 有无投稿须知 / LaTeX 模板、文档类、参考文献格式、字数页数上限、稿件类型、文件与图片格式 |
| `open_access` | doaj / openalex / fqb | OA 与 APC，含**逐年 APC 美元价格** |
| `subjects_topics` `crossref_quality` `wikidata_meta` `preservation` | — | 未变 |
| **`provenance`** | unified / 行级 | `source_count` / 源清单 / `built_at` / `partial` / `degraded_sources` |

⚠️ **`reviews` 只存聚合，不存 `comments.recent` 的单条评论正文**：20 条正文 × 28 万话题会让
`discourse_journals_data` 爆量，单条评论属于 `docs/comments-sync-plan.md` 那条独立管线。

⚠️ **升级代价**：新增分区让归一化 JSON 增大约 17–20%（每话题 +3～4 KB），且**全量话题的 MD5 都会变**
→ 升级后的第一次「应用」会把所有话题判定为 `content_changed`，触发一次全量 `updated_at` 更新 +
搜索重索引。这是一次性的，但要挑低峰期跑。

---

## 后台工作流与路由

管理页（`admin.adminPlugins → discourse-journals`）驱动整条流水线，通过 4 个 MessageBus 频道实时进度 + `GET status` 轮询恢复（刷新页面不丢状态）。

- `POST /admin/journals/mapping/analyze|pause|restart` · `GET /admin/journals/mapping/status|details`
- `POST /admin/journals/mapping/apply|apply_pause|apply_resume` · `GET /admin/journals/mapping/apply_status`
- `GET /admin/journals/promo_stats` · `DELETE /admin/journals/delete_all`
- `POST /journals/promo/track`（**公开、匿名**，白名单 + 每 IP 120 次/分限流，用于推广位曝光/点击埋点，按「天 × slide」聚合无 PII）
- `GET /journals/:api_id/submission/:kind`（`kind` ∈ `guideline|latex`，**公开、匿名**，每 IP 30 次/分限流，
  ≤25 MB）。上游这两个下载地址在 `/api/open` 下、需要 `X-API-Key`，浏览器 `<a download>` 直连必然 401，
  因此由服务端带密钥取回后转发 —— 这也是上游文档给出的推荐做法。可用
  `discourse_journals_submission_proxy_enabled` 关掉（关掉后档案页不再渲染下载链接）。

Jobs：`AnalyzeMapping`、`ApplyMapping`（`retry: 0`）、`DeleteAllJournals`。
MessageBus 频道：`/journals/mapping`、`/journals/mapping-apply`、`/journals/delete`。

---

## 前端展示（期刊话题页）

- `MasterRecordRenderer` 输出的档案页：hero（封面图，加载失败时纯 CSS 露出首字母兜底图）、JCR/SJR/中科院/新锐分区可视化、指标图表（服务端内联 SVG，图/表用 CSS checkbox 切换，cooked 内零 JS）。
- 契约 v4 之后新增三块：**投稿体验**（`dj-review-exp`：星级 + 5 维评分条 + 录用/拒稿率 + 正负向标签）、
  **标准化指标与分级**（`dj-normalized-metrics`：CWTS SNIP/IPP + JUFO 三国等级）、
  **投稿须知与模板**（`dj-submission-panel`：存在性 + 格式要求 + 代理下载链接）；图表区多一条 SNIP 趋势线。
  存量话题在重新同步前仍带旧的 `scirev` 块，`render_legacy_peer_review` 负责兜底渲染。
- 三个 connector：帖子流上方期刊搜索框、右侧导航区的章节 TOC + 推广轮播、导航底部「相关期刊」卡片（服务端 `JournalSuggestedProvider` 按 tags×3 + publisher×2 + country×1 打分，缓存 30 分钟）。
- SEO：title 后缀、meta description/keywords、schema.org `Periodical` JSON-LD（有投稿体验数据时附
  `aggregateRating`）；期刊页服务端注入 CSS 隐藏 sidebar。

---

## 目录结构

```
app/
  models/discourse_journals/       mapping_analysis.rb（三阶段状态机）· promo_stat.rb
  controllers/discourse_journals/  admin_mapping_controller.rb · promo_controller.rb ·
                                   submission_controller.rb（投稿须知/模板下载代理）
  services/discourse_journals/     api_client（唯一出网口，负责鉴权/重试/限流）· title_matcher ·
                                   api_data_transformer · field_normalizer ·
                                   journal_upserter · journal_tag_manager · mapping_applier ·
                                   master_record_renderer · svg_chart_builder ·
                                   journal_seo_context · journal_suggested_provider ·
                                   outdated_marker · bulk_topic_deleter ·
                                   api_rate_limiter · performance_logger · topic_title_key_backfill
  jobs/regular/discourse_journals/ analyze_mapping · apply_mapping · delete_all_journals
assets/javascripts/discourse/      admin controller/template · connectors · components · initializers
assets/stylesheets/common/         discourse-journals.scss（档案页）· discourse-journals-admin.scss（后台）
config/                            settings.yml · locales/{client,server}.{en,zh_CN}.yml
db/migrate · db/post_migrate       mapping_analyses / promo_stats 表与部分索引
lib/tasks/                         discourse_journals:backfill_normalized_title_keys
```

---

## 开发注意

- 上游 API（契约 v1 / 文档版本 4.0，见 `<base_url>/api-docs/`），**每个请求都带 `X-API-Key`**，统一走 `ApiClient`：
  - 分析期全量：`GET /api/open/journals?pageSize=2000&fields=id,canonical_name,issn_l&afterId=<cursor>`。
    pageSize 上限已从 100 提到 2000，`fields=` 再把单页从 ~2.9 MB 压到 ~1 MB；`afterId` 游标不受深分页上限约束。
  - 应用期批量详情：`GET /api/open/journals?ids=…&full=1&resolveIds=follow`（每批 50 个 id，selector 上限 200）。
    **`/api/open/journals/byIds` 已下线（410 `endpoint_gone`）**，这是它的官方后继写法。
  - `resolveIds=follow` 的响应带 `redirects`（`{旧id: 新id|null}`）：合并的 id 会被 `MappingApplier#absorb_redirects!`
    重新指向原话题（避免重复建帖），被删除的 id 则走 `OutdatedMarker` 打过时标记。
- 大量写库刻意绕过 AR 回调（`PostCreator(skip_validations, skip_jobs)`、`update_columns`、`insert_all`/`delete_all`）换吞吐；tag 计数与分类计数分别由 `reconcile_counts!` / `update_category_stats` 手工补一致性。
- 管理员手工给期刊话题加的 tag 会在下次同步被清掉（tag 是全量替换语义）。
- `rake discourse_journals:backfill_normalized_title_keys` 为存量话题回填标题匹配键；改动 `TitleMatcher.normalized_title_key` 算法后必须重跑，否则匹配会 miss。
