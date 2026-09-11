#!/usr/bin/env python3
"""Read complete ATX Markdown sections with source-bound prerequisite context."""
import argparse
import hashlib
import json
from pathlib import Path
import re


def selector(value):
    name, separator, heading = value.partition('::')
    if not separator or not name.strip() or not heading.strip():
        raise ValueError('Use path::Full heading > Subheading: ' + value)
    parts = [part.strip() for part in heading.split('>')]
    if not all(parts):
        raise ValueError('Empty heading component: ' + value)
    return name.strip(), parts


def headings(text):
    lines = text.splitlines(keepends=True)
    nodes, stack = [], []
    fence = None
    for index, line in enumerate(lines):
        marker = re.match(r'^ {0,3}(`{3,}|~{3,})(.*)$', line.rstrip('\r\n'))
        if fence:
            if marker and marker[1][0] == fence[0] and len(marker[1]) >= fence[1] and not marker[2].strip():
                fence = None
            continue
        if marker and (marker[1][0] != '`' or '`' not in marker[2]):
            fence = (marker[1][0], len(marker[1]))
            continue
        match = re.match(r'^ {0,3}(#{1,6})(?:[ \t]+(.*?)|[ \t]*)$', line.rstrip('\r\n'))
        if not match:
            continue
        title = re.sub(r'[ \t]+#+[ \t]*$', '', match[2] or '').strip()
        level = len(match[1])
        while stack and stack[-1]['level'] >= level:
            stack.pop()['end'] = index
        node = {'title': title, 'level': level, 'start': index, 'end': len(lines),
                'parents': list(stack), 'path': [p['title'] for p in stack] + [title]}
        nodes.append(node)
        stack.append(node)
    return lines, nodes


def extract(data, path):
    lines, nodes = headings(data.decode('utf-8'))
    matches = [node for node in nodes if node['path'] == path]
    if len(matches) != 1:
        kind = 'Missing' if not matches else 'Ambiguous'
        raise ValueError(kind + ' heading path (use complete ATX title path): ' + ' > '.join(path))
    node = matches[0]
    ranges = []
    if nodes[0]['start']:
        ranges.append((0, nodes[0]['start'], 'preamble'))
    for parent in node['parents']:
        end = next((n['start'] for n in nodes if n['start'] > parent['start']), len(lines))
        ranges.append((parent['start'], end, 'ancestor introduction'))
    ranges.append((node['start'], node['end'], 'selected subtree'))
    return {'heading_path': path, 'source_sha256': hashlib.sha256(data).hexdigest(),
            'segments': [{'start_line': start + 1, 'end_line': end, 'role': role,
                          'text': ''.join(lines[start:end])} for start, end, role in ranges]}


def render(selection, source):
    out = ['Source: ' + source, 'Heading: ' + ' > '.join(selection['heading_path']),
           'Source SHA-256: ' + selection['source_sha256']]
    for segment in selection['segments']:
        out.append('\nLines {start_line}-{end_line} ({role}):\n'.format(**segment))
        # 将原文显示为引用，避免其标题被误认为审查规则的标题。
        out.append('\n'.join('> ' + line for line in segment['text'].splitlines()))
    return '\n'.join(out) + '\n'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('list', 'read'))
    parser.add_argument('source', help='Markdown path for list; path::Full heading > Subheading for read')
    args = parser.parse_args()
    try:
        if args.action == 'list':
            data = Path(args.source).read_text(encoding='utf-8')
            print(json.dumps([{'heading_path': n['path'], 'start_line': n['start'] + 1,
                               'end_line': n['end']} for n in headings(data)[1]], ensure_ascii=False, indent=2))
        else:
            name, path = selector(args.source)
            print(render(extract(Path(name).read_bytes(), path), name))
    except (OSError, ValueError) as error:
        parser.exit(1, str(error) + '\n')


if __name__ == '__main__':
    main()
