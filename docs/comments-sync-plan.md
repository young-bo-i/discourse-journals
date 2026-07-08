# 期刊评论同步方案（最终设计稿 · 人设池版）

> 目标：把上游期刊评论按时间写进每个期刊话题的回复区，每条评论由一个"人设池"里的
> 虚拟研究者发布，**任何角度看不出是假号**，正文不含任何来源标注。
>
> 所有 core 行为均经源码取证（标注 文件:行号，core = 本仓库当前 main）。状态：设计稿，未实现。
> 本稿取代早前的 staged 隐藏号 + 一作者一号方案（已被产品决策反转）。

---

## 0. 已锁定的产品决策（用户已拍板）

1. 假用户必须**完全像真人且可见**（不是隐藏的 staged 影子号）。
2. 预建**约 1 万个持久化人设**（以后可扩），各有姓名、研究领域、身份。
3. 每条评论**按学科领域从池中挑一个人设**发布（同学科的期刊 → 同领域人设）。
4. 正文**不含任何来源标注**（不出现 SciRev / 来源 字样）。
5. **不改任何全站显示设置**（A）。默认帖子显示的是 **username**，所以 **username 本身就要是一个看起来像真人的账号名**（如 `wei.zhang` / `mchen` / `l_wang88`）——普通、不用多语言、看着像真人即可。姓名/领域由**后台上传文件**提供（F）。
6. 头像**走默认**（系统字母头像，不上传）。
7. 人设**注册时间落在近几年、打散**（C）；不深度 backdate（避免 /about 建站日矛盾）。
8. 建号**做成后台上传文件导入**（F）：管理员上传一份人设清单文件（CSV/JSON），插件按行建号并套全套防穿帮配置。先建 1 万，可再传文件扩容。
9. Member 徽章：暂不发，或确定性随机发给一小部分（G，配置项，默认关）。

---

## 1. 上游 API 事实（已实测）

- `GET /api/open/journals/{unifiedId}/comments?page=&pageSize=` → `data.comments[]`：
  `record_id`（稳定唯一 id，幂等键）、`published_at_iso`+`published_at_precision`（**可能只到年**，如 `"2016"/"year"`）、
  `paper_status`（accepted/rejected/desk_reject）、`overall/speed/communication/review_quality/cost` 各 0-5 评分、
  `first_review_days`/`total_handling_days`、中文 `tags`、`comment_text_zh`/`_en`/`original_language`。
  （`publisher_display_name` 是上游匿名作者名——**本方案不再使用它**，改用自建人设池。）
- `data.journal` 是聚合统计（`comment_count` 等）。
- `byIds?full=1` 行自带 `comments` 摘要块 `{has_comments, count, latest_at, list_url}` —— 发现零额外请求。
- 密度稀疏：样本约 1/3 期刊有评论，多为个位数条、少数几十条。
- 现有 `ApiDataTransformer.transform` 丢弃 `row["comments"]`（api_data_transformer.rb:5-28），需显式接入。
- **待实测**：评论端点 pageSize 上限（列表端点有 pageSize>100 丢数据前科）。

---

## 2. 人设池（后台上传文件导入建号）

### 2.1 人设 schema（持久化）

每个人设 = 一个 User 行 + user custom fields：
- `username`：**看起来像真人的账号名**（如 `wei.zhang` / `mchen` / `l_wang88`）——因为不改显示设置，**帖子上显示的就是它**。ASCII、3-20 字符。
- `name`（可选）：完整姓名，只在用户卡片/资料页的"Name"字段显示（默认不会上帖面）。填了增资料真实感，不填也行。
- `discourse_journals_persona`：`"1"`（标记人设号，成组/回滚定位）。
- `discourse_journals_field`：学科大类（中科院大类，见 §5），驱动分配。
- `discourse_journals_tone`：口吻编号（`0..N-1`，见 §7），绑定固定文风。
- 默认字母头像、无 bio、无生日、TL2、回填的注册时间与"最后访问"时间。

全部人设加入一个专用 **`journal_personas` group**（用于排行榜排除等，见 §4）。

### 2.2 建号入口 = 后台上传文件（决策点 F）

管理后台加一个"人设池"上传区（**注意：早前那套 JSON 导入 UI/ImportLog 表已被删除清理，这是全新、专用的导入器**）：

