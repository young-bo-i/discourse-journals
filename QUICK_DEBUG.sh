#!/bin/bash
# 快速诊断脚本 - 在服务器上运行

echo "🔍 Discourse Journals 导入诊断"
echo "================================"
echo ""

cd /var/www/discourse

echo "📋 1. 检查最近上传的 JSON 文件"
echo "----------------------------"
sudo -u discourse bin/rails runner "
  upload = Upload.where('original_filename LIKE ?', '%.json')
    .order(created_at: :desc)
    .limit(3)
  
  if upload.empty?
    puts '❌ 没有找到 JSON 上传文件'
  else
    upload.each do |u|
      puts \"✅ ID: #{u.id}, 文件名: #{u.original_filename}\"
      puts \"   路径: #{u.url}\"
      puts \"   大小: #{(u.filesize / 1024.0 / 1024.0).round(2)} MB\"
      puts \"   创建时间: #{u.created_at}\"
      puts \"   完整路径: #{Discourse.store.path_for(u)}\"
      puts ''
    end
  end
"

echo ""
echo "📊 2. 检查 Sidekiq 队列"
echo "----------------------------"
sudo -u discourse bin/rails runner "
  require 'sidekiq/api'
  
  queue = Sidekiq::Queue.new
  journal_jobs = queue.select { |j| j.klass.to_s.include?('Journal') }
  
  if journal_jobs.empty?
    puts '⚠️  队列中没有 Journal 任务（可能已完成或失败）'
  else
    puts \"✅ 队列中有 #{journal_jobs.count} 个任务\"
    journal_jobs.first(3).each do |job|
      puts \"   类: #{job.klass}\"
      puts \"   参数: #{job.args}\"
      puts \"   创建: #{job.created_at}\"
      puts ''
    end
  end
"

echo ""
echo "❌ 3. 检查失败任务"
echo "----------------------------"
sudo -u discourse bin/rails runner "
  require 'sidekiq/api'
  
  dead = Sidekiq::DeadSet.new
  journal_failed = dead.select { |j| j.klass.to_s.include?('Journal') }
  
  if journal_failed.empty?
    puts '✅ 没有失败的 Journal 任务'
  else
    puts \"❌ 有 #{journal_failed.count} 个失败任务\"
    journal_failed.first(3).each do |job|
      puts \"   类: #{job.klass}\"
      puts \"   错误: #{job.item['error_message']}\"
      puts \"   时间: #{job.item['failed_at']}\"
      puts \"   堆栈:\"
      (job.item['error_backtrace'] || []).first(5).each do |line|
        puts \"      #{line}\"
      end
      puts ''
    end
  end
"

echo ""
echo "📜 4. 最近日志（包含 journal 或 import）"
echo "----------------------------"
tail -100 log/production.log | grep -i "journal\|import" | tail -20

echo ""
echo "✅ 诊断完成！"
echo ""
echo "💡 如果看到失败任务，请复制错误信息"
echo "💡 如果队列为空且没有失败，任务可能已完成"
echo "💡 检查期刊分类是否有新话题创建"
