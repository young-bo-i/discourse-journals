# 🔧 筛选功能错误修复

## 问题

```
no implicit conversion of Symbol into Integer
```

## 原因

`filters` 参数从 JavaScript 传到 Rails 后，可能被解析为数组而不是哈希，导致访问键值时出错。

## 修复

### 1. 更新 `client.rb`

```ruby
def build_params(page, page_size, filters)
  # 确保 filters 是一个哈希
  filters = filters.to_h if filters.respond_to?(:to_h)
  filters ||= {}

  # 支持字符串键和符号键
  params[:q] = filters["q"] || filters[:q] if (filters["q"] || filters[:q]).present?
  # ...
end
```

### 2. 更新 `admin_sync_controller.rb`

```ruby
def create
  filters = (params[:filters] || {}).to_h.with_indifferent_access
  # ...
end
```

## 快速部署

```bash
cd /Users/youngp/discourse/plugins/discourse-journals
git add .
git commit -m "Fix filters parameter type conversion"
git push

# 服务器
ssh user@server
cd /var/www/discourse/plugins/discourse-journals
git pull
cd /var/www/discourse
sv restart unicorn
```

## 测试

1. 访问 `/admin/plugins/discourse-journals`
2. 点击"显示筛选"
3. 选择任意筛选条件
4. 点击"导入第一页（测试）"
5. 应该成功开始导入

---

✅ 修复完成！
