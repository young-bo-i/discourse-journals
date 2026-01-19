# 最终部署指南 - 简化版

## 📋 文件清单

需要上传到服务器的文件：

```
plugins/discourse-journals/
├── plugin.rb                                                              ← 更新
├── config/locales/
│   ├── client.en.yml                                                     ← 更新
│   └── client.zh_CN.yml                                                  ← 更新
├── admin/assets/javascripts/discourse/
│   ├── components/
│   │   └── journals-admin-import.gjs                                     ← 新建
│   ├── routes/
│   │   └── admin-plugins-journals.js                                     ← 新建
│   └── templates/
│       └── admin-plugins-journals.hbs                                    ← 新建
└── assets/stylesheets/common/
    └── journals-import.scss                                              ← 已存在
```

删除的文件：
```
admin/assets/javascripts/discourse/
├── components/journals-admin.gjs                                         ← 删除
├── routes/admin-plugins/show/journals.js                                 ← 删除
├── routes/admin-plugins/show/journals/index.js                           ← 删除
├── templates/admin-plugins/show/journals/index.gjs                       ← 删除
└── templates/connectors/admin-plugin-config-page/journals-import.gjs    ← 删除
```

## 🚀 快速部署（3步）

### 步骤1：上传文件

```bash
# 从本地上传整个插件目录
cd /Users/youngp/discourse
scp -r plugins/discourse-journals user@your-server:/var/www/discourse/plugins/
```

### 步骤2：修复权限

```bash
# SSH 登录服务器
ssh user@your-server

# 修复权限
cd /var/www/discourse/plugins/discourse-journals
sudo chown -R discourse:discourse .
sudo chmod -R 755 .
```

### 步骤3：重新编译和重启

```bash
cd /var/www/discourse

# 重新编译
sudo -u discourse RAILS_ENV=production bin/rake assets:precompile

# 重启
sv restart unicorn
```

## ✅ 验证

重启后访问：
```
http://你的域名/admin/plugins/journals
```

应该看到：
```
┌────────────────────────────────────────┐
│ 期刊库 (Journals)                       │
├────────────────────────────────────────┤
│                                        │
│ 上传包含期刊数据的 JSON 文件...         │
│                                        │
│ JSON 文件 (.json)                      │
│ [选择文件...]                           │
│                                        │
│ [开始导入] 按钮                         │
│                                        │
└────────────────────────────────────────┘
```

## 🐛 如果还是看不到

### 检查路由注册

```bash
cd /var/www/discourse
sudo -u discourse RAILS_ENV=production bin/rails c

# 在 Rails 控制台中执行
Discourse.plugins.map(&:name)
# 应该包含 "discourse-journals"

AdminDashboardData.fetch_stats['discourse_journals']
```

### 清除浏览器缓存

- Chrome/Edge: Ctrl+Shift+Del
- 清除所有数据
- 硬刷新: Ctrl+Shift+R

### 检查浏览器控制台

按 F12，看 Console 标签是否有JavaScript 错误。

## 📞 最后的方案

如果以上都不行，可以尝试完全重建：

```bash
cd /var/discourse
./launcher rebuild app
```

**注意**：rebuild 会重启整个容器，需要10-15分钟。

## 🎯 成功的标志

- ✅ URL `/admin/plugins/journals` 可以访问
- ✅ 显示文件上传界面
- ✅ 可以选择 JSON 文件
- ✅ 有"开始导入"按钮
- ✅ 点击后显示成功消息

完成后就可以上传 `1.json` 测试导入了！
