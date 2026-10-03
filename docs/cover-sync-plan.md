# 期刊封面同步方案（已拍板 · 已实现）

> 背景：上游封面接口已改版——旧的按刊名寻址 `/api/covers/image/{刊名}` 已下线，改为按稳定 id 寻址的
> `/api/covers/preview/{id}.webp`，插件现有的封面链路全部失效。本稿设计一个**独立于「分析 → 应用」的封面同步子系统**。
>
> 结论均经实测或源码取证（标注 文件:行号；core = 本仓库 main；上游 = `craw_journals` 仓库）。
> 数据取自本机 Docker `app` 容器（2026-10-03）。状态：2026-10-03 按 §6 拍板结论实现，运行说明见 README「封面同步」一节；
> 本文其余部分保留调研时的取证与推导。

---

## 0. 需求

1. 适配上游新封面接口。
2. 后台单独提供「只同步封面」操作，与期刊整体同步（分析 → 应用）分开、可独立触发。
3. 上游有封面 → 用上游的，**删除本地封面**；上游没有 → 维持我们的默认（本地默认封面 / 首字母占位）。

---

## 1. 上游 API 事实（已实测）

### 1.1 `cover` 对象（只出现在 `full=1` 行里）

```json
"cover": {
  "preview_url": "/api/covers/preview/1.webp?v=a855e4f0a5126ab1",
  "download_url": "/api/covers/download/1.webp?v=a855e4f0a5126ab1",
  "cover_url": "/api/covers/preview/1.webp?v=a855e4f0a5126ab1",
  "format": "webp", "width": 288, "height": 384, "bytes": 12824,
  "content_hash": "a855e4f0a5126ab1", "updated_at": "2026-09-09T04:35:48.000Z"
}
```

- 地址是**相对路径**。`cover_url` 是 `preview_url` 的**废弃别名**（文档："将来会移除"）；旧字段 `original_url` 已不存在。
- 没有封面时 `cover: null` 是常态；但 `partial: true` 且 `degraded_sources` 含 `cover` 时，`null` 表示**查询降级**，不是"没有封面"。
- `download_url` 需要 API key，页面展示一律用 `preview_url`。

### 1.2 封面端点 `GET|HEAD /api/covers/preview/{id}.webp`

匿名可达，可直接作 `<img src>`，支持 HEAD。实测：

| 情形 | 状态 | 说明 |
|---|---|---|
| 有封面 | 200 | `ETag: "<content_hash>"`、`Content-Length`；带匹配的 `?v=` 时一年 immutable 缓存，不带为 `max-age=300` |
| `If-None-Match` 命中 | 304 | — |
| 没封面 / 没这个 id | 404 | HEAD 无响应体，**分不清** `not_found` 与 `journal_not_found`——对我们等价 |
| id 已合并 | 301 | `Location: /api/covers/preview/{新id}.webp`（不带 `v`） |
| id 已删除 | 410 | — |
| 封面存储整体不可用 | 503 | `storage_unavailable`：**必须中止**，绝不能当作"没封面" |

`ETag` = `content_hash` = `preview_url` 上的 `v`（文档写明；实测 id=1 三者一致）。

### 1.3 没有任何"按有无封面筛选"的手段

- `fields=id,cover` → 400 `invalid_param`；`hasSources=cover` → 400 `unknown_source`。
- `hasCover=1` / `has_cover=1` 被**静默忽略**（与不带参数的结果逐条相同）；`/api/open/meta` 无封面统计。
- 结论：要知道哪本刊有封面，只能 ① 拉 `full=1` 行（50 本 1.3–3.5 MB），或 ② 逐本 HEAD。

### 1.4 覆盖率与变化节奏

- 文档称约 3%（10,000 / 329,090）；抽样显示可能更高（见 §2.3），以实跑为准。
- 封面**按 ISSN** 关联：上游 `journal_cover_images` 以 ISSN 为主键（2026-09-24 迁移），读取时按 live ISSN 归属映射到
  unified id（`src/server/services/UnifiedDetailFetcher.ts` 的 `lookupCoverRows`）。**完全没有 ISSN 的刊永远不会有封面**（上游文档原话）。
- 封面由运维用 `scripts/import_covers.ts` 分批导入 → 覆盖率会持续增长 → 封面同步必须**可重复执行**、对增量友好。

