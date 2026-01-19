# Zeitwerk 命名冲突修复

## 问题

Zeitwerk 自动加载器报错：

```
expected file /var/www/discourse/plugins/discourse-journals/app/services/discourse_journals/json/importer.rb 
to define constant DiscourseJournals::JSON::Importer, but didn't
```

## 原因

在 Rails/Zeitwerk 中，`JSON` 是一个预定义的缩写词（inflection），会被自动转换为全大写。

- 文件路径：`json/importer.rb` 
- Zeitwerk 期望：`JSON::Importer`（全大写）
- 实际定义：`Json::Importer`（首字母大写）

这导致命名不匹配，Zeitwerk 无法加载类。

## 解决方案

将文件夹从 `json/` 重命名为 `json_import/`，避免与 JSON 缩写词冲突：

### 1. 重命名文件夹

```bash
mv app/services/discourse_journals/json \
   app/services/discourse_journals/json_import
```

### 2. 更新类定义

**文件**: `app/services/discourse_journals/json_import/importer.rb`

```ruby
module DiscourseJournals
  module JsonImport  # 从 Json 改为 JsonImport
    class Importer
      # ...
    end
  end
end
```

### 3. 更新引用

**文件**: `plugin.rb`

```ruby
require_relative "app/services/discourse_journals/json_import/importer"
# 从 json/importer 改为 json_import/importer
```

**文件**: `app/jobs/regular/discourse_journals/import_json.rb`

```ruby
importer = ::DiscourseJournals::JsonImport::Importer.new(file_path: file_path)
# 从 Json::Importer 改为 JsonImport::Importer
```

## Zeitwerk 命名规则

Zeitwerk 遵循严格的文件路径 → 类名映射：

| 文件路径 | 期望的类名 |
|---------|-----------|
| `app/services/user_manager.rb` | `UserManager` |
| `app/services/user_manager/creator.rb` | `UserManager::Creator` |
| `app/services/api/client.rb` | `Api::Client` |
| `app/services/json/parser.rb` | `JSON::Parser` ⚠️ (inflection) |

### 常见缩写词

这些词会被自动转换为全大写：

- `json` → `JSON`
- `html` → `HTML`
- `xml` → `XML`
- `api` → `API`
- `url` → `URL`
- `http` → `HTTP`
- `ssl` → `SSL`

**最佳实践**：避免使用这些缩写词作为文件夹名，或使用下划线连接（如 `json_import`）。

## 验证

所有语法检查通过：

```bash
✓ plugin.rb - Syntax OK
✓ app/services/discourse_journals/json_import/importer.rb - Syntax OK  
✓ app/jobs/regular/discourse_journals/import_json.rb - Syntax OK
```

## 相关链接

- [Zeitwerk README](https://github.com/fxn/zeitwerk)
- [Rails Autoloading Guide](https://guides.rubyonrails.org/autoloading_and_reloading_constants.html)
- [ActiveSupport Inflections](https://api.rubyonrails.org/classes/ActiveSupport/Inflector.html)

## 修复时间

2026-01-19 16:15
