#!/usr/bin/env ruby
# 将大 JSON 文件拆分成多个小文件

require 'json'

def split_json_file(input_file, batch_size: 1000, output_dir: 'split_output')
  puts "📖 读取文件: #{input_file}"
  
  content = File.read(input_file)
  data = JSON.parse(content)
  
  unless data.is_a?(Array)
    puts "❌ 错误：JSON 必须是数组格式"
    exit 1
  end
  
  total = data.size
  puts "📊 总期刊数: #{total}"
  puts "📦 每批数量: #{batch_size}"
  
  Dir.mkdir(output_dir) unless Dir.exist?(output_dir)
  
  batches = (total.to_f / batch_size).ceil
  puts "🔢 将拆分为 #{batches} 个文件\n\n"
  
  data.each_slice(batch_size).with_index do |batch, index|
    batch_num = index + 1
    output_file = File.join(output_dir, "journals_batch_#{batch_num.to_s.rjust(4, '0')}.json")
    
    File.write(output_file, JSON.pretty_generate(batch))
    
    size_mb = (File.size(output_file) / 1024.0 / 1024.0).round(2)
    puts "✅ 文件 #{batch_num}/#{batches}: #{output_file} (#{batch.size} 个期刊, #{size_mb} MB)"
  end
  
  puts "\n🎉 拆分完成！"
  puts "📁 输出目录: #{output_dir}"
  puts "\n📋 下一步："
  puts "  1. 逐个上传这些文件到 /admin/plugins/discourse-journals"
  puts "  2. 或使用 batch_upload.sh 脚本自动上传"
end

# 使用示例
if ARGV.empty?
  puts "用法: ruby split_json.rb <input.json> [batch_size] [output_dir]"
  puts "示例: ruby split_json.rb journals.json 1000 batches"
  exit 1
end

input_file = ARGV[0]
batch_size = (ARGV[1] || 1000).to_i
output_dir = ARGV[2] || 'split_output'

split_json_file(input_file, batch_size: batch_size, output_dir: output_dir)
