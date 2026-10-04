# 📚 Discourse Journals Plugin

学术期刊统一档案系统 —— 把上游期刊数据库（`journal.scholay.com` 的开放 API）镜像为 Discourse 某个分类下的话题：**一本期刊 = 一个话题**，首帖是服务端渲染的结构化期刊档案页，并叠加 SEO 增强与顶部推广横幅。

> ⚠️ 本插件为 scholay 站点定制，面向单一中文站运行；后台进度/错误文案目前为硬编码中文。

---

## 核心概念（先读这三条）

1. **数据真理源是 custom field，不是帖子 raw。** 每本期刊的归一化 JSON 存在话题 custom field `discourse_journals_data` 里；首帖 cooked HTML 由 `MasterRecordRenderer` 从该 JSON 渲染后用 `update_columns` **直写 cooked**，完全绕过 markdown/sanitize 管线（因为页面含 `<svg>`、CSS checkbox 切换等会被 sanitizer 剥掉的结构）。帖子 raw 只是一行纯文本占位。任何 rebake 都会触发 `before_post_process_cooked` 钩子从 JSON 重新渲染自愈。
   - 含义：XSS 防护完全依赖渲染器自身的 `h()`（HTML escape）纪律，core 的 sanitize 不再兜底——改渲染器时务必保持转义。

2. **同步 = 后台三阶段流水线，状态存单表 `discourse_journals_mapping_analyses`（一行，三个独立 enum 状态机）。**
   - **分析（Analyze）** `Jobs::DiscourseJournals::AnalyzeMapping` → `TitleMatcher`：游标分页拉取 API 全量 + 扫描论坛全量，按 **ISSN-L → api_id → 归一化标题** 三级交叉匹配，产出 6 个桶（`exact_1to1` / `forum_1_to_api_n` / `forum_n_to_api_1` / `forum_n_to_api_m` / `forum_only` / `api_only`）与一份完整 `_action_plan`（updates / creates / deletes / merges）。
     另有 `duplicates` 桶：存着同一个 `discourse_journals_api_id` 的多个话题是同一条上游记录的副本（2026-09-03 曾有 2～3 个应用任务并发运行，每条记录各建了 2～3 个话题）。分析时只保留最早的那个参与匹配，其余列进 merges，后台显示为「重复话题」。
   - **应用（Apply）** `Jobs::DiscourseJournals::ApplyMapping` → `MappingApplier`：先把「论坛有、API 没有」的话题**软删除**（标过时，不是硬删），再流水线拉详情（每请求 50 id × 4 并发 + 预取）、4 线程 transform、并行 upsert，写话题/custom fields/tags。每批落 `apply_checkpoint`，支持暂停 / 失败 / 进程崩溃后**断点续传**。收尾 `reconcile_counts!` 重算 tag 计数。
   - **同一时间只能有一个应用任务**（`ApplyLock`，Redis 租约 5 分钟）。任务运行期间后台线程每分钟续约并刷新心跳（只改 `apply_checkpoint.heartbeat`），所以慢批次不会再被误判为中断；第二个任务直接退出，后台的「应用」「继续」在锁被占用时拒绝。进程崩溃后租约自然过期，5 分钟无心跳即可「继续」。
   - 应用的第 0 步合并 `merges`：副本话题被移入回收站（不是标过时，因为期刊仍在上游），并建 permalink，旧网址 301 到保留的话题（`DuplicateTopicMerger`；slug 已是百分号编码，建 permalink 时先解码，避免被二次编码）。
   - 新建前按 ISSN-L → `api_id` → 归一化标题查已有话题；同名有歧义时也能靠 `api_id` 找到原话题，不会再多建一份。
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
| `discourse_journals_cover_sync_rate_limit` | 20 | 封面同步的每秒请求数上限（每本刊一次轻量 HEAD，可比上一项快；上限 100） |
| `discourse_journals_submission_proxy_enabled` | true | 由论坛代理下载投稿须知 / LaTeX 模板（上游这两个地址要密钥，浏览器发不出请求头） |
| `discourse_journals_title_suffix` | 期刊详情 \| … | SEO 标题关键词，插在期刊名之后、分类与站名之前（仅 HTML title），如 `Nature - 影响因子·分区·ISSN - 学术期刊 - 恩特学术` |
| `discourse_journals_meta_description` / `_meta_keywords` | 模板 | meta 模板，占位符 `{{title}}/{{issn}}/{{publisher}}/{{category}}/{{tags}}/{{site_name}}`；description 另有 `{{summary}}`（`JournalSummary` 按影响因子/分区、ISSN/出版商、开放获取、发文/被引、研究方向自动成句，最长 160 字） |
| `discourse_journals_indexnow_enabled` | false | 同步新建或内容变化的期刊入 Redis 队列，`SubmitIndexNow` 每 30 分钟批量推给 IndexNow（Bing/Yandex 等）；验证文件 `/<key>.txt`，key 由站点密钥派生 |
| `discourse_journals_close_topics` | true | upsert 后关闭话题 |
| `discourse_journals_suggested_mode` / `_criteria` / `_count` | custom_first / `tags\|publisher` / 5 | 「相关期刊」推荐 |
| `discourse_journals_performance_logging` | false | 结构化性能日志（`PerformanceLogger`） |
| `discourse_journals_major_publishers` | 20 家 | 仅这些出版商的期刊打 publisher tag |