- **上传文件格式**：CSV 或 JSON，每行/每项一个人设。列建议：
  `username`（必填）、`name`（可选）、`field`（学科大类，可选——缺省由系统按配额自动分配，见 §2.5）、`location`/`bio`（可选）。
  → 姓名库由**你准备并上传**，插件不再内置姓名生成器（省掉造名难题，也让名字可控可审）。
- **导入 job** `Jobs::DiscourseJournals::ImportPersonas`（`queue: "low"`，分批事务、断点、进度走 MessageBus，骨架同 apply）：
  逐行校验 username 合规/不撞名（`User.username_available?`，user.rb:422-437；撞了记为跳过并在结果里报告，**不自动加数字后缀**避免序列号感），
  然后按 §2.3 配方建号。**幂等**：以 username（或文件里的稳定 key）做 UserCustomField 查重，重复上传不重复建。
- **扩容**：以后再传一份新文件即可追加人设（已发评论不受影响，§6）。

### 2.3 建号配方（core 取证，anonymous_shadow_creator.rb:44-79 改造）

```ruby
# 导入 job 内，每 500–1000 行一个事务
User.transaction do
  u = User.create!(
    email: "#{SecureRandom.hex}@scholay-user.invalid",  # 随机唯一假邮箱（正则通过、无 MX 检查）
    skip_email_validation: true,          # user.rb:244,2352 关 email 格式/关联校验
    username: row.username,               # 文件提供的真人化 handle（ASCII，username_validator.rb:47,164）
    name: row.name,                       # 可选，name 字段无字符集限制（user.rb:2119-2126）
    active: true, approved: true, approved_at: created_at,
    trust_level: 2,
    manual_locked_trust_level: 2,         # promotion.rb:18,21 短路 Promotion：不发升级私信/徽章/防降级
    created_at: deterministic_recent_time(row.username),  # 近几年、打散，见 §2.5
    import_mode: true,                    # user.rb:1601 压掉 1 万个 gravatar 抓取 job（唯一作用）
  )
  u.user_option.update_columns(           # 必须：否则假邮箱进摘要队列 → 退信毁域名
    email_digests: false,
    email_level: UserOption.email_level_types[:never],
    email_messages_level: UserOption.email_level_types[:never],
    mailing_list_mode: false,
  )
  u.update_columns(                       # 回填"过去访问过、现在不在线"，绕回调/在线事件
    last_seen_at: deterministic_last_seen(row.username),  # 近几周~几月内、分散
    previous_visit_at: <更早>,
    first_seen_at: u.created_at,
  )
  # 可选：u.user_profile.update_columns(location:, bio_raw:, bio_cooked:)（填 bio 会触发 Autobiographer 徽章，见 §4）
  u.custom_fields = { "discourse_journals_persona" => "1",
                      "discourse_journals_field" => field, "discourse_journals_tone" => tone }
  u.save_custom_fields
  GroupUser... # 加入 journal_personas group
end
```

关键点（全部取证）：
- **密码可选**：不传即"无密码号"（永不登录），password_validator 短路（user.rb:1015-1017）。
- **默认头像零副作用**：`selectable_avatars_mode` 默认 disabled（不赋随机图），无上传 → 系统字母头像；
  首字母取 **username**、颜色由 `MD5(username) % 色板`（user.rb:1235,1259-1261）→ **1 万不同 username 天然离散到全色板**。
  `import_mode` 压掉 gravatar 外呼（user.rb:1600-1614）。
- **TL2 + manual_locked_trust_level:2**：Promotion 完全短路（promotion.rb:18,21）→ 不发欢迎/升级私信、不触发 TL 徽章、防自动降级。
  Member 徽章不会自动补发；决策点 G = 暂不发（或导入后对确定性随机一小部分 `BadgeGranter.grant(Badge::Member, u)`）。
- **date_of_birth 留空** → 天然躲开 cakeday 生日页。
- **不加 `anonymous_users` 行** → `User.real` / /u 目录正常收录（这正是"可见"所要的）。
- **不改任何全站显示设置**（决策点 A）：帖子显示 username，所以 username 必须像真人 handle（由上传文件保证）。

### 2.4 领域分配（文件可指定，也可系统按配额补）

