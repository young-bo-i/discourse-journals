# 🔍 文件上传失败调试指南

## 错误信息

```
Import failed: 验证失败: Upload 不能为空
```

## 可能的原因

### 1. 文件太大

检查设置：
```bash
ssh user@server
cd /var/www/discourse
sudo -u discourse bin/rails runner "
  puts \"最大文件大小: #{SiteSetting.max_attachment_size_kb} KB (#{(SiteSetting.max_attachment_size_kb / 1024.0).round(2)} MB)\"
"
```

如果你的 `1.json` 文件很大（29951行可能有几十MB），需要增加限制：

**Admin → Settings → Files → max attachment size kb**

建议设置为：**102400** (100 MB)

### 2. 文件类型限制

检查允许的扩展名：
```bash
sudo -u discourse bin/rails runner "
  puts \"允许的扩展名: #{SiteSetting.authorized_extensions}\"
"
```

确保包含 `json`。如果没有，在：

**Admin → Settings → Files → authorized extensions**

添加：`json`

### 3. MIME 类型问题

JSON 文件的 MIME 类型可能不被接受。我已经在代码中修改为：
```ruby
type: "application/json"  # 标准 MIME 类型
```

### 4. 文件权限/临时目录

检查临时目录：
```bash
ssh user@server
cd /var/www/discourse
sudo -u discourse bin/rails runner "
  puts \"Temp dir: #{Dir.tmpdir}\"
  puts \"Writable: #{File.writable?(Dir.tmpdir)}\"
"
```

### 5. Nginx 上传限制

检查 Nginx 配置：
```bash
ssh user@server
grep client_max_body_size /etc/nginx/nginx.conf
```

如果太小（如 1m），需要增加：
```nginx
client_max_body_size 100M;
```

然后重启 Nginx：
```bash
sudo service nginx restart
```

## 🔧 立即修复步骤

### 步骤 1：增加文件大小限制

1. 访问 **Admin → Settings → Files**
2. 设置 **max_attachment_size_kb** = `102400` (100 MB)
3. 确保 **authorized_extensions** 包含 `json`

### 步骤 2：检查 Nginx 配置

```bash
ssh user@server

# 检查当前配置
grep -r "client_max_body_size" /etc/nginx/

# 如果需要修改（在 Discourse 容器中）
cd /var/discourse
./launcher enter app

# 在容器中编辑
vi /etc/nginx/conf.d/discourse.conf

# 添加或修改
client_max_body_size 100M;

# 退出容器
exit

# 重启容器
cd /var/discourse
./launcher restart app
```

### 步骤 3：部署改进的错误处理代码

```bash
# 本地
cd /Users/youngp/discourse/plugins/discourse-journals
git add .
git commit -m "Improve upload error handling and validation"
git push

# 服务器
ssh user@server
cd /var/www/discourse/plugins/discourse-journals
git pull
cd /var/www/discourse
sv restart unicorn
```

### 步骤 4：查看详细日志

```bash
ssh user@server
tail -f /var/www/discourse/log/production.log | grep -i "DiscourseJournals\|Upload"
```

然后重新尝试上传，查看具体错误。

## 🎯 快速测试

创建一个小的测试 JSON 文件：

```bash
# 本地
cd /Users/youngp/discourse
head -100 1.json > test-small.json
```

先上传这个小文件测试是否是文件大小问题。

## 📊 检查清单

- [ ] `max_attachment_size_kb` ≥ 文件大小（KB）
- [ ] `authorized_extensions` 包含 `json`
- [ ] Nginx `client_max_body_size` ≥ 文件大小
- [ ] 临时目录可写
- [ ] 日志中没有权限错误

## 🔍 获取详细错误信息

更新代码后，错误消息会更详细，显示：
- 具体哪个步骤失败
- 文件大小
- JSON 验证错误（如果有）
- Upload 对象的错误信息

---

按照这些步骤排查，应该能找到问题！最可能的原因是**文件大小限制**。
