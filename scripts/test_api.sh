#!/bin/bash
# 测试 API 端点是否正常工作

set -e

# 配置（修改这些值）
BASE_URL="http://localhost:3000"  # 或 https://your-domain.com
API_KEY="your_api_key_here"
USERNAME="admin"

echo "🧪 测试 Discourse Journals API"
echo "=============================="
echo ""
echo "服务器: $BASE_URL"
echo "用户: $USERNAME"
echo ""

# 测试1: 批量导入（1个期刊）
echo "1️⃣ 测试批量导入..."
RESPONSE=$(curl -s -X POST \
  -H "Api-Key: $API_KEY" \
  -H "Api-Username: $USERNAME" \
  -H "Content-Type: application/json" \
  -d '{
    "journals": [
      {
        "primary_issn": "2073-4395",
        "unified_index": {
          "title": "Test Journal"
        },
        "aliases": [],
        "sources_by_provider": {
          "openalex": {
            "data": {"test": true}
          }
        }
      }
    ]
  }' \
  "$BASE_URL/discourse-journals/api/journals/batch")

if echo "$RESPONSE" | grep -q "success.*true"; then
  echo "  ✅ 批量导入端点正常"
  echo "  响应: $RESPONSE" | head -c 200
  echo ""
else
  echo "  ❌ 批量导入端点失败"
  echo "  响应: $RESPONSE"
  exit 1
fi

echo ""

# 测试2: 查询期刊
echo "2️⃣ 测试查询期刊..."
RESPONSE=$(curl -s -X GET \
  -H "Api-Key: $API_KEY" \
  -H "Api-Username: $USERNAME" \
  "$BASE_URL/discourse-journals/api/journals/2073-4395")

if echo "$RESPONSE" | grep -q "success.*true"; then
  echo "  ✅ 查询端点正常"
  echo "  响应: $RESPONSE" | head -c 200
  echo ""
elif echo "$RESPONSE" | grep -q "期刊不存在"; then
  echo "  ✅ 查询端点正常（期刊未创建）"
else
  echo "  ❌ 查询端点失败"
  echo "  响应: $RESPONSE"
  exit 1
fi

echo ""
echo "✅ 所有测试通过！"
echo ""
echo "📋 下一步："
echo "  使用 Python 客户端导入完整数据："
echo "  python import_client.py your_journals.json $BASE_URL $API_KEY $USERNAME"
echo ""