### 1.5 性能与限流

- HEAD 单连接 keep-alive 约 185–250 ms/次（本机 Docker → 线上，RTT 主导）。
- 上游对外限流默认关闭（`src/server/index.ts` 注释："内部服务、调用方可控"），`/api/covers` 路由没有限流器。
- 旧地址 `/api/covers/image/{刊名}` 现返回 **401**——浏览器里就是破图。

---

## 2. 插件现状（代码 + 本机数据取证）

### 2.1 封面在代码里的流向

| 环节 | 现状 | 问题 |
|---|---|---|
| `ApiDataTransformer`（api_data_transformer.rb:15） | 透传 `row["cover"]` | — |
| `FieldNormalizer#build_identity`（field_normalizer.rb:95-96） | 读 `cover[:cover_url]` / `cover[:original_url]` | 前者已废弃，后者已不存在 |
| `JournalUpserter#store_custom_fields!`（journal_upserter.rb:176-177、227-232） | 写 cf `discourse_journals_cover_url`（绝对 URL），无封面时删除 | 不区分"降级"与"没有"；从不碰本地 upload |
| `MasterRecordRenderer#render_hero`（master_record_renderer.rb:150-172） | `api_base_url + cover_url` 叠在首字母底图上，加载失败由 CSS 兜底 | 相对路径可用 |
| 相关期刊卡片（journal-suggested.gjs:74-86、plugin.rb:205-211） | **本地 upload 优先**，再用 cf | 与"上游优先"相反 |
| og:image / JSON-LD image | core `TopicView#image_url`：`topic.image_url`（本地 upload）→ 生成的 OG 图 → 站点默认（core lib/topic_view.rb:462-468） | 删除本地 upload 后退回站点默认图 |

### 2.2 旧封面子系统的遗留（946291e，2026-07-08 删代码、留数据）

旧 `TopicCoverManager`：上游有图就下载，没有就用 `CoverImageGenerator` 生成 900×1200 PNG → `UploadCreator` →
写 `topics.image_upload_id` + 首帖 `image_upload_id` + `UploadReference(Post)` + 指纹 cf `discourse_journals_cover_url_hash`。
**这些就是需求里要删的"本地封面"。**

`mapping_analyses` 上的 `cover_status` / `cover_stats` 两列**不能复用**：analyze / restart 会 `delete_all` 整表
（admin_mapping_controller.rb:18、82），旧子系统正是因此烂尾（见 comments-sync-plan.md §9）。

### 2.3 本机数据（分类 6）

| 项 | 数量 |
|---|---|
| 存活期刊话题 | 342,436 |
| 有 `discourse_journals_api_id` | 322,875（19,561 个过时话题没有） |
| 有 api_id 但无 issn_l | 145,424（抽 3,000 个：约 3% 仍有 print/electronic ISSN 或 issn_details） |
| `topics.image_upload_id` 非空 | 316,272 |
| ├ upload 真实存在 | **545**（全是旧生成器的 900×1200 PNG，共 33 MB；58 个被多个话题共享——sha1 去重） |
| └ 悬空（upload 已不存在） | **315,727** |
| cf `discourse_journals_cover_url`（旧 `/api/covers/image/…`，现 401） | 20,534 |
| cf `discourse_journals_cover_url_hash`（旧指纹） | 316,272 |

悬空原因：core `CleanUpUploads` 只看 `upload_references`，不看 `topics.image_upload_id`
（app/jobs/scheduled/clean_up_uploads.rb:47-48）；首帖侧引用一旦消失，upload 就被当孤儿回收。
`clean_up_uploads` 默认开启，**生产很可能同样如此**——上线前用附录 SQL 在生产核实。

抽样探测：
- 有真实本地 upload 的 493 个话题（有 api_id）：上游有封面的仅 **1** 个 → 本机只会删 1 个本地封面。
- 旧 URL 话题随机 400 个：**325（81%）**上游已有新封面；75（19%）已没有（目前前台是破图）。

其他：
- 主题组件 Topic List Thumbnails 已启用，但只配置了分类 1–4，期刊分类不受影响。
- core 默认 CSP 不设 `img-src`（lib/content_security_policy/default.rb），热链上游图片可行——hero 现在就是热链。

---

## 3. 目标语义

展示优先级：**上游封面 > 本地默认封面 > 首字母占位**。

