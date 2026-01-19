# discourse-journals

期刊统一档案系统 - 在 Discourse 中管理只读的、SEO 友好的期刊目录，通过 JSON 导入维护，每个期刊对应一个话题。

## ✨ 核心特性

### 统一档案 (Master Record)

本插件实现了专业的"期刊统一档案"系统，整合来自5个权威数据源的信息：

- **OpenAlex**: 引用指标、主题分类、h-index、产出统计
- **Crossref**: DOI 统计、出版物分布、元数据质量
- **DOAJ**: 开放获取信息、APC 详情、审稿政策、许可证
- **NLM**: MEDLINE 索引、编目信息、出版方详情
- **Wikidata**: 官方网站、实体标识符

### 智能字段归一化

- ✅ **优先级规则**: 根据字段类型自动选择最可信来源
- ✅ **冲突处理**: 保留主值 + 候选值 + 来源标注
- ✅ **数组去重**: ISSN、关键词、网站等自动合并去重
- ✅ **空数据处理**: 安全处理数据源缺失情况
- ✅ **中文展示**: 所有字段使用中文名称，易于理解

### 其他特性

- 自动话题创建和更新（基于 ISSN）
- 只读期刊话题，防止用户修改
- SEO 友好结构，每个期刊独立页面
- 支持重复导入（自动识别更新）
- 后台异步处理，不阻塞界面

## 📋 设置步骤

1. 在站点设置中启用插件：`discourse_journals_enabled`
2. 创建期刊分类（例如："Journals"）并设置 `discourse_journals_category_id`
3. 将该分类设置为只读（防止普通用户回复）

## 🎯 管理界面

打开 `Admin → Plugins → Journals`

- **导入**: 上传 JSON 文件以导入/更新期刊话题

## 📄 JSON 文件格式

JSON 文件应为期刊对象数组。每个期刊对象包含：

```json
[
  {
    "primary_issn": "2073-4395",
    "unified_index": {
      "title": "期刊标题",
      "publisher": "出版方名称",
      "country": "US",
      "languages": ["EN"],
      "subjects": ["主题1", "主题2"],
      "is_open_access": 1,
      "in_doaj": 1,
      "in_nlm": 1,
      "has_wikidata": 1,
      "apc_has": 1,
      "apc_amount": 2000,
      "apc_currency": "USD",
      "homepage": "https://example.com",
      "works_count": 389,
      "cited_by_count": 11563,
      "updated_at": "2026-01-19 14:34:24"
    },
    "aliases": [
      {
        "issn": "2073-4395",
        "kind": "issn_l",
        "source": "openalex"
      }
    ],
    "sources_by_provider": {
      "crossref": {
        "source_name": "crossref_journal",
        "data": { /* Crossref API 响应 */ }
      },
      "doaj": {
        "source_name": "doaj_journal",
        "data": { /* DOAJ API 响应 */ }
      },
      "nlm": {
        "source_name": "nlm_esummary",
        "data": { /* NLM eSummary 响应 */ }
      },
      "openalex": {
        "source_name": "openalex_detail",
        "data": { /* OpenAlex API 响应 */ }
      },
      "wikidata": {
        "source_name": "wikidata_sparql",
        "data": { /* Wikidata SPARQL 响应 */ }
      }
    }
  }
]
```

### 必需字段

- `primary_issn`: 主要 ISSN 标识符（用于更新逻辑）
- `unified_index.title`: 期刊标题

### 可选字段

所有其他字段都是可选的。插件会展示可用数据并跳过缺失字段。

## 🔄 工作原理

### 导入流程

1. **上传**: 通过管理界面上传 JSON 文件
2. **处理**: 系统处理每个期刊条目：
   - 使用 `primary_issn` 检查是否已存在话题
   - 不存在则创建新话题
   - 存在则更新现有话题
3. **展示**: 每个期刊话题展示：
   - 期刊身份信息
   - 出版信息
   - 开放获取与费用
   - 同行评审与伦理合规
   - 归档保存政策
   - 学科与主题
   - 产出与影响指标
   - Crossref 元数据质量
   - NLM 编目信息

### 字段归一化策略

#### 优先级规则

| 字段类型 | 优先级顺序 | 原因 |
|---------|-----------|------|
| 事实型（出版方、国家） | DOAJ ≈ NLM ≈ OpenAlex > Crossref | 人工维护更可靠 |
| 政策型（审稿、版权） | DOAJ 优先 | DOAJ 核心价值 |
| 指标型（发文、被引） | OpenAlex 优先 | 统一计算体系 |
| 元数据质量 | Crossref 独占 | 独特的质量指标 |
| 编目型（MEDLINE） | NLM 优先 | 权威编目信息 |