---

## 话题 custom fields

真理源 `discourse_journals_data`（归一化 JSON）。匹配键：`discourse_journals_issn_l`、`discourse_journals_api_id`、`discourse_journals_normalized_title_key`（前两者有 `topic_custom_fields` 部分索引）。其余：`discourse_journals_publisher`、`discourse_journals_country`、`discourse_journals_cover_url`（上游封面的**绝对**地址 `…/api/covers/preview/{id}.webp?v={content_hash}`，相关期刊卡片与 og:image 读它；JSON 里的 `identity.cover_url` 存同一地址的相对路径，档案页 hero 读它）、`discourse_journals_outdated`（软删标记，值为 ISO8601 时间）。

> 旧封面子系统（2026-07 删除代码）留下的 `discourse_journals_cover_url_hash` 指纹与 `topics.image_upload_id`
> 本地封面图，由「封面同步」在处理到对应话题时自动清理，见下文。

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
- `POST /admin/journals/covers/sync|pause|resume` · `GET /admin/journals/covers/status`（封面同步，见下节）
- `GET /admin/journals/promo_stats` · `DELETE /admin/journals/delete_all`
- `POST /journals/promo/track`（**公开、匿名**，白名单 + 每 IP 120 次/分限流，用于顶部横幅曝光/点击埋点，按「天 × slide」聚合无 PII；当前唯一合法 slide 是 `banner`）。
  前端用 `navigator.sendBeacon` 发送：该端点不校验 CSRF，而 Discourse 的 `ajax()` 会先取一次 `/session/csrf`，曾让每次曝光变成两个请求。
- `GET /journals/search?q=`（**公开、匿名**，每 IP 60 次/分限流）：期刊页搜索框的下拉结果。按 ISSN-L 精确匹配 + 标题按词
  子串匹配（`idx_dj_topics_title_trgm` trigram 索引，毫秒级），最多 8 条。不走 core 全文搜索——在几十万期刊帖子上它要数秒、
  宽泛词要二三十秒，期间占住一个 web 进程。回车 / 「更多结果」仍跳 core 完整搜索页。
- `GET /journals/:api_id/submission/:kind`（`kind` ∈ `guideline|latex`，**公开、匿名**，每 IP 30 次/分限流，
  ≤25 MB）。上游这两个下载地址在 `/api/open` 下、需要 `X-API-Key`，浏览器 `<a download>` 直连必然 401，
  因此由服务端带密钥取回后转发 —— 这也是上游文档给出的推荐做法。可用
  `discourse_journals_submission_proxy_enabled` 关掉（关掉后档案页不再渲染下载链接）。