| 上游结果 | 动作 |
|---|---|
| 200 有封面 | JSON `identity.cover_url` ← preview 路径；cf ← 绝对 URL；重渲染首帖；**删除本地封面** |
| 304 未变 | 不动（仅确保本地封面已删） |
| 404 / 410 | 若存着上游封面（含旧格式 URL）则清掉 → 回落默认；**本地 upload 不动** |
| 301 已合并 | 跟随到新 id，按新 id 的结果处理，存新 id 的地址；api_id 重指向留给全量同步 |
| 401 / 503 / 5xx / 网络错误 | 什么都不改；401、503 中止本次运行（可恢复） |
| 全量同步行的 `degraded_sources` 含 `cover` | 保留现有封面（修复现有 bug） |

"删除本地封面"步骤：
1. `topics.image_upload_id` 置空；首帖 `image_upload_id` 若相同也置空。
2. 删 `UploadReference(upload, 首帖)`；删 cf `discourse_journals_cover_url_hash`。
3. 若该 upload 已无任何引用（upload_references / topics / posts）→ 删 `topic_thumbnails` 行 + `Upload#destroy`（连文件与优化图）；
   共享的 upload 等最后一个引用解除时再删。悬空 id 只做第 1 步。

---

## 4. 架构

### 4.1 共享层：封面规则只写一处

- `CoverRef`（值对象）：从 `cover` 对象或 HEAD 结果得出 preview 相对路径、版本号 `v`、绝对 URL。
- `LocalCoverPurger`：§3 的删除步骤。
- `TopicCoverApplier`（封面同步用）：只改 JSON 的 `identity.cover_url` → 从新 JSON 重渲染 cooked（尊重过时标记）→ 写 cf → 调 purger。
  封面真变化时才动 `updated_at`；不 bump；不重建搜索索引（封面不进索引）。
- **JSON 形状不变**：保留 `cover_original_url` 键（恒为 nil）。删掉它会让 34 万条 JSON 的 MD5 全变，
  下次「应用」全量判 `content_changed`（README「升级代价」那一类事故）。

### 4.2 全量同步的最小改动

- normalizer 经 `CoverRef` 读 `preview_url`；`cover_original_url` 恒为 nil。
- `degraded_sources` 含 `cover` 时沿用已存封面。
- upserter 写入上游封面后调 `LocalCoverPurger`。

### 4.3 独立封面同步子系统（沿用 comments-sync-plan.md §9 的骨架）

- **表** `discourse_journals_cover_syncs`（单活跃行）：`user_id`、`status`（pending / processing / completed / failed / paused）、
  `total`、`checkpoint jsonb {last_topic_id, heartbeat}`、`stats jsonb`、`error_message`、`started_at`、`completed_at`。
- **Job** `Jobs::DiscourseJournals::SyncCovers`（`retry: 0`、`queue: "low"`）：cancel_check + PausedError + 断点续传，心跳判活沿用 15 分钟。
- **批处理**：按 topic id keyset 每批 500：SQL 取 api_id / image_upload_id / 已存封面 / ISSN 情况 →
  8 线程 keep-alive HEAD（共享限流器）→ 逐个应用 → 存 checkpoint + MessageBus 进度。
- **候选集**：有 api_id，且（有 issn_l，或 JSON 里有任何 ISSN，或已存封面）——约 18 万，而不是 32 万。
- **增量**：已存新格式封面的带 `If-None-Match: "<v>"`，未变即 304。
- **`ApiClient#probe_cover(api_id, etag:)`**：HEAD、带 key（便于上游计量）、复用 429 / 重连策略，返回结构化结果。
- **preview 路径由 HEAD 结果拼出**：`/api/covers/preview/{id}.webp?v={ETag}`，与上游 `preview_url` 逐字相同（§1.2）。
  首轮省掉约 1 万本 × ~70 KB 的 `full=1` 负载。上游文档建议"正常情况下不要自行拼接"，见决策点 G。
- **互斥**：apply ⟷ 封面同步 ⟷ delete_all，controller 双向检查 + job 内再检查。
- **路由**：`POST /admin/journals/covers/sync|pause|resume`、`GET /admin/journals/covers/status`（`AdminConstraint`）。
- **后台界面**：「应用映射」之后新增一个区块：说明、上次结果、开始 / 暂停 / 恢复、进度条 + ETA、统计
  （已探测 / 新增或更新 / 未变 / 回落默认 / 删除本地封面 / 跳过 / 错误）。文案进 client.en / client.zh_CN。
