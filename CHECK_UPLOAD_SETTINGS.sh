#!/bin/bash
# 检查上传设置和配置

echo "🔍 检查文件上传配置"
echo "===================="
echo ""

SERVER="user@server"  # 替换为你的服务器地址

echo "📊 本地文件信息："
FILE="/Users/youngp/discourse/1.json"
if [ -f "$FILE" ]; then
    SIZE=$(ls -lh "$FILE" | awk '{print $5}')
    LINES=$(wc -l < "$FILE")
    echo "  文件: $FILE"
    echo "  大小: $SIZE"
    echo "  行数: $LINES"
else
    echo "  ⚠️  文件不存在: $FILE"
fi
echo ""

echo "🌐 检查服务器设置..."
ssh "$SERVER" << 'ENDSSH'
cd /var/www/discourse

echo "1️⃣ Discourse 文件大小设置："
sudo -u discourse bin/rails runner "
  max_kb = SiteSetting.max_attachment_size_kb
  max_mb = (max_kb / 1024.0).round(2)
  puts \"  max_attachment_size_kb: #{max_kb} KB (#{max_mb} MB)\"
  
  exts = SiteSetting.authorized_extensions
  puts \"  authorized_extensions: #{exts}\"
  puts \"  JSON 允许: #{exts.split('|').include?('json') ? '✅' : '❌'}\"
"

echo ""
echo "2️⃣ Nginx 上传限制："
if grep -q "client_max_body_size" /etc/nginx/nginx.conf 2>/dev/null; then
    grep "client_max_body_size" /etc/nginx/nginx.conf | head -1
else
    echo "  ⚠️  未找到 client_max_body_size 配置（默认 1MB）"
fi

echo ""
echo "3️⃣ 临时目录："
sudo -u discourse bin/rails runner "
  tmpdir = Dir.tmpdir
  puts \"  路径: #{tmpdir}\"
  puts \"  可写: #{File.writable?(tmpdir) ? '✅' : '❌'}\"
  puts \"  可用空间: #{('%.2f' % (`df -h #{tmpdir}`.lines.last.split[3].to_f))} GB\"
"

echo ""
echo "4️⃣ ImportLog 模型状态："
sudo -u discourse bin/rails runner "
  begin
    puts \"  表名: #{DiscourseJournals::ImportLog.table_name}\"
    puts \"  表存在: ✅\"
    puts \"  记录数: #{DiscourseJournals::ImportLog.count}\"
    puts \"  状态: #{DiscourseJournals::ImportLog.statuses.keys.join(', ')}\"
  rescue => e
    puts \"  ❌ 错误: #{e.message}\"
  end
"

ENDSSH

echo ""
echo "✅ 检查完成！"
echo ""
echo "📋 建议："
echo "  1. 如果文件 > max_attachment_size_kb，增加到 102400 (100MB)"
echo "  2. 如果 JSON 未允许，添加 'json' 到 authorized_extensions"
echo "  3. 如果 Nginx < 文件大小，设置 client_max_body_size 100M"
echo ""
