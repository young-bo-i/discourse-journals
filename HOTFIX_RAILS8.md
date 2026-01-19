# 🔧 Rails 8 兼容性修复

## 问题

部署时报错：
```
ArgumentError: wrong number of arguments (given 0, expected 1..2)
/vendor/bundle/ruby/3.3.0/gems/activerecord-8.0.4/lib/active_record/enum.rb:217:in `enum'
/plugins/discourse-journals/app/models/discourse_journals/import_log.rb:10
```

## 原因

Rails 8 改变了 `enum` 的语法。

### Rails 7 语法（旧）
```ruby
enum status: { pending: 0, processing: 1 }
```

### Rails 8 语法（新）
```ruby
enum :status, { pending: 0, processing: 1 }
```

## 修复

在 `app/models/discourse_journals/import_log.rb` 第10行：

```ruby
# 修改前
enum status: { pending: 0, processing: 1, completed: 2, failed: 3 }

# 修改后
enum :status, { pending: 0, processing: 1, completed: 2, failed: 3 }
```

## 部署修复

```bash
# 本地
cd /Users/youngp/discourse/plugins/discourse-journals
git add app/models/discourse_journals/import_log.rb
git commit -m "Fix Rails 8 enum syntax"
git push

# 服务器
ssh user@server
cd /var/www/discourse/plugins/discourse-journals
git pull
cd /var/www/discourse
sv restart unicorn
```

或使用 Admin 界面的 "Update" 按钮重新升级。

---

✅ 修复完成后，升级应该能成功！
