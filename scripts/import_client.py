#!/usr/bin/env python3
"""
Discourse Journals API 客户端
无需上传文件，直接通过 API 批量导入期刊
"""

import json
import requests
import time
import sys
from typing import List, Dict, Any

class JournalsApiClient:
    def __init__(self, base_url: str, api_key: str, username: str):
        """
        初始化客户端
        
        Args:
            base_url: Discourse 站点 URL (如 https://forum.example.com)
            api_key: API Key (在 Admin -> API -> New API Key 生成)
            username: 管理员用户名
        """
        self.base_url = base_url.rstrip('/')
        self.api_key = api_key
        self.username = username
        self.session = requests.Session()
        self.session.headers.update({
            'Api-Key': api_key,
            'Api-Username': username,
            'Content-Type': 'application/json'
        })
    
    def batch_import(self, journals: List[Dict[str, Any]], batch_size: int = 100, delay: float = 2.0):
        """
        批量导入期刊
        
        Args:
            journals: 期刊数据列表
            batch_size: 每批数量（默认100，最大500）
            delay: 批次间延迟（秒）
        
        Returns:
            Dict: 汇总结果
        """
        total = len(journals)
        print(f"📊 总期刊数: {total:,}")
        print(f"📦 每批数量: {batch_size}")
        print(f"⏱  批次延迟: {delay}s")
        print()
        
        summary = {
            'total': total,
            'created': 0,
            'updated': 0,
            'skipped': 0,
            'failed': 0,
            'errors': []
        }
        
        # 分批处理
        batches = [journals[i:i + batch_size] for i in range(0, total, batch_size)]
        total_batches = len(batches)
        
        for batch_num, batch in enumerate(batches, 1):
            print(f"[{batch_num}/{total_batches}] 导入 {len(batch)} 个期刊...")
            
            try:
                result = self._import_batch(batch)
                
                summary['created'] += result['created']
                summary['updated'] += result['updated']
                summary['skipped'] += result['skipped']
                
                if result.get('errors'):
                    summary['errors'].extend(result['errors'])
                
                print(f"  ✅ 成功: {result['created']} 新建, {result['updated']} 更新, {result['skipped']} 跳过")
                
                if result.get('errors'):
                    print(f"  ⚠️  错误: {len(result['errors'])} 个")
                
            except Exception as e:
                print(f"  ❌ 批次失败: {e}")
                summary['failed'] += len(batch)
                summary['errors'].append(f"批次 {batch_num} 失败: {str(e)}")
            
            # 等待（除了最后一批）
            if batch_num < total_batches:
                print(f"  ⏳ 等待 {delay}s...\n")
                time.sleep(delay)
        
        print("\n" + "="*50)
        print("🎉 导入完成！")
        print(f"✅ 新建: {summary['created']:,}")
        print(f"🔄 更新: {summary['updated']:,}")
        print(f"⏭  跳过: {summary['skipped']:,}")
        print(f"❌ 失败: {summary['failed']:,}")
        if summary['errors']:
            print(f"⚠️  错误数: {len(summary['errors'])}")
        
        return summary
    
    def _import_batch(self, batch: List[Dict[str, Any]]) -> Dict[str, Any]:
        """导入单个批次"""
        url = f"{self.base_url}/discourse-journals/api/journals/batch"
        payload = {'journals': batch}
        
        response = self.session.post(url, json=payload, timeout=300)
        response.raise_for_status()
        
        data = response.json()
        if not data.get('success'):
            raise Exception(data.get('message', 'Unknown error'))
        
        return data['results']
    
    def get_journal(self, issn: str) -> Dict[str, Any]:
        """查询期刊"""
        url = f"{self.base_url}/discourse-journals/api/journals/{issn}"
        response = self.session.get(url, timeout=30)
        response.raise_for_status()
        return response.json()


def main():
    """示例用法"""
    if len(sys.argv) < 5:
        print("用法: python import_client.py <json_file> <base_url> <api_key> <username> [batch_size] [delay]")
        print()
        print("示例:")
        print("  python import_client.py journals.json https://forum.example.com your_api_key admin 100 2")
        print()
        print("参数:")
        print("  json_file   - 期刊数据 JSON 文件")
        print("  base_url    - Discourse 站点 URL")
        print("  api_key     - API Key (在 Admin -> API 生成)")
        print("  username    - 管理员用户名")
        print("  batch_size  - 每批数量 (可选, 默认100, 最大500)")
        print("  delay       - 批次间延迟秒数 (可选, 默认2)")
        sys.exit(1)
    
    json_file = sys.argv[1]
    base_url = sys.argv[2]
    api_key = sys.argv[3]
    username = sys.argv[4]
    batch_size = int(sys.argv[5]) if len(sys.argv) > 5 else 100
    delay = float(sys.argv[6]) if len(sys.argv) > 6 else 2.0
    
    # 读取 JSON 文件
    print(f"📖 读取文件: {json_file}")
    with open(json_file, 'r', encoding='utf-8') as f:
        journals = json.load(f)
    
    if not isinstance(journals, list):
        print("❌ 错误: JSON 文件必须包含一个期刊数组")
        sys.exit(1)
    
    print(f"✅ 加载了 {len(journals):,} 个期刊\n")
    
    # 创建客户端并导入
    client = JournalsApiClient(base_url, api_key, username)
    
    try:
        summary = client.batch_import(journals, batch_size=batch_size, delay=delay)
        
        # 保存错误日志
        if summary['errors']:
            error_file = f"{json_file}.errors.txt"
            with open(error_file, 'w', encoding='utf-8') as f:
                for error in summary['errors']:
                    f.write(error + '\n')
            print(f"\n📝 错误日志已保存到: {error_file}")
        
    except KeyboardInterrupt:
        print("\n\n⚠️  用户中断")
        sys.exit(1)
    except Exception as e:
        print(f"\n\n❌ 导入失败: {e}")
        sys.exit(1)


if __name__ == '__main__':
    main()