- 文件里带 `field` 列 → 直接用。
- 缺省 → 系统按配额分配：领域 = 中科院大类（约 13 个，见 §5），配额 `N_d ∝ C_d`（该学科评论量）+ **冷门地板 `N_min≥30-50`**，归一到 P=10000。
- 目的：让每个人设的公开评论数落在真人可信区间（个位数到几十条），杜绝"热门学科人设不够→被迫跨领域发帖"这一最大端倪源。
- 冷门学科评论极少时给 `N_min` 个人设，多数只发 0-1 条，恰似低活跃真人。扩容只需再传文件补齐。

### 2.5 注册时间与评论时间（决策点 C：近几年、打散）

- **人设 `created_at`**：确定性打散到**近几年**（如过去 1-4 年、且**跨全年 365 天分散**），
  用 `站点建站日之后的窗口 + SHA1(username) % 可用天数` 生成 → 重建同值、无"同天注册"尖峰。
  跨日分散同时天然化解 cakeday 周年页与周年徽章的"同日尖峰"（§4）。**不早于站点真实建站日**（避免 /about 建站日矛盾）。
- **评论 `created_at`**：上游只到年、且真实年份可能早于人设注册年——为避免"评论早于账号注册"的资料矛盾，
  评论时间映射到**近几年窗口**（不照搬上游 2016 原始年），**钳制为 ≥ 所属人设 created_at + 若干天**；
  同一期刊内按上游 `published_at` 相对顺序**串行**插入（楼层序=展示序，见 §8）。这样账号年龄 > 帖龄、全部近期、且线程内有时间层次。
  （上游原始年份不对外可见，映射到近几年不损失信息、更像"近几年陆续有人分享投稿经历"。）

---

## 3. 评论发帖配方

**走 PostCreator，不 Post.create!**（官方 import 全走 PostCreator，base.rb:608）。

```ruby
PostCreator.new(persona_user,
  topic_id:         journal_topic.id,
  raw:              rendered_markdown,        # §7 无来源模板
  created_at:       computed_time,            # §8 确定性历史时间
  guardian:         Guardian.new(Discourse.system_user),  # 过 closed/只读分类（import 同款 base.rb:582,599）
  skip_validations: true,   # 免 TL 限制/限速/长度/连发校验（post_creator.rb:173,603-608）
  skip_guardian:    true,   # 双保险绕 closed（post_creator.rb:165）
  skip_jobs:        true,   # 不发通知邮件给真人 watcher、不 onebox（post_creator.rb:229）
  skip_events:      true,   # 不触发 post_created webhook / 插件监听（post_creator.rb:227）
  no_bump:          true,   # 不动 bumped_at（post_creator.rb:530）—— 保 28 万话题列表顺序
  custom_fields:    { "discourse_journals_comment_record_id" => record_id },  # 与帖同事务落库
).create!
```

要点：
- **不用 import_mode**（区别于建号）：这样 `update_user_counts` 照常跑（post_creator.rb:614）→
  人设的 `user_stat.post_count` / `last_posted_at` **自动正确累加**，profile 不会出现"帖子流里有帖但显示 0 帖"的端倪，
  **省掉 user_stats 回填步骤**。`skip_jobs` 已挡住给真人 watcher 的通知邮件，`skip_events` 挡住 webhook——通知面已覆盖。
- **closed 话题不 reopen**：guardian 注入直发，与 apply 的 `ensure_closed!` 零冲突。
- **created_at 回填官方能力**（post_creator.rb:583-588）；cooked 同步生成；搜索索引经 `after_commit :index_search` 自动完成（评论可搜）。
- **no_bump**：`updated_at` 仍被更新 → 经插件 sitemap patch（lastmod 取 max(bumped_at,updated_at)）自动成为 SEO 增益；
  bump 到历史时间=沉底、bump 到当前=28 万洗版，都不可取。
- **后续修订纪律**：今后任何程序化改评论帖，editor 必须是 system user（否则 PostRevisor 会补发 mention 通知，post_revisor.rb:400,843）。

---

## 4. 可见人设的"防穿帮"配置清单（非 staged → core 自动过滤全失效）

