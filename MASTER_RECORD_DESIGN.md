# 期刊统一档案 (Journal Master Record) 设计文档

## 概述

本插件实现了一个"期刊统一档案"系统，将来自5个数据源（OpenAlex、Crossref、DOAJ、NLM、Wikidata）的期刊信息归一化并整合为统一的展示结构。

## 核心设计原则

### 1. 字段归一化 (Field Normalization)

**目标**：将不同数据源的字段映射到统一的语义字段

**实现**：`FieldNormalizer` 服务

- 处理字段名差异（如 `display_name` vs `title`）
- 统一数据格式（日期、国家码、语言码）
- 提取嵌套数据结构

### 2. 优先级规则 (Priority Rules)

按字段类型分组设定优先级：

| 字段类型 | 优先级顺序 | 理由 |
|---------|-----------|------|
| 事实型字段（出版方、国家、主页） | DOAJ ≈ NLM ≈ OpenAlex > Crossref | 人工维护，更可靠 |
| 政策型字段（审稿、版权、许可证） | DOAJ 优先 | DOAJ 的核心价值 |
| 指标型字段（发文、被引、h-index） | OpenAlex 优先 | 统一计算体系 |
| 元数据质量（覆盖度） | Crossref 独占 | 独特的元数据指标 |
| 编目型字段（MEDLINE 缩写） | NLM 优先 | 无法替代的编目信息 |

### 3. 冲突处理 (Conflict Resolution)

#### 规则1：保留主值 + 证据列表

对于有差异的重要字段（如 APC 价格），保留：
- **主值**：最可信来源的值
- **候选值**：其他来源的值
- **说明**：差异原因

示例：
```json
{
  "apc_price": {
    "primary": {"price": 2600, "currency": "CHF", "source": "DOAJ"},
    "alternatives": [
      {"price": 2000, "currency": "CHF", "source": "OpenAlex"}
    ],
    "usd_estimate": 2165
  }
}
```

#### 规则2：数组字段做并集 + 去重

- ISSN 列表
- 关键词
- 主题
- 官方网站

#### 规则3：数值字段允许多口径并存

- `works_count` (OpenAlex) ≠ `total_dois` (Crossref)
- 两者含义不同，可同时展示

#### 规则4：时间字段区分来源

- 出版起始年份（编目）：NLM
- 出版起始年份（统计推断）：OpenAlex

### 4. 空数据处理 (Null Data Handling)

#### 设计原则

1. **安全导航**：使用 `safe_dig` 方法避免 nil 错误
2. **展示层过滤**：只展示有数据的段落
3. **字段层过滤**：空值字段不生成输出行
4. **默认值**：关键字段缺失时使用 `—` 占位

#### 实现细节

```ruby
# 安全提取嵌套数据
def safe_dig(hash, *keys)
  return nil if hash.nil?
  hash.dig(*keys)
end

# 检查段落是否有数据
def has_data?(section)
  return false if section.nil?
  section.values.any? { |v| v.present? }
end

# 字段值格式化
def format_value(value, type = :default)
  return "—" if value.nil? || (value.respond_to?(:empty?) && value.empty?)
  # ...
end
```

## 统一档案结构

### A. 身份与链接类

| 统一字段 | 含义 | 主要来源 |
|---------|------|---------|
| 期刊主标题 | 最常用名称 | Crossref / DOAJ / NLM / OpenAlex |
| 期刊别名/别题名 | 其他名称 | NLM / OpenAlex |
| ISSN-L | 链接ISSN（归一标识） | OpenAlex |
| ISSN列表 | 所有ISSN（去重） | 全部来源 |
| ISSN类型明细 | 每个ISSN的类型 | Crossref / NLM |
| 期刊主页 | 官方主页 | OpenAlex > DOAJ > Wikidata |
| 官方网站集合 | 所有网站 | Wikidata + DOAJ |
| 外部ID | OpenAlex ID, Wikidata ID, NLM ID | 各自来源 |

### B. 出版与地域类

