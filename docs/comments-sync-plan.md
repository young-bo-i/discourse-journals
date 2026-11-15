# 期刊评论同步方案（收录账号版）

> 目标：把上游收录的期刊投稿评论按原始时间写进对应期刊话题的回复区。每条评论一个独立回复，
> 由一个专用的收录账号发布，但每条回复显示自己的匿名作者名；回复末尾用一行备注注明来源、
> 原始时间和原文链接。
>
> 状态（2026-11-15）：测试版已实现——管理页「期刊评论同步」按填写的话题 ID 或前 N 本期刊同步；
> 全量同步、定时增量和暂停/续跑尚未实现。取代旧的「人设池」方案：旧方案用虚构的真人化账号发帖、
> 隐去来源并改写评论日期，已废弃，不实现。

---

## 0. 已定决策

1. 每条上游评论 = 期刊话题下的一个独立回复，话题内按原始时间从旧到新排列。
2. 全部由**一个**收录账号发布，用 core 的 bot 账号机制（负 id，同 `system`、discobot）。
   不新建任何「用户」，不给框架增加用户数据。
3. 每条回复显示自己的匿名作者名（§2.1），只是显示层的名字，背后没有账号；名字不用编造的真人姓名。
4. 回复正文下方一行来源说明：来源站点 · 原始发布时间 · 原文链接（前端渲染，后台可关闭）。
5. 时间用上游原始时间，不改写；精度不足或缺失的在备注里写明（§4）。
6. 上游推断出来的字段（评分、投稿结果、周期）只在上游标为高置信度时展示（§3.2），
   避免读者把估算值当成评论者本人给的。

---

## 1. 上游接口（源码核对 + 2026-11-15 实测）

`GET /api/open/journals/{id}/comments?after=<cursor>&pageSize=<1..100>&status=`
（craw_journals `src/server/routes/open.ts`，`router.get('/journals/:id/comments'`）

- 排序 `published_at_iso DESC, id DESC`，无日期的排最后；keyset 游标：取 `nextCursor`
  原样回传为 `after`，为 `null` 即到底。`pageSize` 上限 100，默认 20。
- `total` 是过滤集全量，不随游标变化。
- 状态码：301 = id 已合并（Location 指向新 id 的 comments URL）；404 = 期刊不存在或无评论
  （`error: no_comments`）；410 = id 已删除；400 `bad_cursor`。
- 单条字段：`record_id`（稳定唯一，幂等键，如 `letpub-comment-664905`）、`source_name`、
  `source_url`、`published_at_iso`（无时区后缀）、`published_at_precision`
  （datetime/date/month/year/unknown/invalid）、`paper_status` 与 `is_accepted/is_rejected/is_desk_reject`、
  `overall/speed/communication/review_quality/cost_rating_0_5`、`difficulty_index_0_5`、
  `first_review_days`、`total_handling_days`、`publication_delay_days`、`review_rounds`、
  `fee_page/fee_review/fee_currency`、`tags`、`confidence{status,time_metrics,rating_metrics}`、
  `comment_text`（原文）、`comment_text_zh`、`comment_text_en`、`original_language`、`publisher_display_name`（不用）。
- 实测样例（Fuel，api_id 988，286 条）：LetPub 评论的 `overall_rating_0_5` 是上游从文本推断的
  （`rating_metrics: low`），LetPub 本身没有评分。→ §3.2 的置信度门槛是必须的。
- 发现与增量：apply 拉取的 `full=1` 行带 `comments` 摘要，已存进期刊 JSON 的
  `reviews.count` / `reviews.latest_at`（FieldNormalizer#build_reviews），无需额外请求。

规模（2026-10 上游快照 `journal_comments/comments.jsonl`）：

| 项 | 数值 |
|---|---|
| 评论 / 有评论的期刊 | 193,505 / 14,329 |
| 每刊条数 | 中位 4，p90 35，最多 3,293 |
| 来源 | 万维书刊网 10.2 万、LetPub 2.0 万、Peeref 2.0 万、MedSci 1.7 万、SciRev 1.3 万、其他约 1 万 |
| 时间精度 | datetime 12.9 万、date 2.6 万、year 1.0 万、month 270、无/无效 2.8 万 |
| 原文语言 | 中文 15.8 万、英文 3.6 万 |

全量请求量 ≈ 每刊 ⌈n/100⌉ 次，约 1.5–1.6 万次，走 `ApiClient` 与现有限流。

---

## 2. 收录账号（bot）