> core 没有"机器人"过滤，只认 staged/active/silenced 等。非 staged active 号 = core 眼里的纯真人，
> 面向真实用户的查询会无差别收录。逐面处理：

| # | 泄露面 | 处理（core 证据） | 优先级 |
|---|---|---|---|
| 1 | **邮件**（digest/通知/私信发向假邮箱→退信毁域名） | 建号即 `email_digests=false`+`email_level/email_messages_level=never`（user_option.rb:62-63,99；enqueue_digest_emails.rb:26）；ActivationReminder 对 active 已豁免 | **最高（唯一站外实害）** |
| 2 | **gamification 排行榜**（一次后台重算把 backdate 帖灌进 all-time 公开榜） | 全部人设入 `journal_personas` group，把该 group 加进**每一块**排行榜的 `excluded_groups_ids`（leaderboard_cached_view.rb:161-166；admin 可写 admin_..._controller.rb:52-53）。**无全站开关，漏一块就穿帮**，需覆盖现有+未来每块 | **必须** |
| 3 | **cakeday 周年页**（大量"同日加入 N 周年"尖峰） | §2.5 的 created_at **跨全年 365 天分散** → 周年页每天只散落十几个人设，无尖峰、看似正常；无需关功能 | 随时间策略天然消解 |
| 4 | **徽章公开列表时间尖峰**（Autobiographer/Anniversary 批量同刻发放） | **走默认头像 + 不填 bio → Autobiographer 不触发**（需 uploaded 头像+bio，badge_queries.rb）；Anniversary 授予日随 created_at 跨全年分散、无尖峰；Basic/Member 万人皆有属正常 | 走默认即天然规避 |
| 5 | **cakeday 生日页** | **不填 date_of_birth** → 天然排除（cakeday_controller.rb:51-57） | 天然安全 |
| 6 | **/u 用户目录** | 默认按 likes_received 降序，bot 零赞天然沉底（directory_column.rb:8-18）；"按发帖数排序"会戳穿→可选主题组件注入 `exclude_groups=journal_personas`（directory_items_controller.rb:153-164） | 接受（默认沉底） |
| 7 | **@提及/用户搜索** | bot `last_seen_at` 回填成较早时间→排序靠后（user_search.rb:182）；但精确名匹配与"期刊话题内候选"仍会弹出，且**"真人@bot、bot不回复"是内生破绽** | 接受（无法根除） |
| 8 | **/about 用户数** | +1 万计入（statistics.rb:144-148）→ 视为学术站可信增益；backdate 打散 signups 尖峰 | 接受 |
| 9 | **presence/在线状态** | bot 从不建实时连接 → 永不"在线"（不是 last_seen 驱动） | 天然安全 |

**必须处理的 3 项**：邮件、排行榜组排除、周年页（随时间策略）。走默认头像 + 不填 bio/生日让徽章尖峰与生日页天然消解。

---

## 5. 领域感知的分配

### 5.1 领域数据来源（重要纠错）

`unified.fqb_major_category` **在归一化后被丢弃、拿不到**（field_normalizer.rb:13-31 无 :unified 键）。
可用的领域键是 **`cas_partition.major_category`（中科院大类）**，而且它**已经被打成话题 tag**
（JournalTagManager.extract_subject，journal_tag_manager.rb:418-424）——
**评论同步时不用解析 JSON，直接读话题的学科 tag 就能拿到领域，纯 SQL 可过滤**。零成本。
（中文大类可回退 `xinrui_partition.major_category_cn`；期刊可跨 2 大类，人设匹配允许相近学科。）

### 5.2 确定性分配（HRW / rendezvous 哈希）

```
候选集 C_d = 该学科大类的全部人设（按 user_id 升序的确定数组）
persona   = argmax_{p ∈ C_d}  SHA1(record_id + persona_key(p))
```

四个约束同时满足：
- **确定性**：纯函数，重跑同值。
- **领域匹配**：候选集按学科 tag 限定 → 化学人设永不评医学刊。
- **同刊去重**：一刊内评论按 (computed_time, record_id) 排序逐条取 HRW 第 1 名；若该人设在**本刊**已用过，退到第 2/3 名（确定探测）。
- **扩容稳定**：HRW 加人设只以 ~1/N 概率抢走某条**未发**评论，对已算分配几乎零扰动（远优于 `% N` 取模）；且负载天然近均匀。

