#!/bin/bash
# 部署带进度功能的版本

set -e

echo "🚀 部署 Discourse Journals 插件 - 进度和错误日志功能"
echo "========================================================="
echo ""

# 配置
SERVER="user@server"
REMOTE_PATH="/var/www/discourse"
LOCAL_PATH="/Users/youngp/discourse"

echo "📦 1. 打包插件..."
cd "$LOCAL_PATH"
tar czf journals-progress.tar.gz plugins/discourse-journals
echo "✅ 打包完成: journals-progress.tar.gz"
echo ""

echo "📤 2. 上传到服务器..."
scp journals-progress.tar.gz "$SERVER:/tmp/"
echo "✅ 上传完成"
echo ""

echo "🔧 3. 在服务器上部署..."
ssh "$SERVER" << 'ENDSSH'
set -e

echo "  → 解压文件..."
cd /tmp
tar xzf journals-progress.tar.gz

echo "  → 备份旧版本..."
if [ -d /var/www/discourse/plugins/discourse-journals ]; then
  sudo mv /var/www/discourse/plugins/discourse-journals \
         /var/www/discourse/plugins/discourse-journals.backup.$(date +%Y%m%d_%H%M%S)
fi

echo "  → 部署新版本..."
sudo mv plugins/discourse-journals /var/www/discourse/plugins/
sudo chown -R discourse:discourse /var/www/discourse/plugins/discourse-journals

echo "  → 运行数据库迁移..."
cd /var/www/discourse
sudo -u discourse bin/rails db:migrate

echo "  → 清除缓存..."
sudo -u discourse bin/rails runner "Rails.cache.clear"

echo "  → 重启服务..."
sv restart unicorn

echo ""
echo "✅ 部署完成！"
echo ""
echo "📊 验证部署..."
sudo -u discourse bin/rails runner "
  begin
    puts '  ✅ ImportLog 表已创建' if DiscourseJournals::ImportLog.table_exists?
    puts \"  ✅ 表字段: #{DiscourseJournals::ImportLog.column_names.join(', ')}\"
    puts \"  ✅ 路由已注册\" if Rails.application.routes.routes.any? { |r| r.path.spec.to_s.include?('journals/imports') }
  rescue => e
    puts \"  ❌ 错误: #{e.message}\"
  end
"
echo ""
ENDSSH

echo ""
echo "🎉 完成！"
echo ""
echo "🌐 访问地址："
echo "   http://你的域名/admin/plugins/discourse-journals"
echo ""
echo "📋 测试步骤："
echo "   1. 上传 JSON 文件"
echo "   2. 观察实时进度条"
echo "   3. 查看错误日志（如果有）"
echo ""
echo "🔍 查看日志："
echo "   ssh $SERVER"
echo "   tail -f $REMOTE_PATH/log/production.log | grep -i DiscourseJournals"
echo ""