| 统一字段 | 含义 | 主要来源 |
|---------|------|---------|
| 出版机构名称 | 出版方名称 | DOAJ > NLM > OpenAlex > Crossref |
| 出版机构国家/地区 | 国家码+国家名 | DOAJ / OpenAlex / NLM |
| 出版地 | 出版地点 | NLM |
| 出版起始年份（编目） | NLM编目年份 | NLM |
| 出版起始年份（统计） | 统计推断年份 | OpenAlex |
| OA起始年份 | 开放获取开始年 | DOAJ |
| 出版终止年份 | 停刊年份 | NLM |
| 语言 | 出版语言 | DOAJ / NLM |

### C. 开放获取与费用类

| 统一字段 | 含义 | 主要来源 |
|---------|------|---------|
| 是否开放获取 | OA状态 | OpenAlex / DOAJ |
| 是否收录DOAJ | DOAJ收录状态 | OpenAlex / DOAJ |
| DOAJ收录年份 | 进入DOAJ年份 | OpenAlex |
| 作者保留版权 | 版权归属 | DOAJ |
| 许可证列表 | CC许可证 | DOAJ |
| APC价格 | 文章处理费（多值） | DOAJ（主）+ OpenAlex（候选） |
| 是否有减免 | APC减免政策 | DOAJ |

### D. 同行评审与伦理合规

| 统一字段 | 含义 | 主要来源 |
|---------|------|---------|
| 审稿方式 | 同行评审类型 | DOAJ |
| 审稿说明链接 | 审稿流程页面 | DOAJ |
| 编委会链接 | 编委会页面 | DOAJ |
| 反抄袭检测 | 是否检测抄袭 | DOAJ |
| 投稿指南链接 | 作者指南 | DOAJ |
| 出版周期/速度 | 平均出版周期（周） | DOAJ |

### E. 归档保存与索引政策

| 统一字段 | 含义 | 主要来源 |
|---------|------|---------|
| 长期保存服务 | CLOCKSS等 | DOAJ |
| 国家图书馆保存 | 图书馆收存 | DOAJ |
| 存储政策 | 自存政策 | DOAJ |

### F. 学科与主题

| 统一字段 | 含义 | 主要来源 |
|---------|------|---------|
| 学科分类 | 学科分类体系 | DOAJ |
| 关键词 | 主题关键词 | DOAJ |
| OpenAlex主题 | 主题列表+占比 | OpenAlex |

### G. 产出、引用与指标

| 统一字段 | 含义 | 主要来源 |
|---------|------|---------|
| 论文总数 | 作品数 | OpenAlex |
| OA论文数 | OA作品数 | OpenAlex |
| 被引总数 | 被引次数 | OpenAlex |
| 近2年平均被引 | 影响力指标 | OpenAlex |
| h指数 | h-index | OpenAlex |
| i10指数 | i10-index | OpenAlex |
| 年度产出与引用 | 逐年统计 | OpenAlex |

### H. Crossref 元数据质量

| 统一字段 | 含义 | 主要来源 |
|---------|------|---------|
| DOI数量统计 | current/backfile/total | Crossref |
| DOI年份分布 | 按年分布 | Crossref |
| 元数据覆盖率 | 字段覆盖比例 | Crossref |
| 提交标记 | 元数据完整性 | Crossref |

### I. NLM 编目与索引信息

| 统一字段 | 含义 | 主要来源 |
|---------|------|---------|
| NLM标题排序键 | 规范化标题 | NLM |
| MEDLINE缩写 | 期刊缩写 | NLM |
| 当前索引状态 | MEDLINE索引状态 | NLM |
| 资源类型 | 期刊类型 | NLM |
| 主题分类 | 主题标引 | NLM |

## 技术实现

### 服务架构

```
FieldNormalizer      字段归一化
       ↓
  归一化数据
       ↓
MasterRecordRenderer 渲染器
       ↓
   Markdown内容
       ↓
  JournalUpserter    话题创建/更新
```

### 核心服务

#### 1. FieldNormalizer

**职责**：将各数据源字段映射到统一结构

**输入**：原始 journal_data
```json
{
  "primary_issn": "2073-4395",
  "unified_index": {...},
  "sources": {
    "crossref": {...},
    "doaj": {...},
    "nlm": {...},
    "openalex": {...},
    "wikidata": {...}
  }
}
```

