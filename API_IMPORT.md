# 🚀 REST API 批量导入 - 最佳方案

## ✨ 优势

✅ **不需要上传文件** - 直接发送 JSON 数据  
✅ **不占用服务器存储** - 即时处理，不保存临时文件  
✅ **可断点续传** - 分批导入，失败可重试  
✅ **进度可控** - 客户端控制速度和批次  
✅ **适合超大数据集** - 15万个期刊也轻松处理  
✅ **编程友好** - 易于集成到自动化流程  

## 📡 API 端点

### 1. 批量导入期刊

```http
POST /discourse-journals/api/journals/batch
Content-Type: application/json
Api-Key: your_api_key
Api-Username: admin

{
  "journals": [
    {
      "primary_issn": "2073-4395",
      "unified_index": {
        "title": "Agronomy"
      },
      "aliases": ["Agronomy (Basel)"],
      "sources_by_provider": {
        "openalex": { "data": {...} },
        "crossref": { "data": {...} },
        ...
      }
    },
    ...  // 最多 500 个
  ]
}
```

**响应**:
```json
{
  "success": true,
  "results": {
    "total": 100,
    "created": 85,
    "updated": 10,
    "skipped": 5,
    "errors": ["索引 23: Missing ISSN"]
  },
  "message": "导入完成：85 新建，10 更新，5 跳过"
}
```

### 2. 查询期刊

```http
GET /discourse-journals/api/journals/:issn
Api-Key: your_api_key
Api-Username: admin
```

## 🐍 Python 客户端使用

### 安装依赖
```bash
pip install requests
```

### 基本使用

```python
from import_client import JournalsApiClient

# 初始化
client = JournalsApiClient(
    base_url="https://forum.example.com",
    api_key="your_api_key",
    username="admin"
)

# 读取 JSON 文件
import json
with open('journals.json') as f:
    journals = json.load(f)

# 批量导入（自动分批）
summary = client.batch_import(
    journals,
    batch_size=100,  # 每批 100 个
    delay=2.0        # 批次间隔 2 秒
)

print(f"成功: {summary['created']} 新建, {summary['updated']} 更新")
```

### 命令行使用

```bash
# 基本用法
python import_client.py journals.json https://forum.example.com your_api_key admin

# 自定义批次大小和延迟
python import_client.py journals.json https://forum.example.com your_api_key admin 200 3

# 对于 15 万个期刊
python import_client.py journals_150k.json https://forum.example.com your_api_key admin 500 1
```

## 📊 导入 15 万个期刊

### 预估时间

- **每批**: 500 个期刊
- **批次数**: 150,000 ÷ 500 = 300 批
- **每批耗时**: ~10 秒（处理 + 延迟）
- **总时间**: 300 × 10s = **50 分钟**

### 优化建议

```python
# 快速模式（服务器性能好）
client.batch_import(journals, batch_size=500, delay=0.5)
# 预计: 25 分钟

# 稳定模式（推荐）
client.batch_import(journals, batch_size=200, delay=2)
# 预计: 60 分钟

# 保守模式（服务器负载高）
client.batch_import(journals, batch_size=100, delay=5)
# 预计: 125 分钟
```

## 🔧 获取 API Key

1. 登录 Discourse 管理后台
2. 访问 **Admin → API → New API Key**
3. 设置：
   - **Description**: Journals Import
   - **User Level**: Single User → 选择管理员
   - **Scope**: All (Global)
4. 保存并复制 API Key

## 🎯 完整流程

### 步骤 1: 部署 API 端点

```bash
cd /Users/youngp/discourse/plugins/discourse-journals
git add .
git commit -m "Add REST API for batch import"
git push

# 服务器
ssh user@server
cd /var/www/discourse/plugins/discourse-journals
git pull
cd /var/www/discourse
sv restart unicorn
```

### 步骤 2: 准备 JSON 文件

确保你的 JSON 格式正确：
```json
[
  {
    "primary_issn": "...",
    "unified_index": { "title": "..." },
    "aliases": [...],
    "sources_by_provider": {...}
  },
  ...
]
```

### 步骤 3: 获取 API Key

见上面的说明。

### 步骤 4: 运行导入

```bash
cd /Users/youngp/discourse/plugins/discourse-journals/scripts

# 测试（前100个）
head -n 100 /Users/youngp/discourse/1.json > test.json
python import_client.py test.json \
  https://your-domain.com \
  your_api_key \
  admin

# 全量导入
python import_client.py /Users/youngp/discourse/journals_150k.json \
  https://your-domain.com \
  your_api_key \
  admin \
  500 \
  1
```

### 步骤 5: 监控进度

客户端会显示实时进度：
```
📊 总期刊数: 150,000
📦 每批数量: 500
⏱  批次延迟: 1s

[1/300] 导入 500 个期刊...
  ✅ 成功: 490 新建, 8 更新, 2 跳过
  ⏳ 等待 1s...

[2/300] 导入 500 个期刊...
  ✅ 成功: 495 新建, 3 更新, 2 跳过
  ⏳ 等待 1s...

...

[300/300] 导入 500 个期刊...
  ✅ 成功: 485 新建, 12 更新, 3 跳过

==================================================
🎉 导入完成！
✅ 新建: 149,234
🔄 更新: 523
⏭  跳过: 243
❌ 失败: 0
```

## 🔍 错误处理

- **自动重试**: 单个批次失败不影响其他批次
- **错误日志**: 自动保存到 `.errors.txt` 文件
- **断点续传**: 可以从失败的批次继续

## 🆚 方案对比

| 方案 | 文件上传 | API 导入 |
|------|---------|---------|
| 文件大小限制 | ❌ 有限制 | ✅ 无限制 |
| 存储占用 | ❌ 需要临时文件 | ✅ 不占用 |
| 超时问题 | ❌ 大文件超时 | ✅ 分批无超时 |
| 进度控制 | ❌ 无法控制 | ✅ 灵活控制 |
| 断点续传 | ❌ 不支持 | ✅ 支持 |
| 编程集成 | ❌ 困难 | ✅ 简单 |
| 15万期刊 | ❌ 不可行 | ✅ 50分钟 |

## 🎉 总结

**推荐使用 REST API 方案！**

- ✅ 专业、高效、可靠
- ✅ 适合任何规模的数据集
- ✅ 易于集成和自动化
- ✅ 不浪费存储空间

---

立即部署并开始导入你的 15 万个期刊！🚀
