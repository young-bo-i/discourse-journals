#!/bin/bash
# Rails 8 enum 语法修复 - 快速部署

set -e

echo "🔧 Rails 8 兼容性修复 - 快速部署"
echo "===================================="
echo ""

# 配置
PLUGIN_DIR="/Users/youngp/discourse/plugins/discourse-journals"
SERVER="user@server"  # 替换为实际服务器地址

echo "📝 提交修复..."
cd "$PLUGIN_DIR"
git add app/models/discourse_journals/import_log.rb
git commit -m "Fix Rails 8 enum syntax compatibility" || echo "Already committed"
git push

echo "✅ 修复已推送到仓库"
echo ""

echo "🚀 在服务器上拉取修复..."
ssh "$SERVER" << 'ENDSSH'
set -e

echo "  → 拉取最新代码..."
cd /var/www/discourse/plugins/discourse-journals
git pull

echo "  → 重启 Unicorn..."
cd /var/www/discourse
sv restart unicorn

echo ""
echo "✅ 修复完成！"
echo ""
echo "📊 等待10秒后检查状态..."
sleep 10

echo "🔍 检查 Unicorn 状态..."
sv status unicorn

echo ""
echo "🎉 完成！如果 Unicorn 正常运行，插件应该已成功加载。"
echo ""
ENDSSH

echo ""
echo "✅ 部署完成！"
echo ""
echo "🌐 访问地址："
echo "   http://你的域名/admin/plugins/discourse-journals"
echo ""
