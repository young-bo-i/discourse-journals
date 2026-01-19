# 📊 SEO 标题后缀功能

## ✨ 功能说明

为期刊话题的 HTML `<title>` 标签自动添加 SEO 友好的后缀，提升搜索引擎收录效果。

## 🎯 效果演示

### HTML 源码中

```html
<head>
  <title>Agronomy (2073-4395) - 期刊详情 | 学术期刊库 | 开放获取期刊</title>
  <meta name="description" content="...">
</head>
```

### 页面显示

```
标题栏：Agronomy (2073-4395) - 期刊详情 | 学术期刊库 | 开放获取期刊
页面内容：Agronomy (2073-4395)  ← 没有后缀
```

## ⚙️ 配置方法

### 1. 访问设置页面

```
Admin → Settings → Plugins → discourse-journals
```

### 2. 找到配置项

**discourse_journals_title_suffix**

### 3. 设置后缀文案

**默认值**:
```
期刊详情 | 学术期刊库 | 开放获取期刊
```

**自定义示例**:
```
Journal Details | Academic Database | Open Access
学术期刊 | SCI收录 | 影响因子查询
期刊信息 | ISSN查询 | 开放获取数据库
```

### 4. 保存设置

点击 "Save Changes"

## 🔍 SEO 优势

### 1. 提升关键词密度

```html
<!-- 之前 -->
<title>Agronomy (2073-4395)</title>

<!-- 之后 -->
<title>Agronomy (2073-4395) - 期刊详情 | 学术期刊库 | 开放获取期刊</title>
```

**SEO 价值**:
- ✅ 增加相关关键词
- ✅ 提高搜索匹配度
- ✅ 改善点击率

### 2. 搜索结果展示

**Google 搜索结果**:
```
Agronomy (2073-4395) - 期刊详情 | 学术期刊库
https://your-site.com/t/agronomy/123
期刊信息、影响因子、开放获取政策等详细数据...
```

### 3. 关键词建议

#### 中文站点

```
期刊详情 | 学术期刊库 | 开放获取期刊
SCI期刊 | 影响因子查询 | ISSN数据库
学术期刊 | 论文发表 | 期刊评价
```

#### 英文站点

```
Journal Details | Academic Database | Open Access
Scientific Journal | Impact Factor | ISSN Lookup
Research Journal | Publication Database
```

#### 行业特定

```
医学期刊 | PubMed收录 | 临床研究
工程期刊 | IEEE收录 | 技术论文
计算机期刊 | ACM | CS期刊
```

## 🎨 最佳实践

### 1. 长度控制

**推荐**: 50-70 个字符
```
✅ 期刊详情 | 学术期刊库 | 开放获取期刊 (25字符)
✅ Journal Info | Academic DB | OA (30字符)
❌ 这是一个非常详细的学术期刊信息数据库平台包含了全球所有的开放获取期刊... (太长)
```

### 2. 分隔符使用

**推荐**: 使用 `|` 或 `-` 分隔
```
✅ 期刊详情 | 学术期刊库 | 开放获取
✅ 期刊详情 - 学术期刊库 - 开放获取
❌ 期刊详情，学术期刊库，开放获取 (逗号不够清晰)
```

### 3. 关键词顺序

**重要性递减排列**:
```
最重要 → 次重要 → 一般

✅ 期刊详情 | 学术期刊库 | 开放获取
✅ SCI期刊 | 影响因子 | ISSN查询
```

### 4. 品牌词

```
✅ 期刊详情 | 你的品牌名 | 学术数据库
✅ Journal Info | YourBrand | Academic DB
```

## 🔧 技术实现

### 前端（JavaScript）

```javascript
// assets/javascripts/discourse/initializers/journals-title-suffix.js
api.modifyClass("controller:topic", {
  get documentTitle() {
    const topic = this.model;
    if (isJournalTopic(topic)) {
      const suffix = siteSettings.discourse_journals_title_suffix;
      return `${originalTitle} - ${suffix}`;
    }
    return originalTitle;
  }
});
```

### 特点

- ✅ 只修改 `<title>` 标签
- ✅ 不修改页面内容
- ✅ 不修改数据库
- ✅ 只对期刊分类生效
- ✅ 避免重复添加

## 📊 效果验证

### 1. 查看源代码

```bash
# 访问任意期刊话题
curl https://your-site.com/t/agronomy/123 | grep "<title>"

# 应该看到
<title>Agronomy (2073-4395) - 期刊详情 | 学术期刊库 | 开放获取期刊</title>
```

### 2. 浏览器检查

```
F12 → Elements → <head> → <title>
```

### 3. Google Search Console

```
1. 提交 sitemap
2. 等待索引
3. 查看标题显示
```

## ⚠️ 注意事项

### 1. 避免关键词堆砌

```
❌ 期刊期刊期刊学术学术学术数据库数据库
✅ 期刊详情 | 学术期刊库
```

### 2. 保持一致性

所有期刊使用相同的后缀，便于品牌建设。

### 3. 定期更新

根据 SEO 效果调整关键词。

### 4. 多语言支持

如果站点支持多语言，后缀也应该本地化。

## 📈 SEO 效果追踪

### Google Analytics

```
行为 → 网站内容 → 所有页面
筛选：/t/
```

### Google Search Console

```
效果 → 页面
筛选：期刊相关页面
查看：点击次数、展示次数、点击率
```

### 关键指标

- **搜索展示次数** - 后缀关键词是否带来更多展示
- **点击率 (CTR)** - 标题是否更吸引人
- **平均排名** - SEO 排名是否提升

## 🎯 示例配置

### 学术期刊站

```
期刊详情 | 影响因子 | 开放获取 | 学术期刊库
```

### 医学期刊站

```
医学期刊 | PubMed收录 | SCI期刊 | 临床研究
```

### 开放获取站

```
OA期刊 | 免费访问 | 开放获取 | 学术资源
```

### 多语言站

**中文**:
```
期刊详情 | 学术期刊库 | 开放获取
```

**英文**:
```
Journal Details | Academic Database | Open Access
```

---

**享受 SEO 优化带来的流量提升！** 📈
