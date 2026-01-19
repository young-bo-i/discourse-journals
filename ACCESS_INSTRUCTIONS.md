# 访问导入页面 - 正确的 URL

## ⚠️ 重要

**不要访问**：`/admin/plugins/journals` ❌
这个 URL 会被重定向到设置页面！

## ✅ 正确的访问地址

```
http://你的域名/admin/journals
```

或者在开发环境：
```
http://localhost:4200/admin/journals
```

## 🚀 部署后访问

### 1. 上传修改的文件

```bash
# 上传这3个修改过的文件
scp plugins/discourse-journals/config/routes.rb \
    user@server:/var/www/discourse/plugins/discourse-journals/config/

scp plugins/discourse-journals/plugin.rb \
    user@server:/var/www/discourse/plugins/discourse-journals/

scp plugins/discourse-journals/app/views/discourse_journals/admin/index.html.erb \
    user@server:/var/www/discourse/plugins/discourse-journals/app/views/discourse_journals/admin/
```

### 2. 修复权限

```bash
ssh user@server
cd /var/www/discourse/plugins/discourse-journals
sudo chown -R discourse:discourse .
```

### 3. 重启

```bash
cd /var/www/discourse
sv restart unicorn
```

### 4. 访问

```
http://你的域名/admin/journals
```

**注意**：是 `/admin/journals`，不是 `/admin/plugins/journals`！

## 📋 路由说明

现在的路由是：

```
GET  /admin/journals          → 显示导入页面
POST /admin/journals/imports  → 处理文件上传
```

完全独立于插件设置页面。

## 🔍 验证路由

SSH 登录服务器后，检查路由是否注册：

```bash
cd /var/www/discourse
sudo -u discourse RAILS_ENV=production bin/rails routes | grep journals
```

应该看到：
```
GET  /admin/journals          discourse_journals/admin#index
POST /admin/journals/imports  discourse_journals/admin_imports#create
```

## 📝 添加书签

建议将以下 URL 加入书签：

```
http://你的域名/admin/journals
```

这样就能直接访问导入页面了！

## 🎯 完整流程

1. 访问 `http://你的域名/admin/journals`
2. 点击"选择文件"
3. 选择 `1.json` 文件
4. 点击"开始导入"
5. 等待成功消息
6. 去期刊分类查看导入的话题

---

**记住**：永远使用 `/admin/journals`，不是 `/admin/plugins/journals`！
