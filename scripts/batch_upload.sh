#!/bin/bash
# 自动批量上传拆分后的文件

set -e

# 配置
BASE_URL="http://your-domain.com"  # 修改为你的域名
ADMIN_USERNAME="admin"              # 修改为管理员用户名
API_KEY="your-api-key"              # 修改为 API Key
BATCH_DIR="split_output"
DELAY_SECONDS=30                    # 每次上传间隔（秒）

echo "🚀 批量导入期刊"
echo "===================="
echo ""

if [ ! -d "$BATCH_DIR" ]; then
  echo "❌ 错误：目录不存在: $BATCH_DIR"
  echo "请先运行 split_json.rb 拆分文件"
  exit 1
fi

# 获取所有文件
FILES=($(ls "$BATCH_DIR"/journals_batch_*.json | sort))
TOTAL=${#FILES[@]}

if [ $TOTAL -eq 0 ]; then
  echo "❌ 错误：没有找到批次文件"
  exit 1
fi

echo "📦 找到 $TOTAL 个批次文件"
echo ""

for i in "${!FILES[@]}"; do
  FILE="${FILES[$i]}"
  BATCH=$((i + 1))
  
  echo "[$BATCH/$TOTAL] 上传: $(basename "$FILE")"
  
  # 使用 curl 上传
  RESPONSE=$(curl -s -X POST \
    -H "Api-Key: $API_KEY" \
    -H "Api-Username: $ADMIN_USERNAME" \
    -F "file=@$FILE" \
    "$BASE_URL/admin/journals/imports.json")
  
  # 检查响应
  if echo "$RESPONSE" | grep -q "upload_id"; then
    IMPORT_LOG_ID=$(echo "$RESPONSE" | grep -o '"import_log_id":[0-9]*' | cut -d: -f2)
    echo "  ✅ 成功！Import Log ID: $IMPORT_LOG_ID"
  else
    echo "  ❌ 失败！响应: $RESPONSE"
    echo ""
    echo "是否继续？(y/n)"
    read -r CONTINUE
    if [ "$CONTINUE" != "y" ]; then
      exit 1
    fi
  fi
  
  # 等待处理
  if [ $BATCH -lt $TOTAL ]; then
    echo "  ⏳ 等待 $DELAY_SECONDS 秒..."
    sleep $DELAY_SECONDS
    echo ""
  fi
done

echo ""
echo "🎉 所有批次上传完成！"
echo "请查看管理后台检查导入状态"