Jobs：`AnalyzeMapping`、`ApplyMapping`（`retry: 0`）、`DeleteAllJournals`、`SyncCovers`（`retry: 0`）。
MessageBus 频道：`/journals/mapping`、`/journals/mapping-apply`、`/journals/delete`、`/journals/cover-sync`。

---

## 封面同步（独立于「分析 → 应用」）

后台「封面同步」区块（`JournalsCoverSync` 组件）单独触发，不走分析/应用流水线，状态存独立表
`discourse_journals_cover_syncs`（**不能**挂在 `mapping_analyses` 上——analyze/restart 会清空那张表，旧封面子系统正是因此烂尾）。

- **为什么逐本 HEAD**：上游没有任何「按有无封面筛选」的手段（`fields=cover`、`hasSources=cover` 报 400，`hasCover` 被静默忽略），
  只能对匿名端点 `HEAD /api/covers/preview/{api_id}.webp` 逐本探测：200 带 `ETag`（= `content_hash` = `preview_url` 的 `v`）、
  304（带了 `If-None-Match` 且未变）、404 没封面、301 已合并（跟随到新 id）、410 已删除、**503 封面存储整体不可用（立即中止，绝不当作「没封面」）**。
  preview 地址由 HEAD 结果拼出，与 `full=1` 行里官方的 `cover.preview_url` 逐字相同（已实测）。
- **候选集**：有 `api_id`，且有 ISSN（issn_l 或 JSON 里任何 ISSN）或已存封面。上游封面按 ISSN 关联，完全没有 ISSN 的刊永远不会有封面。
- **每个话题的处理**（`CoverSyncer` → `TopicCoverApplier` / `LocalCoverPurger`）：
  - 上游有封面 → 写 JSON `identity.cover_url` + cf + 重渲染首帖，并**删除本地旧封面**（`image_upload_id`、首帖引用、upload 本身；被多个话题共用的 upload 等最后一个引用解除再删）；
  - 上游没有 → 清掉已存的上游/旧格式地址，回落默认；**本地默认封面保留**；
  - 探测出错 → 该话题不动；整批全部失败 → 中止（可继续）。
  - 每批顺带清掉旧封面系统的垃圾：指向已不存在 upload 的 `image_upload_id`（core 的孤儿清理只看 `upload_references`，不看它）与旧指纹 cf。
- 封面真变化才动 `updated_at`；不 bump、不重建搜索索引。JSON 形状不变（`cover_original_url` 键保留为 nil），避免全量 MD5 变化。
- 按话题 id keyset 分批（500/批），每批落 checkpoint + 心跳，支持暂停 / 失败 / 进程被杀（15 分钟无心跳）后断点续传。
- 与「应用映射」「删除全部」互斥（controller 双向检查 + job 内再查）。全量同步写入的封面走同一套规则：读 `preview_url`；
  上游封面查询降级（`degraded_sources` 含 `cover`）时沿用已存封面；写入上游封面后同样删除本地旧封面。
- 规模：本站约 18 万本候选，按 ~20 req/s 一轮约 2–3 小时；可调 `discourse_journals_cover_sync_rate_limit`。

---

## 前端展示（期刊话题页）

- 封面优先级：**上游封面 > 本地默认封面 > 首字母占位**。档案页 hero 只用上游封面（加载失败时纯 CSS 露出首字母兜底图）；
  相关期刊卡片与 og:image / twitter:image / JSON-LD image 优先上游封面，其次本地默认封面（og:image 由 `TopicViewCoverPatch` 处理）。
- `MasterRecordRenderer` 输出的档案页：hero（封面图，加载失败时纯 CSS 露出首字母兜底图）、JCR/SJR/中科院/新锐分区可视化、指标图表（服务端内联 SVG，图/表用 CSS checkbox 切换，cooked 内零 JS）。
- 契约 v4 之后新增三块：**投稿体验**（`dj-review-exp`：星级 + 5 维评分条 + 录用/拒稿率 + 正负向标签）、
  **标准化指标与分级**（`dj-normalized-metrics`：CWTS SNIP/IPP + JUFO 三国等级）、
  **投稿须知与模板**（`dj-submission-panel`：存在性 + 格式要求 + 代理下载链接）；图表区多一条 SNIP 趋势线。
  存量话题在重新同步前仍带旧的 `scirev` 块，`render_legacy_peer_review` 负责兜底渲染。
