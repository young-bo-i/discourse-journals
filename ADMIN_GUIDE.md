# 管理员使用指南

## 📍 访问位置

### 1. 进入插件管理页面

在 Discourse 管理后台，通过以下路径访问：

```
管理员后台 → Plugins (插件) → Journals
```

具体步骤：

1. 点击右上角的头像
2. 点击 **Admin** (管理员) 进入管理后台
3. 在左侧菜单找到 **Plugins** (插件)
4. 在插件列表中找到 **Journals**
5. 点击进入插件管理页面

### 2. 访问路径

直接访问 URL：
```
https://your-discourse-site.com/admin/plugins/journals
```

## 🎯 前提条件

### 必须完成的设置

在使用插件前，需要先配置以下设置：

1. **启用插件**
   - 进入 `Admin → Settings → Plugins`
   - 找到 `discourse journals enabled`
   - 勾选启用

2. **配置期刊分类**
   - 进入 `Admin → Settings → Plugins`
   - 找到 `discourse journals category id`
   - 选择或创建一个分类（如 "Journals" 或 "期刊"）
   - 建议将该分类设置为只读，防止普通用户回复

3. **其他可选设置**
   - `discourse journals close topics`: 自动关闭期刊话题（推荐启用）
   - `discourse journals bypass bump`: 更新时不置顶（推荐启用）

## 📤 使用插件导入期刊

### 界面说明

进入插件页面后，你会看到：

```
┌─────────────────────────────────────────┐
│ Journals                                │
├─────────────────────────────────────────┤
│                                         │
│ Import Journals                         │
│                                         │
│ Upload a JSON file containing journal  │
│ data from OpenAlex, Crossref, DOAJ,    │
│ NLM, and Wikidata. The system will     │
│ create or update journal topics based   │
│ on the ISSN.                            │
│                                         │
│ JSON file (.json)                       │
│ [选择文件]                               │
│                                         │
│ [Start import]                          │
│                                         │
└─────────────────────────────────────────┘
```

### 导入步骤

1. **准备 JSON 文件**
   - 格式：期刊对象数组
   - 必需字段：`primary_issn`、`unified_index.title`
   - 参考：`1.json` 文件格式

2. **选择文件**
   - 点击 "选择文件" 按钮
   - 选择你的 JSON 文件（如 `1.json`）

3. **开始导入**
   - 点击 "Start import" 按钮
   - 系统会显示成功消息："Import started successfully"

4. **后台处理**
   - 导入在后台异步进行，不会阻塞界面
   - 大文件可能需要几分钟处理时间

5. **查看结果**
   - 进入你配置的期刊分类
   - 查看创建或更新的期刊话题

## 📊 导入后会发生什么

### 创建新期刊

如果 JSON 中的期刊（按 `primary_issn` 识别）在系统中不存在：

- ✅ 创建新话题
- ✅ 标题格式：`{期刊名称} ({ISSN})`
- ✅ 内容包含9大类信息
- ✅ 自动关闭话题（只读）

### 更新现有期刊

如果期刊已存在：

- ✅ 更新话题内容
- ✅ 保留话题 URL 和 ID
- ✅ 使用最新数据重新生成内容
- ✅ 不会置顶（如果启用了 bypass_bump）

## 📝 期刊话题内容结构

每个期刊话题包含以下段落：

### 1. 期刊身份 (Journal Identity)
- 期刊主标题、别名
- ISSN-L、ISSN 列表、类型明细表格
- 期刊主页、官方网站集合
- 外部 ID（OpenAlex、Wikidata、NLM）

### 2. 出版信息 (Publication Information)
- 出版机构名称、国家/地区
- 出版起始年份（多来源对比）
- 语言

### 3. 开放获取与费用 (Open Access & Fees)
- OA 状态、DOAJ 收录信息
- 许可证列表
- APC 价格（含主值和候选值）
- 减免政策

### 4. 同行评审与伦理合规 (Peer Review & Ethics)
- 审稿方式
- 编委会、投稿指南链接
- 反抄袭检测
- 出版周期

### 5. 归档保存与索引政策 (Preservation & Archiving)
- 长期保存服务（CLOCKSS）
- 国家图书馆保存
- 存储政策

### 6. 学科与主题 (Subjects & Topics)
- 学科分类
- 关键词
- OpenAlex 主题 Top 5

### 7. 产出与影响 (Output & Impact)
- 论文总数、被引总数
- h-index、i10-index
- 年度产出统计表格

### 8. Crossref 元数据质量 (Crossref Metadata Quality)
- DOI 统计
- DOI 年份分布表格

### 9. NLM 编目信息 (NLM Cataloging)
- MEDLINE 缩写
- 索引状态

**注意**：只展示有数据的段落，空数据会自动过滤。

## 🔄 重复导入

### 支持场景

- ✅ 更新现有期刊信息
- ✅ 在现有导入中添加新期刊
- ✅ 定期刷新所有期刊数据

### 识别逻辑

系统通过 `primary_issn` 字段识别期刊：

- 相同 ISSN → 更新话题
- 新 ISSN → 创建话题

### 最佳实践

1. **定期更新**：每月或每季度重新导入最新数据
2. **增量导入**：可以只导入新增或更新的期刊
3. **全量刷新**：需要时可以导入完整数据库

## 🔍 查看导入进度

### 方法1：查看服务器日志

SSH 登录服务器，查看日志：

```bash
# 查看实时日志
tail -f /var/www/discourse/log/production.log

# 搜索导入相关日志
grep "DiscourseJournals" /var/www/discourse/log/production.log
```

日志示例：
```
[DiscourseJournals] Import completed: 100 processed, 80 created, 20 updated, 0 skipped, 0 errors
```

### 方法2：检查 Sidekiq

进入 Sidekiq 管理页面：
```
https://your-discourse-site.com/sidekiq
```

查看 `Jobs::DiscourseJournals::ImportJson` 任务状态。

### 方法3：查看期刊分类

直接进入期刊分类，查看新创建或更新的话题。

## ❗ 常见问题

### 1. 导入按钮没反应

**可能原因**：
- 未选择文件
- 文件格式不正确（必须是 .json）
- JavaScript 错误

**解决方法**：
- 确保选择了 JSON 文件
- 检查浏览器控制台是否有错误
- 刷新页面重试

### 2. 提示缺少分类

**错误信息**：
```
Select a journals category in site settings.
```

**解决方法**：
- 进入 `Admin → Settings → Plugins`
- 设置 `discourse journals category id`
- 选择一个有效的分类

### 3. 导入后没看到话题

**可能原因**：
- 后台任务还在处理
- JSON 格式错误
- 分类权限问题

**解决方法**：
- 等待几分钟（大文件需要更长时间）
- 检查服务器日志是否有错误
- 确认你有权限查看该分类

### 4. 某些字段没显示

**原因**：
- 数据源缺失该字段
- 所有来源都没有该字段的数据

**说明**：
这是正常行为，系统会自动过滤空字段。

## 📞 技术支持

如需帮助，请查看：

- **插件文档**：`README.md`
- **设计文档**：`MASTER_RECORD_DESIGN.md`
- **修复记录**：`ZEITWERK_FIX.md`

或联系系统管理员。

---

**最后更新**：2026-01-19
