# ✅ 正确的插件设置 - 按照官方标准

## 🎯 关键发现

根据 Discourse 官方文档和最新实践（2025-2026），插件管理界面需要：

1. ✅ `add_admin_route` - 在插件菜单中注册链接
2. ✅ **Ember route-map.js** - 前端路由映射（这是之前缺少的！）
3. ✅ Handlebars 模板 - UI 界面
4. ✅ Ember Controller - 交互逻辑
5. ✅ API 路由 - 后端处理

## 📦 现在的文件结构

```
plugins/discourse-journals/
├── plugin.rb                                              ← 使用 add_admin_route
├── assets/javascripts/discourse/
│   ├── discourse-journals-route-map.js                    ← 关键！前端路由
│   ├── controllers/
│   │   └── admin-plugins-discourse-journals.js            ← Ember 控制器
│   └── templates/admin/
│       └── plugins-discourse-journals.hbs                 ← Handlebars 模板
├── app/
│   ├── controllers/discourse_journals/
│   │   └── admin_imports_controller.rb                    ← API 控制器
│   ├── services/...                                       ← 业务逻辑
│   └── jobs/...                                          ← 后台任务
└── config/locales/
    ├── client.en.yml                                      ← 前端翻译
    ├── client.zh_CN.yml
    └── server.en.yml                                      ← 后端翻译
```

## 🚀 部署步骤

### 1. 打包上传

```bash
cd /Users/youngp/discourse
tar czf journals.tar.gz plugins/discourse-journals
scp journals.tar.gz user@server:/tmp/
```

### 2. 服务器部署

```bash
ssh user@server

# 备份旧版本（如果需要）
cd /var/www/discourse/plugins
sudo mv discourse-journals discourse-journals.backup

# 部署新版本
cd /tmp
tar xzf journals.tar.gz
sudo mv plugins/discourse-journals /var/www/discourse/plugins/
sudo chown -R discourse:discourse /var/www/discourse/plugins/discourse-journals

# 重启
cd /var/www/discourse
sv restart unicorn
```

### 3. 清除浏览器缓存

- 按 Ctrl+Shift+Del 清除缓存
- 硬刷新：Ctrl+Shift+R

## ✅ 访问路径

重启后，有**两种方式**访问：

### 方式1：通过插件菜单（推荐）

```
Admin → Plugins → 找到 "Journals" 或 "discourse-journals"
→ 点击插件名称
→ 应该显示导入界面（不是设置页面）
```

### 方式2：直接访问 URL

```
http://你的域名/admin/plugins/discourse-journals
```

## 🎨 正确的界面

应该看到：

```
┌────────────────────────────────────────┐
│ 期刊库                                  │
├────────────────────────────────────────┤
│                                        │
│ 导入期刊                                │
│                                        │
│ 上传包含期刊数据的 JSON 文件，数据来自  │
│ OpenAlex、Crossref、DOAJ、NLM 和       │
│ Wikidata...                            │
│                                        │
│ JSON 文件 (.json)                      │
│ [选择文件...]                           │
│                                        │
│ [开始导入] ← 蓝色按钮                   │
│                                        │
│ ℹ️ 导入在后台运行，大文件可能需要       │
│    较长时间。                           │
│                                        │
└────────────────────────────────────────┘
```

## 🔍 验证

### 检查文件

```bash
cd /var/www/discourse/plugins/discourse-journals

# 关键文件
ls -la assets/javascripts/discourse/discourse-journals-route-map.js
ls -la assets/javascripts/discourse/controllers/admin-plugins-discourse-journals.js
ls -la assets/javascripts/discourse/templates/admin/plugins-discourse-journals.hbs
```

### 检查路由

```bash
cd /var/www/discourse
sudo -u discourse bin/rails routes | grep journals
```

### 查看日志

```bash
tail -50 /var/www/discourse/log/production.log | grep -i journal
```

## 📋 关键文件内容

### route-map.js
```js
export default {
  resource: "admin.adminPlugins",
  path: "/plugins",
  map() {
    this.route("discourse-journals");
  },
};
```

这个文件告诉 Ember：当访问 `/admin/plugins/discourse-journals` 时，使用 `adminPlugins.discourse-journals` 路由。

## 💡 为什么之前不行

之前缺少了 `discourse-journals-route-map.js` 文件，导致：
- ❌ Ember 不知道如何处理这个路由
- ❌ 访问时被重定向到设置页面（Discourse 的默认行为）
- ❌ 自定义模板和控制器没有被使用

现在添加了 route-map.js：
- ✅ Ember 正确处理路由
- ✅ 加载自定义模板
- ✅ 使用自定义控制器
- ✅ 显示导入界面

---

**这次应该可以了！** 部署后访问 `/admin/plugins/discourse-journals`！🎉