- 用 `db/fixtures/` 种子建号，照搬 core 自带插件的写法
  （`plugins/discourse-narrative-bot/db/fixtures/001_discobot.rb`）：固定负 id、主邮箱占位、
  `user_option` 邮件全部 `never`、资料简介说明「本账号收录公开来源的期刊投稿评价，每条注明出处」。
- 负 id 即 core 意义上的 bot（`User#bot?`，app/models/user.rb `scope :human_users` 为 `users.id > 0`），因此：
  - 不计入站点用户数（lib/statistics.rb 用 `User.real`）；
  - 不进 /u 用户目录（app/models/directory_item.rb 的刷新查询带 `u.id > 0`）；
  - 不进 gamification 排行榜（leaderboard_cached_view.rb 带 `u.id > 0`）；
  - 不能登录，不收任何邮件。
- 不给 admin/moderator 权限：发帖用 `skip_guardian` 绕过 closed 话题，不需要额外权限。
- 首次同步时自动建号：用户名 `journal_reviews`、显示名「投稿经历收录」，id 存在 PluginStore
  （`comment_bot_user_id`）。core 有 `BotUser` 时用它分配 id，旧版 core 退回到「所有用户最小 id 与 -1200 再减 1」。
- 收录账号只在搜索结果、引用署名、无 JS 页面、话题参与者头像这几处露出名字。

### 2.1 每条回复的匿名作者（已实现）

- 名字由三个词表随机组合：`discourse_journals_comment_author_modifiers`（修饰词）+ `discourse_journals_comment_author_nouns`
  （名词）+ `discourse_journals_comment_author_suffixes`（可选后缀，含「无后缀」），中英文混排，如「熬夜的Panda」
  「写论文的Falcon在读」。默认 70 × 70 × 25 = 122,500 种组合。编号取 `SHA1(record_id)` 前 6 位，作为随机种子挑词，
  所以同一条评论每次同步、每次打开都是同一个名字。
- 同一话题内重名时，楼层靠前的保留原名，后面的追加随机大写字母（同样以编号为种子），直到不重复。
- 名字由 `CommentAuthor.assign!` 按话题算好写进帖子自定义字段 `discourse_journals_comment` 的 `name`（同时还存
  `source`、`code` 和来源信息）。同步有新增或更新时重算；改词表会触发 `RenameCommentAuthors` 后台任务重算全部话题。
  还没分配名字的回复显示不带后缀的基础名。
- 自定义字段随话题一次性预加载，序列化成 `dj_comment_author`。
- 前端替换 core 的两个包裹出口 `post-avatar`、`post-meta-data-poster-name`，只对带 `dj_comment_author` 的回复生效：
  头像是按编号着色的首字，名字没有用户链接，也没有 `data-user-card`，点了不弹任何用户卡片。
  其他帖子（含真人回复）完全走 core 默认渲染。

---

## 3. 回复格式

### 3.1 结构

```
[可选] 结构化信息行（只含高置信度字段，§3.2）

评论正文（原文）

[英文原文且有中文译文时] [details="中文译文"] … [/details]
```

正文下方的来源说明不写进 raw，由前端渲染：

```
来源：LetPub · 原发布于 2026-10-07 19:53 · 查看原文
```

- 正文用 `comment_text` 原文，只做空白规整，不改写。
- 来源站点、`source_url`、原发布时间与精度存在帖子自定义字段 `discourse_journals_comment` 里，
  `CommentSourceNote` 在序列化时拼成 `dj_comment_source`，前端在 `post-content-cooked-html__after`
  渲染。设置 `discourse_journals_comment_source_note_enabled` 关闭后不再序列化，所有回复立即隐藏，无需重新同步。
- 摘要（digest）同时覆盖 raw 和这些字段，来源信息变化也会触发更新。
- 原文链接带 `rel="nofollow noopener noreferrer"`，只接受 http(s)。
- 所有文字走 server locale（`discourse_journals.comment_post.*`），中英两套；「查看原文」走 client locale。

### 3.2 结构化信息的置信度门槛

| 字段 | 展示条件 |
|---|---|
| 投稿结果（录用/拒稿/直拒…） | `confidence.status == "high"` |
| 首审天数、总处理天数、审稿轮次、出版延迟 | `confidence.time_metrics == "high"` |
| 各项评分 | `confidence.rating_metrics == "high"` |
| 版面费/审稿费 | 有值即展示（取自原文的显式数字） |
| 标签 | 不在单条回复里展示（聚合标签已在档案页「评价」区） |