**持久化 = `post.user_id` 本身**（post_creator.rb:562 建帖时落库）：record_id 唯一索引冻结每条评论只建一次，
`post.user_id` 写完即永久，改作者是显式重操作（PostOwnerChanger）。**不需要独立映射表**，扩容只影响未发评论。

---

## 6. 幂等三层

1. **record_id 唯一部分索引**（DB 硬保证，防并发/重放重复发帖）：
   ```ruby
   add_index :post_custom_fields, [:value], unique: true,
     where: "name = 'discourse_journals_comment_record_id'",
     algorithm: :concurrently, if_not_exists: true   # 照抄插件 topic_custom_fields 部分索引写法
   ```
2. 每刊先 SELECT 已存在 record_id 集合，只插缺失项。
3. 人设 find/create 以姓名库槽位为幂等键（UserCustomField 唯一部分索引）。

---

## 7. 正文渲染（无来源）

上游字段：`comment_text_zh/_en`、`paper_status`、各 0-5 评分、`first_review_days/total_handling_days`、中文 tags。

**三条 core 硬约束**（取证）：
1. **正文一个外链都不放**（本就无来源）→ 从根免疫 onebox 全站 rebake 时的批量抓取（cooked_post_processor.rb:27,39,63）。
2. **入库前清洗 `@`、`[quote`、本站域名内链**：`extract_links`/`TopicLink.extract_from` 在建帖事务无条件跑（post_creator.rb:204,652-655），
   否则 `@真实用户` cook 成 mention（视觉端倪）、内链建反向关系。
3. 上线前查 watched words / `review_every_post=false`（skip_validations 已基本绕过，但仍核查）。

**模板**：3+ 套第一人称"投稿体验"，把结构化字段**自然嵌进句子**（不做"字段:值"罗列），评分行内 `x/5`（不画满行 ★），
`paper_status` 翻"录用/被拒/编辑直接拒稿"，缺失字段整句省略，中文 tags 化成半句口语。
**口吻绑定人设**（`persona.tone = 建号时定的编号`）→ 同一人设永远同一文风，跨期刊多条读起来像同一个人。
**只出中文、以模板重述为主，不整段照贴翻译原文**（避免 1 万条共享机翻腔这一横向端倪）。

---

## 8. 时间策略（映射到近几年，与人设注册期一致）

决策点 C 已定：评论时间落在**近几年**、与人设注册期一致（不照搬上游 2016 原始年）。算法：
- **相对顺序来自上游**：同一期刊内评论按 (`published_at`, `record_id`) 排序，决定线程内先后。
- **绝对时间确定性映射**：`t = SHA1(record_id)` 映射到近几年窗口内一点，**钳制 `t ≥ 所属人设.created_at + 若干天`**（避免"评论早于账号注册"），
  纯函数、重跑同值、落库后终身不变。
- **串行插入**：一刊内按上述顺序逐条创建 → 楼层序 = 展示序（Discourse 按 post_number 展示，非 created_at；
  负时间差的 time-gap 分隔条不渲染，不炸）。绝对 created_at 无需严格单调（post_number 已定序）。
- **增量追加**：新评论同法计算 + 钳制到该刊已有最后评论之后；时间戳一旦落库不再变。
- 结果：账号年龄 > 帖龄、全部近期、线程内有时间层次——像"近几年陆续有研究者分享投稿经历"。

---

## 9. 同步管线（独立子系统，吸取封面烂尾教训）

**不做 apply 第三相位**：analyze/restart 会 `delete_all` 整张 mapping_analyses 表（admin_mapping_controller.rb:18,82），
封面子系统正是把状态挂这行才烂尾。评论同步必须独立、可单独触发、可断点。

- 新表 `discourse_journals_comment_syncs`（单活跃行）：`status` enum、`checkpoint jsonb`（`{last_topic_id, heartbeat}`，
  心跳判活照抄 STALE_APPLY_THRESHOLD 15 分钟）、`stats jsonb`、`started_at/completed_at/error_message/user_id`。
