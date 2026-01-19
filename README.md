# 📚 Discourse Journals Plugin

期刊统一档案系统 - 从外部 API 同步期刊数据到 Discourse 论坛

---

## ✨ 功能特性

- 🔄 **API 同步**：从外部 API 自动同步期刊数据
- 🎯 **智能筛选**：支持多条件筛选（DOAJ、NLM、Wikidata、开放获取等）
- 📊 **实时进度**：导入过程实时显示进度和统计
- 🛡️ **错误处理**：数据验证失败时跳过，不污染数据库
- 🗑️ **智能恢复**：自动恢复被误删的期刊话题
- 🔍 **SEO 优化**：自动添加 SEO 友好的标题后缀

---

## 🚀 快速开始

### 1. 启用插件

```
Admin → Settings → Plugins → discourse_journals_enabled = true
```

### 2. 配置分类

```
Admin → Settings → Plugins → discourse_journals_category_id
选择用于存放期刊的分类
```

### 3. 配置 API

```
Admin → Plugins → discourse-journals
输入 API URL（例如：https://api.example.com）
点击"测试连接"验证
```

### 4. 开始导入

```
方式 A：导入第一页（测试）
  - 约 100 个期刊
  - 用于验证数据正确性

方式 B：导入所有数据
  - 所有期刊（如 15 万个）
  - 后台运行，可安全关闭页面
```

---

## ⚙️ 配置选项

访问：`Admin → Settings → Plugins → discourse-journals`

| 配置项 | 默认值 | 说明 |
|--------|--------|------|
| `discourse_journals_enabled` | `false` | 是否启用插件 |
| `discourse_journals_category_id` | - | 期刊分类 ID |
| `discourse_journals_api_url` | - | 外部 API URL |
| `discourse_journals_title_suffix` | `期刊详情 \| 学术期刊库 \| 开放获取期刊` | SEO 标题后缀 |
| `discourse_journals_auto_recover_deleted` | `true` | 自动恢复已删除的话题 |
| `discourse_journals_close_topics` | `true` | 导入后自动关闭话题 |
| `discourse_journals_bypass_bump` | `true` | 更新时不顶帖 |

---

## 🎯 筛选条件

支持以下筛选条件：

| 参数 | 类型 | 说明 |
|------|------|------|
| `q` | string | 搜索关键词（ISSN、标题、出版商） |
| `inDoaj` | boolean | 是否在 DOAJ 中 |
| `inNlm` | boolean | 是否在 NLM 中 |
| `hasWikidata` | boolean | 是否有 Wikidata 记录 |
| `isOpenAccess` | boolean | 是否为开放获取 |

**使用方法**：
```
Admin → Plugins → discourse-journals
→ 显示筛选
→ 设置筛选条件
→ 开始导入
```

---

## 📊 导入行为

### ✅ 成功创建/更新

```
数据完整 → 归一化成功 → 渲染成功 → 创建/更新帖子
```

**统计**：
- ✅ 新建：创建新期刊话题
- 🔄 更新：更新已存在的期刊

### ⏭️ 跳过（不创建帖子）

以下情况会跳过该期刊：

- ❌ 缺少必要字段（ISSN、标题）
- ❌ 数据归一化失败
- ❌ 内容渲染失败
- ❌ 话题已被删除（如果 `auto_recover_deleted = false`）

**日志**：
```
[DiscourseJournals] ✗ Skipped: Unknown (2008-6164)
[DiscourseJournals]   Reason: 缺少 title 字段
```

---

## 🗑️ 删除话题的处理

### 场景 1：软删除（默认管理员删除）

**auto_recover_deleted = true**（默认）：
```
话题被删除 → 下次导入 → 自动恢复 → 更新内容
```

**auto_recover_deleted = false**：
```
话题被删除 → 下次导入 → 跳过该期刊
```

### 场景 2：永久删除

```
话题被永久删除 → 清理孤立数据 → 创建新话题
```

### 推荐配置

**✅ 推荐**：`auto_recover_deleted = true`

**理由**：
- 保持数据完整性
- 避免因误删除导致数据缺失
- 不会创建重复话题

**如何永久排除某个期刊**：
- ✅ 使用筛选条件排除
- ❌ 不要反复删除话题（会被自动恢复）

---

## 🛡️ 错误处理

### 原则

**数据质量第一，宁可跳过，不可污染！**

- ✅ 数据验证失败 → 跳过该期刊
- ✅ 不创建/更新帖子
- ✅ 记录详细错误日志
- ❌ 不会创建带错误信息的帖子

### 错误分类

| 错误类型 | 处理方式 |
|----------|----------|
| 缺少必要字段 | 跳过，记录日志 |
| 数据格式错误 | 跳过，记录堆栈 |
| 归一化失败 | 跳过，记录错误 |
| 渲染失败 | 跳过，记录错误 |

### 查看错误日志

**前端**：
```
Admin → Plugins → discourse-journals
→ 导入完成后显示"❌ 错误日志"
→ 点击"显示错误"查看详情
→ 点击"复制错误日志"复制
```

**服务器**：
```bash
tail -f log/production.log | grep "DiscourseJournals"

# 查看跳过的期刊
tail -f log/production.log | grep "✗ Skipped"

# 查看成功的期刊
tail -f log/production.log | grep "✓ Created\|✓ Updated"
```

---

## 🔍 SEO 优化

### 标题后缀

**功能**：为期刊话题添加 SEO 友好的标题后缀

**效果**：

```html
<!-- 之前 -->
<title>Agronomy (2073-4395) - 测试期刊 - Discourse</title>

<!-- 之后 -->
<title>Agronomy (2073-4395) - 期刊详情 | 学术期刊库 | 开放获取期刊</title>
```

