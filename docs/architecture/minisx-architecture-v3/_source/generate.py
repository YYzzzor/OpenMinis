#!/usr/bin/env python3
"""Build offline, self-contained HTML entry points from one source of content."""
from __future__ import annotations
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / '_source'
ENTRIES = {
    'index.html': ('整体架构 · MinisX 架构导览 v3', '/architecture'),
    'message-lifecycle.html': ('发送消息 · MinisX 架构导览 v3', '/flow/01'),
    'native-capabilities.html': ('原生能力清单 · MinisX 架构导览 v3', '/capabilities'),
    'ish.html': ('iSH 命令执行 · MinisX 架构导览 v3', '/module/ish'),
    'native.html': ('原生能力桥接 · MinisX 架构导览 v3', '/module/native'),
    'ios-frameworks.html': ('iOS 系统框架 · MinisX 架构导览 v3', '/module/os'),
    'mcp.html': ('MCP 配置中心 · MinisX 架构导览 v3', '/module/mcp'),
}

def build() -> None:
    data = json.loads((ROOT / 'architecture-data.json').read_text(encoding='utf-8'))
    ids = {node['id'] for node in data['nodes']}
    if len(ids) != len(data['nodes']):
        raise ValueError('Duplicate node ids')
    for scope in data['scopes'].values():
        scoped = {item[0] for item in scope['nodes']}
        if not scoped <= ids:
            raise ValueError('Unknown node in scope')
        for edge in scope['edges']:
            if edge['a'] not in scoped or edge['b'] not in scoped:
                raise ValueError('Unknown edge endpoint')
    caps = data.get('capabilities', {})
    cap_ids = {item['id'] for item in caps.get('items', [])}
    if len(cap_ids) != len(caps.get('items', [])):
        raise ValueError('Duplicate capability ids')
    groups = {group['id'] for group in caps.get('groups', [])}
    for item in caps.get('items', []):
        if item['group'] not in groups:
            raise ValueError('Unknown capability category')
        for ref in item.get('refs', []):
            if not ref.get('path') or not ref.get('symbol'):
                raise ValueError('Incomplete capability source reference')
    for framework in data.get('frameworks', []):
        if not set(framework['capabilities']) <= cap_ids:
            raise ValueError('Unknown capability in framework table')
    for gap in caps.get('gaps', []):
        if not set(gap.get('related', [])) <= cap_ids:
            raise ValueError('Unknown capability in limitations')
    if not set(data.get('moduleGuides', {})) <= ids:
        raise ValueError('Unknown deep-dive module')
    content = json.dumps(data, ensure_ascii=False, separators=(',', ':')).replace('<', '\\u003c')
    template = (SOURCE / 'template.html').read_text(encoding='utf-8')
    style = (SOURCE / 'style.css').read_text(encoding='utf-8')
    app = (SOURCE / 'app.js').read_text(encoding='utf-8')
    if '</script' in app.lower():
        raise ValueError('Unsafe inline script closing tag')
    for filename, (title, entry) in ENTRIES.items():
        html = template.replace('__TITLE__', title).replace('__STYLE__', style)
        html = html.replace('__DATA__', content).replace('__ENTRY__', json.dumps(entry)).replace('__APP__', app)
        (ROOT / filename).write_text(html, encoding='utf-8')
        print(f'{filename}: {len(html.encode("utf-8")):,} bytes')

if __name__ == '__main__':
    build()