#### 冲突处理

对于存在差异的字段（如 APC 价格）：

```markdown
**APC价格**:

- 主值: 2600 CHF (DOAJ)
- 候选值: 2000 CHF (OpenAlex)
- 美元估算: $2165 USD
```

对于时间字段：

```markdown
**出版起始年份**:
- 出版起始年份 (编目): 2011
- 出版起始年份 (统计推断): 1987
```

### 数据源缺失处理

系统优雅处理各种数据缺失场景：

- ✅ 单个数据源完全缺失 → 使用其他来源
- ✅ 数据源部分字段缺失 → 使用候选来源
- ✅ 所有来源都缺少某字段 → 该字段不展示
- ✅ 关键字段缺失 → 使用 fallback 链

## 🔁 重复导入

插件支持重复导入。当上传包含已存在期刊的 JSON 文件时（按 `primary_issn` 匹配）：

- 现有话题**更新**为新数据
- 新期刊**创建**新话题
- 话题内容根据最新数据重新生成

这允许您：
- 定期更新期刊信息
- 在现有导入中添加新期刊
- 刷新所有期刊数据

## 📊 话题结构

每个期刊话题自动生成以下段落：

### 1. 期刊身份 (Journal Identity)
- 期刊主标题、别名
- ISSN-L、ISSN 列表、类型明细
- 期刊主页、官方网站集合
- 外部标识符（OpenAlex, Wikidata, NLM）

### 2. 出版信息 (Publication Information)
- 出版机构名称、国家/地区、出版地
- 出版起始年份（多来源对比）
- OA 起始年份、终止年份
- 语言

### 3. 开放获取与费用 (Open Access & Fees)
- OA 状态、DOAJ 收录
- 作者版权、许可证列表
- APC 价格（主值+候选值）
- 减免政策

### 4. 同行评审与伦理合规 (Peer Review & Ethics)
- 审稿方式、审稿说明
- 编委会链接
- 反抄袭检测
- 投稿指南、OA 声明
- 出版周期

### 5. 归档保存与索引政策 (Preservation & Archiving)
- 长期保存服务（CLOCKSS 等）
- 国家图书馆保存
- 存储政策

### 6. 学科与主题 (Subjects & Topics)
- 学科分类
- 关键词
- OpenAlex 主题（Top 5）

### 7. 产出与影响 (Output & Impact)
- 论文总数、OA 论文数
- 被引总数、近2年平均被引
- h指数、i10指数
- 年度产出与引用统计

### 8. Crossref 元数据质量 (Crossref Metadata Quality)
- DOI 数量统计
- DOI 年份分布
- 元数据覆盖率

### 9. NLM 编目信息 (NLM Cataloging)
- MEDLINE 缩写
- 索引状态
- 资源类型
- 主题分类

## ⚙️ 配置项

- `discourse_journals_enabled`: 启用/禁用插件
- `discourse_journals_category_id`: 期刊话题的分类
- `discourse_journals_close_topics`: 自动关闭话题（只读）
- `discourse_journals_bypass_bump`: 更新时不置顶

## 🏗️ 技术架构

```
插件结构:
├── plugin.rb                              # 主插件文件
├── config/
│   ├── locales/                          # 翻译文件（中文字段名）
│   ├── routes.rb                         # API 路由
│   └── settings.yml                      # 插件设置
├── app/
│   ├── controllers/                      # API 控制器
│   ├── services/
│   │   ├── field_normalizer.rb          # 字段归一化
│   │   ├── master_record_renderer.rb    # 统一档案渲染
│   │   ├── json/importer.rb             # JSON 导入逻辑
│   │   └── journal_upserter.rb          # 话题创建/更新
│   └── jobs/                             # 后台任务
├── admin/assets/javascripts/             # 管理界面（Ember 组件）
└── spec/                                 # 测试文件
```

### 核心服务

**FieldNormalizer** - 字段归一化
- 将5个数据源映射到统一结构
- 处理字段名差异和嵌套数据
- 实现优先级和冲突处理规则

**MasterRecordRenderer** - 档案渲染
- 将归一化数据渲染为 Markdown
- 只展示有数据的段落和字段
- 多值字段展示主值+候选值

**JournalUpserter** - 话题管理
- 基于 ISSN 创建或更新话题
- 调用归一化和渲染服务
- 管理自定义字段

## 📚 更多文档

- [MASTER_RECORD_DESIGN.md](MASTER_RECORD_DESIGN.md) - 统一档案详细设计文档

## 📄 许可证

与 Discourse 核心相同（GPL v2.0+）