**特点**：
- ✅ 服务器端渲染（SEO 友好）
- ✅ 只修改 `<title>` 标签
- ✅ 页面内容不变
- ✅ 可在设置中自定义

**配置**：
```
Admin → Settings → Plugins
→ discourse_journals_title_suffix
→ 输入自定义后缀
```

**建议后缀**：

中文站点：
```
期刊详情 | 学术期刊库 | 开放获取期刊
SCI期刊 | 影响因子查询 | ISSN数据库
学术期刊 | 论文发表 | 期刊评价
```

英文站点：
```
Journal Details | Academic Database | Open Access
Scientific Journal | Impact Factor | ISSN Lookup
```

---

## 📈 导入统计

### 实时显示

```
📊 已处理: 100/15000
✅ 新建: 10
🔄 更新: 85
⏭️ 跳过: 5
❌ 错误: 5
```

### 完成消息

```
✅ 同步完成！新建 10 个，更新 85 个，跳过 5 个
```

---

## 🧪 测试建议

### 1. 首次导入

```
1. 导入第一页（100 个期刊）
2. 检查错误日志
3. 错误率 < 5% → 继续导入全部
4. 错误率 > 5% → 检查数据质量
```

### 2. 验证数据

```
1. 访问期刊分类
2. 随机打开几个期刊话题
3. 检查内容是否完整
4. 确认没有"数据归一化失败"的帖子
```

### 3. 测试删除恢复

```
1. 手动删除一个期刊话题
2. 运行导入（第一页）
3. 验证话题是否被恢复
4. 检查内容是否更新
```

---

## 🎯 最佳实践

### 1. 配置建议

```yaml
✅ discourse_journals_auto_recover_deleted: true
✅ discourse_journals_close_topics: true
✅ discourse_journals_bypass_bump: true
✅ discourse_journals_title_suffix: "自定义 SEO 后缀"
```

### 2. 排除特定期刊

**✅ 正确方法**：
```
使用筛选条件排除
例如：inDoaj = true（只导入 DOAJ 收录的期刊）
```

**❌ 错误方法**：
```
反复删除话题（会被自动恢复）
```

### 3. 数据质量监控

```
1. 每次导入后记录跳过率
2. 跳过率 > 10% 时调查原因
3. 定期检查服务器日志中的错误模式
4. 优化数据源或归一化逻辑
```

---

## 📁 文件结构

```
discourse-journals/
├── README.md                           # 本文件
├── plugin.rb                           # 插件主文件
├── config/
│   ├── settings.yml                    # 配置项
│   └── locales/                        # 国际化文件
├── app/
│   ├── controllers/                    # 控制器
│   │   └── discourse_journals/
│   │       └── admin_sync_controller.rb
│   ├── jobs/                           # 后台任务
│   │   └── regular/discourse_journals/
│   │       └── sync_from_api.rb
│   ├── models/                         # 模型
│   │   └── discourse_journals/
│   │       └── import_log.rb
│   └── services/                       # 服务对象
│       └── discourse_journals/
│           ├── field_normalizer.rb     # 字段归一化
│           ├── master_record_renderer.rb # 内容渲染
│           ├── journal_upserter.rb     # 创建/更新话题
│           └── api_sync/
│               ├── client.rb           # API 客户端
│               └── importer.rb         # 导入器
├── assets/
│   └── javascripts/discourse/
│       ├── controllers/                # 前端控制器
│       ├── templates/                  # 前端模板
│       └── initializers/               # 前端初始化
└── db/
    └── migrate/                        # 数据库迁移
```

---

## 🔧 开发

### 运行测试

```bash
# Ruby 测试
bin/rspec plugins/discourse-journals/spec

# 语法检查
ruby -c plugins/discourse-journals/plugin.rb

# Linting
bin/lint plugins/discourse-journals/
```

### 日志调试

```bash
# 查看所有日志
tail -f log/production.log | grep "DiscourseJournals"

# 只看错误
tail -f log/production.log | grep "DiscourseJournals.*ERROR"

# 只看成功
tail -f log/production.log | grep "✓"
```

---

## ❓ 常见问题

### Q: 导入失败怎么办？

**A**: 检查以下几点：
1. API URL 是否正确
2. 网络连接是否正常
3. 查看错误日志获取详细信息
4. 检查服务器日志

### Q: 为什么有些期刊被跳过？

**A**: 可能原因：
1. 缺少必要字段（ISSN、标题）
2. 数据格式错误
3. 归一化或渲染失败
4. 话题已被删除（如果 auto_recover = false）

查看错误日志获取具体原因。

### Q: 如何永久排除某个期刊？

**A**: 
- ✅ 使用筛选条件排除
- ❌ 不要反复删除话题（会被自动恢复）

### Q: SEO 标题后缀没有生效？

**A**: 检查：
1. 是否已设置 `discourse_journals_title_suffix`
2. 是否重启了服务器
3. 浏览器是否有缓存（查看页面源代码）

### Q: 导入速度慢怎么办？

**A**: 
- 导入在后台运行，可安全关闭页面
- 15 万期刊约需 50-90 分钟
- 服务器性能影响速度

---

## 📝 更新日志

### v0.7 (2026-01-19)

- ✨ 添加 SEO 标题后缀功能
- 🛡️ 增强错误处理机制
- 🗑️ 智能处理已删除话题
- 🎯 支持 API 筛选条件
- 📊 改进进度显示和统计

### v0.6

- 🔄 从文件导入改为 API 同步
- 📈 实时进度和错误日志
- ✨ 数据归一化和渲染

---

## 📄 许可证

MIT License

---

## 🙏 致谢

感谢 Discourse 社区的支持！

---

**开始使用，导入你的期刊数据库！** 🚀