SciRev 一类来源的作者自填字段为高置信度，会展示；LetPub/万维一类从文本推断的不会。

---

## 4. 时间

| `published_at_precision` | 帖子 `created_at` | 备注里的写法 |
|---|---|---|
| datetime | 原值 | 原发布于 2026-10-07 19:53 |
| date | 当天 00:00 | 原发布于 2026-10-07 |
| month | 当月 1 日 | 原发布于 2016 年 5 月 |
| year | 当年 1 月 1 日 | 原发布于 2016 年 |
| unknown / invalid / 空 | 收录时刻 | 原发布时间未知 |

- `published_at_iso` 没有时区后缀，按北京时间（UTC+8）解释：精确到时刻的 13.0 万条全部来自国内站点
  （万维 10.2 万、LetPub 1.9 万、PeipuSci 4.4 千、学术进修课堂 1.9 千），页面显示的就是北京时间；
  国外来源（SciRev、Peeref、Reddit 等）只到日、年或没有日期。上游摘要里的 `latest_at` 把同一个值加了 `Z`，
  只用于增量比较，不参与显示。
- 首次同步时每个话题内按时间升序逐条插入，楼层顺序 = 时间顺序；之后增量新增的追加在后。

---

## 5. 写入

```ruby
ActiveRecord::Base.transaction do
  post =
    PostCreator.new(
      bot,
      topic_id: topic.id,
      raw: raw,
      created_at: created_at,
      import_mode: true,       # 不推送 MessageBus、不更新 bot 自身计数与跟踪、不做垃圾/审核检查
      skip_guardian: true,     # 期刊话题是 closed 的
      skip_validations: true,  # 不受频率、长度、相似度等限制
      skip_jobs: true,         # 不发通知/邮件，不 onebox
      skip_events: true,       # 不触发 post_created webhook 与插件事件
      no_bump: true,           # 不顶起话题，保持期刊列表顺序
    ).create!
  CommentPost.create!(record_id:, topic_id: topic.id, post_id: post.id, digest: Digest::SHA1.hexdigest(raw))
end
```

- 新表 `discourse_journals_comment_posts`：`record_id`（唯一索引）、`topic_id`、`post_id`、`digest`、时间戳。
  帖子与映射同一事务落库；唯一索引兜住并发或重跑导致的重复（2026-09 重复话题事故的教训）。
- 用 `import_mode`：话题的 `posts_count`、`highest_post_number`、`last_posted_at` 仍由 PostCreator 正常更新；
  省掉的是导入用不到的副作用——每条回复 2 次 MessageBus 推送（会刷屏正在看该话题的人）、bot 自己的
  `user_stats` 与话题跟踪、垃圾/审核检查。代价：bot 资料页的发帖数不准，无影响。
- 修改：上游正文或渲染结果变化（digest 不同）时用 `PostRevisor`，编辑者为 system，
  `skip_validations`、`bypass_bump`、`skip_revision`（模板调整不产生几十万条修订记录）。
- 删除：上游不再返回的评论，用 `PostDestroyer`（system，软删除，可恢复）。

---

## 6. 同步流程

1. **全量**（管理页手动启动）：按 topic id 游标遍历分类内 `reviews.count > 0` 的期刊话题；每刊用游标拉全部评论，
   与映射表对账：新增 → 建帖；digest 变化 → 修改；上游已无 → 删除。
2. **增量**：apply 更新期刊时若 `reviews.count` 或 `reviews.latest_at` 变化，把话题记入待同步标记；
   定时任务只处理有标记的话题。
3. **安全**：
   - 只有某刊列表完整拉取成功才做删除；网络错误、5xx 一律跳过该刊，下次再试；
   - 一次运行里某刊要删掉超过一半已同步回复时不删，只记日志，人工确认；
   - 301 跟随到新 id；410 跳过并记日志。
4. **并发**：Redis 租约，同一时间只跑一个评论同步；ApplyLock 被持有时（apply 运行中，话题可能被合并、移入回收站）暂停。
5. **断点、暂停、进度**：沿用封面同步的模式（PluginStore 状态 + MessageBus + 管理页按钮），按 topic id 记录断点。

预计全量：见 §9 实测；建帖约 1.5 小时，抓取在本地按顺序要 3–4 小时，必须并发抓取并与建帖流水线化。

---

## 7. 对现有功能的影响

