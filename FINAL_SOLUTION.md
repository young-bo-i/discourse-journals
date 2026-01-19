# 最终解决方案 - Rails 传统视图

## 🎯 方案说明

放弃复杂的 Ember 组件系统，使用**传统的 Rails 视图（ERB）**，这是最可靠的方法。

## 📦 核心文件

### 1. 控制器
```
app/controllers/discourse_journals/admin_controller.rb
```
简单的 Rails 控制器，渲染 index 页面。

### 2. 视图
```
app/views/discourse_journals/admin/index.html.erb
```
包含：
- HTML 表单
- 文件上传input
- JavaScript 处理提交
- 内联样式

### 3. 路由
```
config/routes.rb
```
简化的路由配置。

## 🚀 部署步骤

### 1. 上传文件

```bash
# 上传这些新文件到服务器
scp plugins/discourse-journals/app/controllers/discourse_journals/admin_controller.rb \
    user@server:/var/www/discourse/plugins/discourse-journals/app/controllers/discourse_journals/

# 创建 views 目录
ssh user@server "mkdir -p /var/www/discourse/plugins/discourse-journals/app/views/discourse_journals/admin"

scp plugins/discourse-journals/app/views/discourse_journals/admin/index.html.erb \
    user@server:/var/www/discourse/plugins/discourse-journals/app/views/discourse_journals/admin/

scp plugins/discourse-journals/config/routes.rb \
    user@server:/var/www/discourse/plugins/discourse-journals/config/

scp plugins/discourse-journals/plugin.rb \
    user@server:/var/www/discourse/plugins/discourse-journals/
```

### 2. 修复权限

```bash
ssh user@server
cd /var/www/discourse/plugins/discourse-journals
sudo chown -R discourse:discourse .
sudo chmod -R 755 .
```

### 3. 重启（重要！）

```bash
cd /var/www/discourse

# 方法1：快速重启
sv restart unicorn

# 方法2：如果方法1不行，用 launcher
cd /var/discourse
./launcher restart app
```

## ✅ 访问

重启后，直接访问：

```
http://你的域名/admin/plugins/journals
```

应该看到：

```
┌──────────────────────────────────────┐
│ 期刊库                                │
├──────────────────────────────────────┤
│                                      │
│ 导入期刊                              │
│                                      │
│ 上传包含期刊数据的 JSON 文件...       │
│                                      │
│ JSON 文件 (.json)                    │
│ [选择文件...]                         │
│                                      │
│ [开始导入]                            │
│                                      │
│ 📘 导入在后台运行，大文件可能需要     │
│    较长时间。                         │
│                                      │
└──────────────────────────────────────┘
```

## 🎨 特性

- ✅ **纯 Rails 视图**：不依赖 Ember 路由
- ✅ **AJAX 提交**：页面不刷新
- ✅ **实时反馈**：成功/失败消息
- ✅ **美观样式**：使用 Discourse CSS 变量
- ✅ **文件验证**：只接受 .json 文件

## 🔍 调试

### 检查路由

```bash
cd /var/www/discourse
sudo -u discourse RAILS_ENV=production bin/rails routes | grep journals
```

应该看到：
```
GET  /admin/plugins/journals     discourse_journals/admin#index
POST /admin/plugins/journals/imports discourse_journals/admin_imports#create
```

### 检查视图文件

```bash
ls -la /var/www/discourse/plugins/discourse-journals/app/views/discourse_journals/admin/
```

应该看到 `index.html.erb`。

### 查看日志

```bash
tail -f /var/www/discourse/log/production.log
```

然后访问页面，看是否有错误。

## 💡 为什么这个方案可靠

1. **不依赖 Ember**：避开复杂的前端路由系统
2. **传统 MVC**：Rails 最基础的模式
3. **自包含**：HTML + CSS + JS 都在一个文件中
4. **调试简单**：可以直接看到渲染结果

## 🎯 使用方法

1. 访问 `/admin/plugins/journals`
2. 点击"选择文件"，选择 `1.json`
3. 点击"开始导入"
4. 等待成功消息
5. 去期刊分类查看导入的话题

## 📞 如果还是不行

1. **检查 Rails 日志**：
   ```bash
   tail -50 /var/www/discourse/log/production.log
   ```

2. **检查权限**：
   ```bash
   ls -la /var/www/discourse/plugins/discourse-journals/app/views/
   ```

3. **尝试访问**：
   ```
   http://你的域名/admin/plugins/journals
   ```
   
   如果返回 404，说明路由没有正确加载。

4. **完全重启**：
   ```bash
   cd /var/discourse
   ./launcher rebuild app
   ```

---

**这个方案应该是最可靠的！** 🎉
