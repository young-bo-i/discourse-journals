# 最简单的部署方式

## 🚀 一键部署

```bash
# 1. 从本地完整上传插件目录
cd /Users/youngp/discourse
tar czf discourse-journals.tar.gz plugins/discourse-journals
scp discourse-journals.tar.gz user@your-server:/tmp/

# 2. 在服务器上解压和部署
ssh user@your-server << 'EOF'
cd /tmp
tar xzf discourse-journals.tar.gz
sudo rm -rf /var/www/discourse/plugins/discourse-journals
sudo mv plugins/discourse-journals /var/www/discourse/plugins/
sudo chown -R discourse:discourse /var/www/discourse/plugins/discourse-journals
cd /var/www/discourse
sv restart unicorn
EOF
```

## 📝 或者分步骤

### 步骤1：打包

```bash
cd /Users/youngp/discourse
tar czf discourse-journals.tar.gz plugins/discourse-journals
```

### 步骤2：上传

```bash
scp discourse-journals.tar.gz user@your-server:/tmp/
```

### 步骤3：部署

SSH 登录服务器：
```bash
ssh user@your-server
cd /tmp
tar xzf discourse-journals.tar.gz
sudo rm -rf /var/www/discourse/plugins/discourse-journals
sudo mv plugins/discourse-journals /var/www/discourse/plugins/
sudo chown -R discourse:discourse /var/www/discourse/plugins/discourse-journals
cd /var/www/discourse
sv restart unicorn
```

## ✅ 访问

重启后访问：
```
http://你的域名/admin/journals
```

## 🔍 检查路由

```bash
cd /var/www/discourse
sudo -u discourse RAILS_ENV=production bin/rails routes | grep journals
```

应该看到：
```
GET  /admin/journals          discourse_journals/admin#index
POST /admin/journals/imports  discourse_journals/admin_imports#create
```

## 🐛 如果还是 404

### 1. 检查文件权限

```bash
ls -la /var/www/discourse/plugins/discourse-journals/
ls -la /var/www/discourse/plugins/discourse-journals/app/controllers/
ls -la /var/www/discourse/plugins/discourse-journals/app/views/
```

所有文件应该是 `discourse:discourse` 所有者。

### 2. 检查控制器文件

```bash
cat /var/www/discourse/plugins/discourse-journals/app/controllers/discourse_journals/admin_controller.rb
```

应该看到控制器代码。

### 3. 检查视图文件

```bash
cat /var/www/discourse/plugins/discourse-journals/app/views/discourse_journals/admin/index.html.erb
```

应该看到 HTML 代码。

### 4. 查看日志

```bash
tail -f /var/www/discourse/log/production.log
```

然后访问 `/admin/journals`，看日志中的错误信息。

### 5. 完全重启

如果以上都不行：

```bash
cd /var/discourse
./launcher restart app
```

## 💡 测试路由

在服务器上，进入 Rails 控制台：

```bash
cd /var/www/discourse
sudo -u discourse RAILS_ENV=production bin/rails c
```

然后执行：

```ruby
# 检查插件是否加载
Discourse.plugins.map(&:name)
# 应该包含 "discourse-journals"

# 检查路由
Rails.application.routes.routes.select { |r| r.path.spec.to_s.include?('journals') }

# 退出
exit
```

## 📋 关键文件清单

确保以下文件都存在：

```
plugins/discourse-journals/
├── plugin.rb                                          ← 核心
├── app/
│   ├── controllers/discourse_journals/
│   │   ├── admin_controller.rb                       ← 控制器
│   │   └── admin_imports_controller.rb               ← 导入控制器
│   ├── views/discourse_journals/admin/
│   │   └── index.html.erb                            ← 视图
│   ├── services/...
│   └── jobs/...
├── config/
│   └── routes.rb                                      ← 路由
└── lib/discourse_journals/
    └── engine.rb                                      ← Engine
```

---

**如果所有方法都试过还是不行，请提供：**
1. 日志输出（production.log）
2. 路由列表输出
3. 文件权限列表

这样我们才能准确定位问题！