- 三个 connector：帖子流上方期刊搜索框、右侧导航区的章节 TOC、导航底部「相关期刊」卡片（服务端 `JournalSuggestedProvider` 按 tags×3 + publisher×2 + country×1 打分，缓存 30 分钟）。
- 期刊话题默认全部关闭（`discourse_journals_close_topics`），而 core 的随机推荐只取未关闭话题，期刊分类的随机池因此恒为空、
  core 永远缓存不上，每次打开期刊页都会对 `topics` 全表做一次 `ORDER BY RANDOM()`（线上 36 万期刊时约 60ms、3 个进程）。
  `RandomTopicSelectorPatch` 在话题关闭时对期刊分类直接返回空，全站随机推荐照常补位。
  站内推广只剩全站头部下方的 `below-site-header/scholay-banner`（`discourse_journals_banner_enabled` 控制）；右侧导航区那个轮播广告已移除。
- SEO：title 关键词、meta description/keywords、schema.org `Periodical` JSON-LD（有投稿体验数据时附
  `aggregateRating`）；期刊页服务端注入 CSS 隐藏 sidebar。
  爬虫看不到前端的「相关期刊」卡片，所以 crawler 视图在帖子后服务端输出 12 个相关期刊链接（`RelatedJournalLinks`，复用推荐打分，缓存 1 天），
  否则期刊页之间没有互链，只能靠 sitemap 被发现。robots.txt 对所有爬虫组禁止 core 的浏览统计信标 `/srv/pv`、`/pageview`
  （渲染期刊页的爬虫会触发它们，曾占 Googlebot 约三成抓取）。

---

## 目录结构

```
app/
  models/discourse_journals/       mapping_analysis.rb（三阶段状态机）· promo_stat.rb ·
                                   cover_sync.rb（封面同步状态）
  controllers/discourse_journals/  admin_mapping_controller.rb · admin_covers_controller.rb ·
                                   promo_controller.rb · submission_controller.rb（投稿须知/模板下载代理） ·
                                   index_now_controller.rb（IndexNow 验证文件）
  services/discourse_journals/     api_client（唯一出网口，负责鉴权/重试/限流）· title_matcher ·
                                   api_data_transformer · field_normalizer ·
                                   journal_upserter · journal_tag_manager · mapping_applier ·
                                   master_record_renderer · svg_chart_builder ·
                                   journal_seo_context · journal_suggested_provider ·
                                   outdated_marker · bulk_topic_deleter · duplicate_topic_merger · apply_lock ·
                                   api_rate_limiter · performance_logger · topic_title_key_backfill ·
                                   cover_url · cover_syncer · topic_cover_applier · local_cover_purger ·
                                   journal_summary · related_journal_links · index_now
  jobs/regular/discourse_journals/ analyze_mapping · apply_mapping · delete_all_journals · sync_covers
  jobs/scheduled/discourse_journals/ submit_index_now
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
  - 封面：`full=1` 行的 `cover.preview_url`（相对路径，匿名可直接 `<img src>`）；`cover.cover_url` 是废弃别名，旧的按刊名寻址
    `/api/covers/image/{刊名}` 已下线（现返回 401）。封面同步用 `HEAD /api/covers/preview/{id}.webp`，详见「封面同步」一节。
- 大量写库刻意绕过 AR 回调（`PostCreator(skip_validations, skip_jobs)`、`update_columns`、`insert_all`/`delete_all`）换吞吐；tag 计数与分类计数分别由 `reconcile_counts!` / `update_category_stats` 手工补一致性。
- 管理员手工给期刊话题加的 tag 会在下次同步被清掉（tag 是全量替换语义）。
- `rake discourse_journals:backfill_normalized_title_keys` 为存量话题回填标题匹配键；改动 `TitleMatcher.normalized_title_key` 算法后必须重跑，否则匹配会 miss。
