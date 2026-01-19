# 🔧 上传失败修复总结

## 📊 你的文件

- **文件名**: `1.json`
- **大小**: 1.0 MB
- **行数**: 29,951

## ❌ 错误信息

```
Import failed: 验证失败: Upload 不能为空
```

## 🎯 最可能的原因（按概率排序）

### 1. 文件类型限制 (90%)

Discourse 默认可能不允许上传 `.json` 文件。

**修复**：
1. 访问 `/admin/site_settings/category/files`
2. 找到 **authorized_extensions**
3. 添加 `json`（用 `|` 分隔，例如：`jpg|jpeg|png|gif|json`）

### 2. 文件大小限制 (8%)

虽然你的文件只有 1MB，但默认限制可能更小。

**修复**：
1. 访问 `/admin/site_settings/category/files`
2. 找到 **max_attachment_size_kb**
3. 设置为 `10240` (10 MB) 或更大

### 3. MIME 类型问题 (2%)

我已经在代码中修复了这个问题：
```ruby
type: "application/json"  # 之前是 "json"
```

## 🚀 快速修复步骤

### 方法1：通过管理界面（推荐）

1. 登录管理后台
2. 访问 **Admin → Settings → Files**
3. 修改以下设置：
   - `authorized_extensions`: 添加 `json`
   - `max_attachment_size_kb`: 设置为 `10240` 或更大
4. 保存设置
5. 重新尝试上传

### 方法2：通过命令行

```bash
ssh user@server
cd /var/www/discourse

# 检查当前设置
sudo -u discourse bin/rails runner "
  puts SiteSetting.authorized_extensions
  puts SiteSetting.max_attachment_size_kb
"

# 添加 json 扩展名
sudo -u discourse bin/rails runner "
  exts = SiteSetting.authorized_extensions
  unless exts.split('|').include?('json')
    SiteSetting.authorized_extensions = exts + '|json'
    puts 'Added json to authorized_extensions'
  end
"

# 增加文件大小限制（可选）
sudo -u discourse bin/rails runner "
  SiteSetting.max_attachment_size_kb = 10240
  puts 'Set max_attachment_size_kb to 10240 (10 MB)'
"
```

## 🔧 部署改进的代码

我已经改进了错误处理，会显示更详细的错误信息：

```bash
cd /Users/youngp/discourse/plugins/discourse-journals
git add .
git commit -m "Improve upload validation and error messages"
git push

# 服务器
ssh user@server
cd /var/www/discourse/plugins/discourse-journals
git pull
cd /var/www/discourse
sv restart unicorn
```

## 📊 诊断工具

运行检查脚本：
```bash
cd /Users/youngp/discourse/plugins/discourse-journals
./CHECK_UPLOAD_SETTINGS.sh
```

这会显示：
- ✅ 当前文件大小限制
- ✅ 允许的文件扩展名
- ✅ JSON 是否允许
- ✅ Nginx 配置
- ✅ 临时目录状态

## 🎯 更新后的错误提示

部署新代码后，如果还有问题，你会看到更明确的错误：

- ❌ "无效的 JSON 文件: ..." - JSON 格式问题
- ❌ "文件太大 (X MB)，最大允许 Y MB" - 大小限制
- ❌ "文件上传失败: [具体原因]" - Upload 对象错误

## ✅ 验证修复

修复后，再次上传应该能看到进度条：

```
┌─────────────────────────────────────┐
│ ███████░░░░░░░░░░░░░░░░ 35%        │
│ 已处理 350/1000                     │
│ ✅ 新建: 300  🔄 更新: 50          │
└─────────────────────────────────────┘
```

---

**下一步**: 先运行 `./CHECK_UPLOAD_SETTINGS.sh` 诊断，然后按照结果修复！