- 期刊页：页面框架只隐藏 1 楼的头像、元信息和 topic map（discourse-journals.scss 的 `body.dj-journal-page`），
  回复区按常规显示；为收录账号的回复补一套简洁样式。
- 1 楼重建：`before_post_process_cooked` 钩子只处理 `post_number == 1`（plugin.rb），回复不受影响。
- 排序与 SEO：`no_bump` 不改变列表顺序；话题 `updated_at` 会变，sitemap lastmod 随之更新，评论内容可被站内搜索与爬虫收录。
  **不加** Review / AggregateRating 结构化数据：Google 不允许汇总其他网站的评价做评价摘要。
- 话题仍是 closed，读者不能回复；是否开放真实用户评论另行决定。
- 数据量：posts 约 +19.4 万行，加上搜索索引预计数百 MB；用户只 +1（bot）。

---

## 8. 实施清单

已实现（测试版，2026-11-15）：
- 迁移 `discourse_journals_comment_posts`（`record_id` 唯一）；`CommentPost` 模型。
- 收录账号：运行时自动创建（`CommentBot`），不用 `db/fixtures/`。
- `ApiClient#fetch_journal_comments`：游标分页，301/404（`no_comments` 与不存在分开）/410。
- `CommentPostBuilder`（§3、§4）、`CommentAuthor`（§2.1）、`CommentSyncer`（单刊对账、删除安全阈值、首次导入保持已读）。
- `SyncComments` job + `CommentSyncState`（PluginStore 状态、心跳、Redis 租约、apply 运行时让路）。
- 管理页「期刊评论同步」：话题 ID 或前 N 本（≤200）、进度、结果统计。
- 设置 `discourse_journals_comment_author_modifiers` / `_nouns` / `_suffixes`；中英文 locale；回复与管理页样式。
- Specs：渲染、对账、API 客户端、管理接口、话题 JSON 中的作者名、job。

未实现：全量同步入口与暂停/续跑、定时增量任务（及其开关设置）、README 的运维说明之外的文档。

---

## 9. 性能实测（2026-11-15，本地 Docker，jemalloc）

| 项 | 实测 | 结论 |
|---|---|---|
| 建帖 | IEEE Access 1,777 条：37.4 ms、40.7 SQL/条，每条 2 次 MessageBus 推送 | 改 `import_mode` 后：25–31 ms、25.1 SQL/条（−38%），推送 0 |
| 其中 Markdown 渲染 | 12–16 ms/条（core 的 PrettyText） | 保留；改成 raw_html 自拼 HTML 能省一半，但会失去 core 的清洗兜底，不值 |
| 作者命名 `assign!` | 一条回复一条 UPDATE（1,777 条 → 1,781 SQL） | 改为每批 1,000 条一条 UPDATE：5 SQL |
| 上游抓取 | 本地每页 0.6–1.0 s；静态页首字节也要 0.66 s，是网络距离 | 全量约 1.6 万次请求：顺序要 3–4 小时；需并发 + 流水线，并先在生产测延迟 |
| 无变化重同步 | IEEE Access 18.7 s，几乎全是抓取，数据库只有 5 条 SQL | 增量只能抓 `reviews` 摘要变了的期刊，不能定期全量重抓 |
| 内存 | 单进程连续 4 轮各 3,401 条：比预热基线高 +150～180 MB，不再增长 | 无泄漏；生产 Sidekiq 空闲约 700 MB、上限 1000 MB，余量约 130 MB，全量前要么调高 `UNICORN_SIDEKIQ_MAX_RSS`，要么任务支持断点续跑 |
| 管理页「按数量选期刊」查询 | 4.5 s：全表扫描并解析 34 万期刊 JSON | 测试按钮可接受；全量/增量要改成 upserter 写一个 `discourse_journals_comment_count` 小字段，用索引查 |
| 话题页渲染 | 0 / 11 / 286 / 1,777 条回复：HTML 58–61 ms、JSON 26–33 ms、爬虫 40–51 ms；SQL 不随回复数增长 | 无 N+1；页面体积随每页 20 条回复增长 |
| 存储 | 每条约 2.2 KB 行数据（帖子 725 B、自定义字段 285 B、搜索 940 B、映射 128 B）+ 索引 | 19.4 万条约 0.5–0.8 GB |

## 10. 待确认

1. 全量同步前：管理页加暂停/续跑，确认首次全量的时间窗口（约 1.6 万次请求、19.4 万条回复）。
2. 定时增量任务是否启用、多久一次。
3. 收录账号的名字与默认作者名格式是否要调整（都可在后台改）。