- **MessageBus**：`/journals/cover-sync`。

### 4.4 展示调整

- og:image / JSON-LD：在 `reloadable_patch` 里 prepend `TopicView#image_url`，期刊话题有上游封面时返回它。
- 相关期刊卡片：服务端序列化与 gjs 都改成上游优先。

---

## 5. 规模估算

| | 请求数 | ~35 req/s | 5 req/s（现有默认限速） |
|---|---|---|---|
| 每次运行 | ~18 万 HEAD + 封面有变化的话题写库（首轮约 1–2 万） | ~1.5 小时 | ~10 小时 |

每轮请求数都一样（上游没有封面清单可做增量），304 只省响应处理、不省请求数——见决策点 E。

---

## 6. 决策点（已拍板）

A、B、C、D、E、G 按下表建议执行（E 留作后续）。**F 改为：不另做一次性清理，旧数据的删除由封面同步在处理到每个话题时自动完成**
（悬空 `image_upload_id` 与旧指纹按批清掉；上游有封面的话题删除本地旧封面并替换）。两个废列 `cover_status` / `cover_stats` 未动。

| # | 问题 | 建议 |
|---|---|---|
| A | 全量同步是否继续写封面 | **是**，经共享层。`full=1` 行自带封面，新刊立刻有图，且与封面同步结果一致。否则全量同步要么把封面写坏，要么得把"沿用旧值"耦合进去 |
| B | 上游封面热链，还是下载成本地 upload | **热链**。上游专为 `<img src>` 设计（匿名 + 带版本号长缓存）；下载等于复活已删的旧子系统，也与"删除本地"矛盾 |
| C | og:image 是否改用上游封面 | **是**。否则删除本地封面后分享图退回站点默认 |
| D | 限速 | 新增 `discourse_journals_cover_sync_rate_limit`（默认 20，上限 100）。HEAD 很轻，不该和全量同步共用 5 req/s |
| E | 上游是否补一个封面清单接口 | **建议后续做**：craw_journals 加 `GET /api/open/covers?afterId=&since=`（id + content_hash + updated_at，约 1 万行），封面同步从 ~18 万次请求降到个位数；插件侧发现步骤可替换 |
| F | 是否顺手清理遗留数据（31.5 万悬空 `image_upload_id`、31.6 万旧指纹 cf、两列废列） | **不混进本次**，另做一次性 post_migrate / rake |
| G | preview 路径自行拼接，还是再拉 `full=1` 取官方值 | **拼接**（ETag = content_hash 文档写明且实测一致）。若不拼，首轮多约 200 次 `full=1` 请求（数百 MB） |

---

## 7. 实施阶段

1. 共享层 + 全量同步修正（normalizer / upserter / 降级沿用）+ specs。
2. 封面同步子系统：迁移、模型、`ApiClient#probe_cover`、job、controller、路由、后台区块、i18n + specs。
3. 展示调整：og:image patch、卡片优先级。
4. 本机 Docker 验证：`docker cp` + `db:migrate` + `sv restart unicorn`（前端改动需在容器里 `assets:precompile`）；
   先小批量（api_id ≤ 2000）再全量；逐项核对 hero、卡片、og:image、本地封面删除、暂停 / 恢复、与 apply 互斥。
5. README 更新（路由、job、频道、表、设置）。

---

## 附录：上线前在生产跑的只读统计

```sql
-- 把 6 换成生产的 discourse_journals_category_id
SELECT count(*) FILTER (WHERE t.image_upload_id IS NOT NULL)                AS with_image_upload_id,
       count(*) FILTER (WHERE t.image_upload_id IS NOT NULL AND u.id IS NULL) AS dangling,
       count(u.id)                                                          AS existing_uploads
FROM topics t
LEFT JOIN uploads u ON u.id = t.image_upload_id
WHERE t.category_id = 6 AND t.deleted_at IS NULL;

SELECT name, count(*)
FROM topic_custom_fields
WHERE name IN ('discourse_journals_cover_url', 'discourse_journals_cover_url_hash', 'discourse_journals_api_id')
GROUP BY name;
```
