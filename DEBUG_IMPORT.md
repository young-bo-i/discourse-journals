# 🔍 导入调试指南

## 问题诊断

导入后显示：
- ✅ "导入在后台运行..." - 正常
- ⚠️ `Translation missing: zh_CN.discourse_journals.admin.imports.started` - 翻译缺失

## 🚨 立即检查

### 1. 查看后台任务日志

```bash
# SSH 到服务器
ssh user@server

# 查看最近的日志（最重要！）
cd /var/www/discourse
tail -100 log/production.log | grep -i "journal\|import"

# 实时监控日志
tail -f log/production.log | grep -i "journal"
```

### 2. 检查 Sidekiq 任务状态

```bash
cd /var/www/discourse

# 检查队列中的任务
sudo -u discourse bin/rails runner "
  puts '=== Sidekiq Queue ==='
  Sidekiq::Queue.new.each do |job|
    if job.klass.include?('Journal')
      puts \"Job: #{job.klass}\"
      puts \"Args: #{job.args}\"
      puts \"Created: #{job.created_at}\"
      puts '---'
    end
  end
"

# 检查失败的任务
sudo -u discourse bin/rails runner "
  puts '=== Failed Jobs ==='
  Sidekiq::DeadSet.new.each do |job|
    if job.klass.include?('Journal')
      puts \"Job: #{job.klass}\"
      puts \"Error: #{job.item['error_message']}\"
      puts \"Backtrace: #{job.item['error_backtrace']&.first(5)}\"
      puts '---'
    end
  end
"
```

### 3. 检查上传的文件

```bash
cd /var/www/discourse

# 查找最近上传的 JSON 文件
find public/uploads -name "*.json" -type f -mtime -1 -ls

# 或者检查数据库
sudo -u discourse bin/rails runner "
  upload = Upload.where('original_filename LIKE ?', '%.json')
    .order(created_at: :desc)
    .first
  if upload
    puts \"Upload ID: #{upload.id}\"
    puts \"Filename: #{upload.original_filename}\"
    puts \"Path: #{upload.url}\"
    puts \"Size: #{upload.filesize}\"
    puts \"Created: #{upload.created_at}\"
  else
    puts 'No JSON uploads found'
  end
"
```

### 4. 手动触发导入（测试）

如果后台任务卡住了，可以手动触发：

```bash
cd /var/www/discourse

# 替换 123 为实际的 upload_id
sudo -u discourse bin/rails runner "
  upload_id = 123  # 从上一步获取
  job_args = { upload_id: upload_id }
  Jobs::DiscourseJournals::ImportJson.new.execute(job_args)
"
```

## 🔧 修复翻译问题

翻译文件已存在，但可能需要清除缓存：

```bash
cd /var/www/discourse

# 清除缓存
sudo -u discourse bin/rails runner "Rails.cache.clear"

# 重启 Unicorn
sv restart unicorn

# 清除浏览器缓存
# 浏览器按 Ctrl+Shift+Del
```

## 📊 常见错误

### 错误1：文件路径错误

```
Errno::ENOENT: No such file or directory @ rb_sysopen - /path/to/file.json
```

**原因**：Upload 对象的路径可能不正确  
**修复**：检查 `admin_imports_controller.rb` 中的文件路径获取

### 错误2：JSON 解析错误

```
JSON::ParserError: unexpected token at '...'
```

**原因**：JSON 文件格式不正确  
**修复**：验证 JSON 文件：

```bash
# 在本地验证
cat /Users/youngp/discourse/1.json | jq . > /dev/null && echo "JSON valid"
```

### 错误3：数据库连接超时

```
PG::ConnectionBad: could not connect to server
```

**原因**：导入时间过长，连接断开  
**修复**：增加 Sidekiq 超时时间

### 错误4：内存不足

```
Killed (signal 9)
```

**原因**：JSON 文件太大（如你的 29951 行文件）  
**修复**：分批处理或增加内存

## 🎯 期望的正常日志

成功导入应该看到：

```
Started POST "/admin/journals/imports" for xxx.xxx.xxx.xxx
Processing by DiscourseJournals::AdminImportsController#create
Parameters: {"file"=>#<ActionDispatch::Http::UploadedFile...>}
Upload created: id=123, filename=1.json
Enqueued Jobs::DiscourseJournals::ImportJson with upload_id=123

[Sidekiq] Jobs::DiscourseJournals::ImportJson started
[Sidekiq] Processing JSON file: /path/to/1.json
[Sidekiq] Found 50 journals in file
[Sidekiq] Processing journal 1/50: Agronomy (2073-4395)
[Sidekiq] Created topic: "Agronomy (2073-4395)"
...
[Sidekiq] Import completed: 45 created, 5 updated, 0 failed
[Sidekiq] Jobs::DiscourseJournals::ImportJson completed in 45.2s
```

## 🚀 快速诊断命令

复制整个命令块到服务器：

```bash
#!/bin/bash
cd /var/www/discourse

echo "=== 1. 最近日志 ==="
tail -50 log/production.log | grep -i "journal\|import" | tail -20

echo -e "\n=== 2. Sidekiq 队列 ==="
sudo -u discourse bin/rails runner "
  count = Sidekiq::Queue.new.select { |j| j.klass.include?('Journal') }.count
  puts \"Queue中有 #{count} 个Journal任务\"
"

echo -e "\n=== 3. 失败任务 ==="
sudo -u discourse bin/rails runner "
  failed = Sidekiq::DeadSet.new.select { |j| j.klass.include?('Journal') }
  puts \"失败任务数: #{failed.count}\"
  failed.first(3).each do |job|
    puts \"Error: #{job.item['error_message']}\"
  end
"

echo -e "\n=== 4. 最近上传 ==="
sudo -u discourse bin/rails runner "
  upload = Upload.where('original_filename LIKE ?', '%.json')
    .order(created_at: :desc)
    .first
  puts upload ? \"最近上传: #{upload.original_filename} (ID: #{upload.id})\" : '无上传'
"
```

## 📝 报告问题时提供

如果仍有问题，请提供：

1. 上述诊断命令的完整输出
2. `log/production.log` 中包含 "journal" 或 "import" 的行
3. 错误消息的完整堆栈跟踪
4. JSON 文件大小和记录数

---

**下一步**：先运行诊断命令，查看具体错误信息！