**输出**：归一化数据
```json
{
  "identity": {...},
  "publication": {...},
  "open_access": {...},
  "review_compliance": {...},
  "preservation": {...},
  "subjects_topics": {...},
  "metrics": {...},
  "crossref_quality": {...},
  "nlm_cataloging": {...}
}
```

#### 2. MasterRecordRenderer

**职责**：将归一化数据渲染为Markdown

**特性**：
- 只渲染有数据的段落
- 空值字段自动过滤
- 多值字段展示主值+候选值
- 冲突字段标注来源

#### 3. JournalUpserter

**职责**：创建或更新期刊话题

**流程**：
1. 根据 ISSN 查找现有话题
2. 调用 FieldNormalizer 归一化数据
3. 调用 MasterRecordRenderer 生成内容
4. 创建/更新话题
5. 保存自定义字段

## 数据源缺失处理

### 场景1：单个数据源完全缺失

```ruby
# 示例：没有 Wikidata 数据
{
  "sources": {
    "crossref": {...},
    "doaj": {...},
    "nlm": {...},
    "openalex": {...},
    "wikidata": nil  # 或 {}
  }
}
```

**处理**：
- `safe_dig` 返回 nil
- 相关字段不展示
- 其他来源数据正常展示

### 场景2：数据源部分字段缺失

```ruby
# 示例：DOAJ 缺少 APC 信息
{
  "sources": {
    "doaj": {
      "bibjson": {
        "title": "...",
        "apc": nil  # 缺失
      }
    }
  }
}
```

**处理**：
- 使用候选来源（OpenAlex）
- 标注实际来源

### 场景3：所有来源都缺少某字段

```ruby
# 示例：所有来源都没有 APC 信息
```

**处理**：
- 字段不展示
- 段落可能为空
- `has_data?` 过滤空段落

### 场景4：关键字段缺失

```ruby
# 示例：缺少 title
```

**处理**：
- 使用 fallback 链：unified_index > openalex > crossref > doaj > nlm > journal_data[:name]
- 确保始终有标题

## 展示效果

### 完整数据的展示

```markdown
# 期刊身份 (Journal Identity)

- **期刊主标题**: Agronomy
- **ISSN-L (链接ISSN)**: 2073-4395
- **ISSN列表**: 2073-4395
- **期刊主页**: http://www.mdpi.com/journal/agronomy

**外部标识符**:

- **OpenAlex**: https://openalex.org/S2738977497
- **Wikidata**: Q27726978
- **NLM**: 101671521

# 出版信息 (Publication Information)

- **出版机构名称**: MDPI AG
- **出版机构国家/地区**: Switzerland / CH
- **出版地**: Basel, Switzerland

**出版起始年份**:
- 出版起始年份 (编目): 2011
- 出版起始年份 (统计推断): 1987

# 开放获取与费用 (Open Access & Fees)

- **是否开放获取**: 是
- **是否收录DOAJ**: 是
- **DOAJ收录年份**: 2011

**APC价格**:

- 主值: 2600 CHF (DOAJ)
- 候选值: 2000 CHF (OpenAlex)
- 美元估算: $2165 USD

...
```

### 部分数据缺失的展示

只展示有数据的段落和字段，空字段自动过滤。

## 扩展性

### 添加新数据源

1. 在 `FieldNormalizer` 中添加新来源的提取逻辑
2. 更新优先级规则
3. 更新国际化文件

### 添加新字段

1. 在 `FieldNormalizer` 的相应段落添加字段提取
2. 在 `MasterRecordRenderer` 中添加渲染逻辑
3. 在 `server.en.yml` 中添加翻译

### 修改优先级

在 `FieldNormalizer` 的提取方法中调整来源顺序：

```ruby
# 旧：Crossref 优先
crossref_value || doaj_value

# 新：DOAJ 优先
doaj_value || crossref_value
```

## 总结

本系统实现了：

✅ 五个数据源的字段归一化
✅ 基于字段类型的优先级规则
✅ 冲突处理（主值+候选值）
✅ 数组字段去重合并
✅ 空数据安全处理
✅ 中文字段展示
✅ 可扩展架构

通过这个设计，可以为每个期刊生成一个完整、准确、易读的统一档案。