- 新 job `Jobs::DiscourseJournals::SyncComments`（`retry: 0`、`queue: "low"`，cancel_check + PausedError + resume，抄 apply_mapping.rb 骨架）。
- 管理后台第 5 区块 + MessageBus `/journals/comments-sync` + 路由 `comments/sync|pause|resume|status`。
- **与 apply 互斥**（双向 controller 检查）：两者各自 new ApiRateLimiter（进程内 5req/s），并行会变 10req/s。
- **发现零成本**：apply 时把 byIds 行 `comments.count/latest_at` 落**独立 topic custom field**
  `discourse_journals_comments_count`（**不并入 discourse_journals_data**——否则 28 万行 JSON 一次性 MD5 全变、全量重索引，
  这是本设计最容易踩的单点事故）。评论 job 扫 `count != synced`（本地水位 custom field）的话题，按 topic id 有序推进。
- **规模**：拉取 ≈ H 次请求 @5req/s（H=有评论刊数）；发帖话题间 2-4 线程并行（楼层分配有 DistributedMutex + 唯一索引双保险，
  post_creator.rb:408-416），同刊内串行。首次全量小时级，增量分钟级。

---

## 10. 回滚

- 定位：`SELECT post_id FROM post_custom_fields WHERE name='discourse_journals_comment_record_id'`（有索引）。
- 批删走 BulkTopicDeleter 式 SQL + 每话题 `Topic.reset_highest`（topic.rb:981-1035）→ 再按
  `discourse_journals_persona` custom field 定位清人设 → `JournalTagManager.reconcile_counts!` 式对账。
- 现有 `DeleteAllJournals` 随话题级联删评论帖（清 posts + post_custom_fields），留零帖人设孤儿（无害，留清理钩子）。
  建议顺路给 BulkTopicDeleter 补漏删的 `post_timings/post_stats/topic_views/incoming_links` 四表。

---

## 11. 决策点（已全部拍板）

| # | 问题 | 结论 |
|---|---|---|
| A | 是否改全站姓名显示设置 | **不改**。帖子显示 username → **username 本身要是真人化 handle**（由上传文件保证），无需多语言 |
| C | 人设注册时间 | **近几年、跨全年打散**（建站日之后）；评论时间也映射到近几年、钳制 ≥ 人设注册（§8） |
| F | 建号方式与规模 | **后台上传文件导入**，先 1 万；姓名/领域由文件提供，缺省领域按配额补；可再传文件扩容 |
| G | Member 徽章 | **暂不发**（或导入后对确定性随机一小部分 grant，配置项默认关） |

（B「/u 目录遮蔽」= 默认沉底接受；D「来源标注」= 无来源；E「语言」= 仅中文——均已定。）

---

## 12. 实施阶段

1. **人设基建**：
   - `journal_personas` group + 建号服务（按 §2.3 配方）+ **后台"人设池"上传文件 UI + `ImportPersonas` job**（CSV/JSON 解析、分批、幂等、进度、结果报告）。
   - 领域配额分配（文件缺省时）；`created_at`/`last_seen_at` 确定性打散（§2.5）。
   - 把 `journal_personas` 加入现有及未来**每一块** gamification 排行榜的 `excluded_groups_ids`；确认邮件 user_option 关闭。
2. **评论管线**：迁移（comment_syncs 表 + `record_id` 唯一部分索引）；transformer 接 comments 摘要 + 2 个 topic custom field；
   `CommentAssigner`（HRW 领域分配，读话题学科 tag）；`CommentRenderer`（无来源模板 + 口吻绑人设）；`CommentPoster`（PostCreator 配方 §3）；
   `SyncComments` job + checkpoint/暂停/恢复 + admin 区块 + 与 apply 互斥 + 速率设置。
3. **联动（可选）**：聚合评分**条件性**进 discourse_journals_data → 档案页"读者评价"section + JSON-LD aggregateRating + SEO excerpt。
4. **运维**：回滚 rake（record_id 批删 + reset_highest + 按 `discourse_journals_persona` 清人设）。

**上线前检查单**：确认无 active user/post webhook、无重度监听 `:user_created`/`:post_created` 的插件（discourse-ai/automation）；
watched words；`review_every_post=false`；评论端点 pageSize 上限实测；**先在 staging 用 50 人设 + 100 刊小批量演练**（含 @人设、点头像看卡片/资料、翻 /u 目录、看 /badges 与周年页，逐一核对无端倪）。
