# 🚀 导入进度和错误日志功能

## ✨ 新功能

### 1. 实时进度条
- 显示导入百分比（0-100%）
- 实时更新处理状态
- 显示详细统计：已处理/总数、新建、更新、错误数

### 2. 错误日志系统
- 只记录错误信息（不记录成功的）
- 显示错误摘要和详细堆栈
- 支持复制错误日志到剪贴板
- 支持展开/折叠错误列表

### 3. 后台任务追踪
- 数据库表 `discourse_journals_import_logs` 记录所有导入
- 状态：pending → processing → completed/failed
- 保存详细统计和错误信息

## 📦 新增文件

```
plugins/discourse-journals/
├── app/
│   ├── models/discourse_journals/
│   │   └── import_log.rb                    ← 导入日志 Model
│   ├── controllers/discourse_journals/
│   │   └── admin_imports_controller.rb      ← 更新：添加状态查询
│   ├── services/discourse_journals/
│   │   └── json_import/importer.rb          ← 更新：支持进度回调
│   └── jobs/regular/discourse_journals/
│       └── import_json.rb                   ← 更新：发送实时进度
├── db/migrate/
│   └── 20260119000001_create_import_logs.rb ← 数据库迁移
└── assets/javascripts/discourse/
    ├── controllers/
    │   └── admin-plugins-discourse-journals.js  ← 更新：进度监听
    └── templates/admin/
        └── plugins-discourse-journals.hbs       ← 更新：UI 显示
```

## 🎨 界面预览

### 导入中
```
┌─────────────────────────────────────────────┐
│ 期刊库                                       │
├─────────────────────────────────────────────┤
│ 导入期刊                                     │
│                                             │
│ [选择文件] 1.json                            │
│ [开始导入] (禁用中...)                       │
│                                             │
│ ┌───────────────────────────────────────┐  │
│ │ ███████████░░░░░░░░░░░░░░░░░ 45%      │  │
│ │ 已处理 45/100 (40 新建, 5 更新, 2 错误)│  │
│ └───────────────────────────────────────┘  │
│                                             │
│ 📊 已处理: 45/100                           │
│ ✅ 新建: 40  🔄 更新: 5  ❌ 错误: 2         │
└─────────────────────────────────────────────┘
```

### 完成（有错误）
```
┌─────────────────────────────────────────────┐
│ ✅ 导入完成！新建 95 个，更新 3 个           │
│                                             │
│ ❌ 错误日志 (2)                             │
│ [显示错误 ▼] [复制错误日志]                 │
│                                             │
│ ┌───────────────────────────────────────┐  │
│ │ 1. Row 23: Missing primary_issn        │  │
│ │    详细: ISSN: null, Title: xxx        │  │
│ │                                        │  │
│ │ 2. Row 45: JSON parse error            │  │
│ │    详细: Invalid UTF-8 at line 123    │  │
│ └───────────────────────────────────────┘  │
└─────────────────────────────────────────────┘
```

## 🔧 技术实现

### MessageBus 实时推送

**后端发送**（Job）:
```ruby
MessageBus.publish(
  "/journals/import/#{import_log_id}",
  {
    progress: 45.5,
    processed: 45,
    total: 100,
    message: "已处理 45/100...",
    status: "processing"
  },
  user_ids: [user_id]
)
```

**前端接收**（Controller）:
```javascript
this.messageBus.subscribe(`/journals/import/${id}`, (data) => {
  this.progress = data.progress;
  this.progressMessage = data.message;
  // 更新统计...
});
```

### 进度回调机制

**Importer**:
```ruby
def initialize(progress_callback: nil)
  @progress_callback = progress_callback
end

def report_progress(current, total, message)
  @progress_callback&.call(current, total, message)
end
```

**Job 调用**:
```ruby
importer = Importer.new(
  file_path: file_path,
  progress_callback: ->(current, total, message) {
    # 更新数据库 + 发送 MessageBus
  }
)
```

### 错误数据结构

```ruby
# 旧格式（字符串）
@errors << "Error message"

# 新格式（哈希）
@errors << { 
  message: "Row 23: Missing ISSN",
  details: "Title: xxx\nBacktrace: ..."
}
```

数据库存储（JSONB）:
```json
{
  "errors_data": [
    {
      "message": "Row 23: Missing ISSN",
      "details": "...",
      "timestamp": "2026-01-19T10:30:45Z"
    }
  ]
}
```

## 🚀 部署步骤

### 1. 打包上传
```bash
cd /Users/youngp/discourse
tar czf journals-progress.tar.gz plugins/discourse-journals
scp journals-progress.tar.gz user@server:/tmp/
```

### 2. 服务器部署
```bash
ssh user@server

# 部署文件
cd /tmp
tar xzf journals-progress.tar.gz
sudo rm -rf /var/www/discourse/plugins/discourse-journals
sudo mv plugins/discourse-journals /var/www/discourse/plugins/
sudo chown -R discourse:discourse /var/www/discourse/plugins/discourse-journals

# 运行数据库迁移（重要！）
cd /var/www/discourse
sudo -u discourse bin/rails db:migrate

# 清除缓存
sudo -u discourse bin/rails runner "Rails.cache.clear"

# 重启
sv restart unicorn
```

### 3. 验证部署
```bash
# 检查迁移
sudo -u discourse bin/rails runner "
  puts DiscourseJournals::ImportLog.table_name
  puts DiscourseJournals::ImportLog.column_names
"

# 应该输出：
# discourse_journals_import_logs
# ["id", "upload_id", "user_id", "status", ...]
```

## 📊 API 端点

### 1. 创建导入
```
POST /admin/journals/imports
Body: { file: <JSON file> }

Response: {
  "status": "started",
  "upload_id": 123,
  "import_log_id": 456
}
```

### 2. 查询状态
```
GET /admin/journals/imports/:id/status

Response: {
  "id": 456,
  "status": "processing",
  "progress": 45.5,
  "processed_records": 45,
  "total_records": 100,
  "created_count": 40,
  "updated_count": 5,
  "error_count": 2,
  "errors": [
    {
      "message": "...",
      "details": "...",
      "timestamp": "..."
    }
  ]
}
```

### 3. 查询历史
```
GET /admin/journals/imports/logs?limit=50

Response: {
  "logs": [
    {
      "id": 456,
      "status": "completed",
      "created_count": 95,
      "error_count": 2,
      ...
    }
  ]
}
```

## 🎯 使用流程

1. 用户上传 JSON 文件
2. 创建 `ImportLog` 记录（status: pending）
3. Job 入队并开始处理（status: processing）
4. 每处理 10 个记录：
   - 更新 `ImportLog`
   - 通过 MessageBus 推送进度
   - 前端实时更新 UI
5. 完成后（status: completed/failed）：
   - 保存最终统计
   - 只保存错误日志（不保存成功记录）
   - 前端显示结果和错误列表

## 💡 特性

### 只记录错误
- ✅ 不记录成功处理的期刊
- ✅ 只记录失败/跳过的条目
- ✅ 包含详细的错误信息和堆栈
- ✅ 支持 JSONB 结构化存储

### 实时进度
- ✅ 百分比进度条
- ✅ 当前/总数统计
- ✅ 每 10 个更新一次（减少数据库写入）
- ✅ MessageBus 推送到特定用户

### 用户体验
- ✅ 美观的进度条动画
- ✅ 可展开/折叠的错误列表
- ✅ 一键复制错误日志
- ✅ 导入期间禁用按钮防止重复提交

---

**完成！** 🎉

现在用户可以：
1. 看到实时导入进度
2. 查看详细的错误日志
3. 复制错误信息用于调试
