#!/usr/bin/env python3
"""Read or index Markdown Specs with deterministic, character-bounded context."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import sys
from urllib.parse import quote


DEFAULT_PER_DOC_BUDGET = 9400
DEFAULT_TOTAL_BUDGET = 9500
EXPANDED = '本次已展开'
PARTIAL = '本次部分展开'
UNEXPANDED = '本次未展开'


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


def _frontmatter_description(lines):
    """Read the supported one-line YAML description without a YAML dependency."""
    if not lines or lines[0].strip() != '---':
        return ''
    value = None
    for line in lines[1:]:
        if line.strip() == '---':
            break
        match = re.match(r'^description:[ \t]*(.*?)[ \t]*(?:\r?\n)?$', line)
        if match and value is None:
            value = match[1]
    else:
        raise ValueError('Unterminated YAML frontmatter')
    if value is None:
        return ''
    if value:
        if value.startswith('"'):
            try:
                parsed = json.loads(value)
            except json.JSONDecodeError as error:
                raise ValueError('Invalid quoted description: ' + str(error)) from error
            if not isinstance(parsed, str):
                raise ValueError('Description must be a YAML string')
            return parsed
        if value.startswith("'"):
            if len(value) < 2 or not value.endswith("'"):
                raise ValueError('Invalid single-quoted description')
            return value[1:-1].replace("''", "'")
    return value


def parse_document(data):
    """Derive metadata, headings, and the digest from one immutable byte read."""
    text = data.decode('utf-8')
    lines, nodes = headings(text)
    return {'lines': lines, 'nodes': nodes,
            'description': _frontmatter_description(lines),
            'source_sha256': hashlib.sha256(data).hexdigest()}


def _extract_document(document, path):
    lines, nodes = document['lines'], document['nodes']
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
    return {'heading_path': path, 'source_sha256': document['source_sha256'],
            'segments': [{'start_line': start + 1, 'end_line': end, 'role': role,
                          'text': ''.join(lines[start:end])} for start, end, role in ranges]}


def extract(data, path):
    text = data.decode('utf-8')
    lines, nodes = headings(text)
    document = {'lines': lines, 'nodes': nodes,
                'source_sha256': hashlib.sha256(data).hexdigest()}
    return _extract_document(document, path)


def render(selection, source):
    out = ['Source: ' + source, 'Heading: ' + ' > '.join(selection['heading_path']),
           'Source SHA-256: ' + selection['source_sha256']]
    for segment in selection['segments']:
        out.append('\nLines {start_line}-{end_line} ({role}):\n'.format(**segment))
        # 将原文显示为引用，避免其标题被误认为审查规则的标题。
        out.append('\n'.join('> ' + line for line in segment['text'].splitlines()))
    return '\n'.join(out) + '\n'


def _merge_ranges(ranges):
    merged = []
    for start, end in sorted(ranges):
        if end <= start:
            continue
        if merged and start <= merged[-1][1]:
            merged[-1] = (merged[-1][0], max(merged[-1][1], end))
        else:
            merged.append((start, end))
    return merged


def _covered_lines(ranges):
    return sum(end - start for start, end in ranges)


def _node_status(node, ranges):
    covered = sum(max(0, min(end, node['end']) - max(start, node['start']))
                  for start, end in ranges)
    if not covered:
        return UNEXPANDED
    return EXPANDED if covered == node['end'] - node['start'] else PARTIAL


def _status_counts(document, ranges):
    counts = {EXPANDED: 0, PARTIAL: 0, UNEXPANDED: 0}
    for node in document['nodes']:
        counts[_node_status(node, ranges)] += 1
    return counts


def _quote_command_path(source):
    return shlex.quote(source)


def _doc_header(source, document):
    description = document['description'] or '(no source description)'
    return ('### Spec: ' + source + '\n'
            'Description: ' + description + '\n'
            'Source SHA-256: ' + document['source_sha256'] + '\n')


def _route_text(source, document, ranges, mode, requested=(), whole=False, limit=None):
    nodes = document['nodes']
    out = []
    size = 0

    def append(value):
        nonlocal size
        size += len(value)
        if limit is not None and size > limit:
            return False
        out.append(value)
        return True

    if not append(_doc_header(source, document)):
        return None
    if whole and nodes:
        body_lines = _covered_lines(ranges)
        body_status = UNEXPANDED
        if body_lines:
            body_status = EXPANDED if body_lines == len(document['lines']) else PARTIAL
        if not append('Document body: ' + body_status + '\n'):
            return None
    elif mode != 'full':
        for path in requested:
            node = next((candidate for candidate in nodes if candidate['path'] == path), None)
            if node:
                if not append('Requested section ' + ' > '.join(path) + ': ' +
                              _node_status(node, ranges) + '\n'):
                    return None
    if not nodes:
        state = UNEXPANDED
        if document['lines']:
            body_lines = _covered_lines(ranges)
            if body_lines:
                state = EXPANDED if body_lines == len(document['lines']) else PARTIAL
        if not append('Document body: ' + state + '\n'):
            return None
        if not append('Route: no supported ATX headings.\n'):
            return None
        return ''.join(out)

    if mode == 'full':
        if not append('Route (ATX headings; indentation shows parent sections):\n'):
            return None
        for node in nodes:
            indent = '  ' * (node['level'] - 1)
            if not append(indent + '- ' + node['title'] +
                          ' (lines ' + str(node['start'] + 1) + '-' + str(node['end']) +
                          '; ' + _node_status(node, ranges) + ')\n'):
                return None
    elif mode == 'roots':
        roots = [node for node in nodes if not node['parents']]
        if not append('Route (top-level sections; nested headings are available with list):\n'):
            return None
        nested_count = len(nodes) - len(roots)
        for node in roots:
            if not append('- ' + node['title'] +
                          ' (lines ' + str(node['start'] + 1) + '-' + str(node['end']) +
                          '; ' + _node_status(node, ranges) + ')\n'):
                return None
        if nested_count and not append(str(nested_count) + ' nested headings omitted; use list for their paths.\n'):
            return None
        if not append('Use: python3 -B scripts/harness/spec_context.py list ' +
                      _quote_command_path(source) + '\n'):
            return None
    else:
        counts = _status_counts(document, ranges)
        if not append('Route omitted (' + str(len(nodes)) + ' ATX headings).\n'):
            return None
        if not append('Expansion counts: ' + str(counts[EXPANDED]) + ' ' + EXPANDED +
                      ', ' + str(counts[PARTIAL]) + ' ' + PARTIAL + ', ' +
                      str(counts[UNEXPANDED]) + ' ' + UNEXPANDED + '.\n'):
            return None
        if not append('Use: python3 -B scripts/harness/spec_context.py list ' +
                      _quote_command_path(source) + '\n'):
            return None
    return ''.join(out)


def _body_text(document, ranges):
    lines = document['lines']
    out = []
    for start, end in ranges:
        out.append('Lines ' + str(start + 1) + '-' + str(end) + ' (source text):\n')
        for line in lines[start:end]:
            out.append('> ' + line.rstrip('\r\n') + '\n')
    return ''.join(out)


def _render_context(specs, route_modes, outline):
    blocks = []
    per_doc = []
    for spec, mode in zip(specs, route_modes):
        ranges = _merge_ranges(spec['coverage'])
        requested = [path for path, _ in spec['selections']]
        block = _route_text(spec['source'], spec['document'], ranges, mode,
                            requested, spec['whole'])
        if block is None:
            raise ValueError('Internal route budget check failed; no output was returned')
        if not outline and ranges:
            block += 'Returned body:\n' + _body_text(spec['document'], ranges)
        block += '\n'
        blocks.append(block)
        per_doc.append(len(block))
    return ''.join(blocks), per_doc


def _body_text_length(document, ranges, limit):
    size = 0
    lines = document['lines']
    for start, end in ranges:
        size += len('Lines ' + str(start + 1) + '-' + str(end) + ' (source text):\n')
        if size > limit:
            return limit + 1
        for line in lines[start:end]:
            size += len(line.rstrip('\r\n')) + 3
            if size > limit:
                return limit + 1
    return size


def _context_sizes(specs, route_modes, outline, per_doc_budget):
    sizes = []
    for spec, mode in zip(specs, route_modes):
        ranges = _merge_ranges(spec['coverage'])
        requested = [path for path, _ in spec['selections']]
        route = _route_text(spec['source'], spec['document'], ranges, mode,
                            requested, spec['whole'], per_doc_budget)
        if route is None:
            sizes.append(per_doc_budget + 1)
            continue
        size = len(route) + 1
        if size > per_doc_budget:
            sizes.append(per_doc_budget + 1)
            continue
        if not outline and ranges:
            size += len('Returned body:\n')
            size += _body_text_length(spec['document'], ranges, per_doc_budget - size)
        sizes.append(size)
    return sizes


def _choose_routes(specs, per_doc_budget, total_budget, outline):
    modes = ['full'] * len(specs)
    mode_order = ('full', 'roots', 'minimal')
    for index in range(len(specs)):
        while True:
            sizes = _context_sizes(specs, modes, outline, per_doc_budget)
            if sizes[index] <= per_doc_budget:
                break
            position = mode_order.index(modes[index])
            if position == len(mode_order) - 1:
                raise ValueError('Minimal route exceeds per-document budget for ' + specs[index]['source'])
            modes[index] = mode_order[position + 1]

    while True:
        sizes = _context_sizes(specs, modes, outline, per_doc_budget)
        total_size = sum(sizes)
        if total_size <= total_budget:
            return modes
        choices = []
        for index, mode in enumerate(modes):
            position = mode_order.index(mode)
            for next_position in range(position + 1, len(mode_order)):
                compact_modes = list(modes)
                compact_modes[index] = mode_order[next_position]
                compact_sizes = _context_sizes(specs, compact_modes, outline, per_doc_budget)
                savings = total_size - sum(compact_sizes)
                if compact_sizes[index] <= per_doc_budget and savings > 0:
                    choices.append((savings, sizes[index], -index,
                                    -next_position, compact_modes))
        if not choices:
            raise ValueError('Minimal routes exceed total budget; reduce the document selection or raise --total-budget')
        _, _, _, _, modes = max(choices, key=lambda item: item[:4])


def _try_add_ranges(specs, route_modes, outline, spec_index, additions,
                    per_doc_budget, total_budget):
    spec = specs[spec_index]
    trial = _merge_ranges(spec['coverage'] + additions)
    if trial == _merge_ranges(spec['coverage']):
        return True
    old = spec['coverage']
    spec['coverage'] = trial
    sizes = _context_sizes(specs, route_modes, outline, per_doc_budget)
    if sizes[spec_index] <= per_doc_budget and sum(sizes) <= total_budget:
        return True
    spec['coverage'] = old
    return False


def _node_ranges(document, node, include_preamble=True):
    lines, nodes = document['lines'], document['nodes']
    ranges = []
    if include_preamble and nodes and nodes[0]['start']:
        ranges.append((0, nodes[0]['start']))
    for parent in node['parents']:
        end = next((candidate['start'] for candidate in nodes
                    if candidate['start'] > parent['start']), len(lines))
        ranges.append((parent['start'], end))
    ranges.append((node['start'], node['end']))
    return ranges


def _node_intro_range(document, node):
    next_heading = next((candidate['start'] for candidate in document['nodes']
                         if candidate['start'] > node['start']), node['end'])
    return (node['start'], next_heading)


def _direct_children(document, node):
    return [candidate for candidate in document['nodes']
            if candidate['parents'] and candidate['parents'][-1] is node]


def _add_node(specs, route_modes, outline, spec_index, node,
              per_doc_budget, total_budget, include_preamble=True):
    document = specs[spec_index]['document']
    full_ranges = _node_ranges(document, node, include_preamble)
    if _try_add_ranges(specs, route_modes, outline, spec_index, full_ranges,
                       per_doc_budget, total_budget):
        return
    intro_ranges = _node_ranges(document, node, include_preamble)[:-1]
    intro_ranges.append(_node_intro_range(document, node))
    _try_add_ranges(specs, route_modes, outline, spec_index, intro_ranges,
                    per_doc_budget, total_budget)
    for child in _direct_children(document, node):
        _add_node(specs, route_modes, outline, spec_index, child,
                  per_doc_budget, total_budget, include_preamble=True)


def _context_requests(values, outline):
    specs, lookup, request_order = [], {}, []
    for value in values:
        if outline:
            name = value.strip()
            if not name or '::' in name:
                raise ValueError('--outline expects document paths without :: selectors')
            selected_path = None
            whole = False
        elif '::' in value:
            name, selected_path = selector(value)
            whole = False
        else:
            name = value.strip()
            if not name:
                raise ValueError('Empty document path')
            selected_path = None
            whole = True
        key = str(Path(name).resolve())
        if key not in lookup:
            document = parse_document(Path(name).read_bytes())
            lookup[key] = len(specs)
            specs.append({'source': Path(name).as_posix(), 'document': document,
                          'coverage': [], 'whole': False, 'selections': []})
        spec_index = lookup[key]
        spec = specs[spec_index]
        if whole:
            spec['whole'] = True
            if not outline:
                request_order.append((spec_index, None))
        elif selected_path is not None:
            selection = _extract_document(spec['document'], selected_path)
            spec['selections'].append((selected_path, selection))
            request_order.append((spec_index, selected_path))
    if not specs:
        raise ValueError('context needs at least one document path or heading selector')
    return specs, request_order


def context(values, per_doc_budget=DEFAULT_PER_DOC_BUDGET,
            total_budget=DEFAULT_TOTAL_BUDGET, outline=False):
    if per_doc_budget <= 0 or total_budget <= 0:
        raise ValueError('Character budgets must be positive integers')
    specs, request_order = _context_requests(values, outline)
    modes = _choose_routes(specs, per_doc_budget, total_budget, outline)
    if not outline:
        seen = set()
        completed_whole = set()
        for index, path in request_order:
            spec = specs[index]
            document = spec['document']
            if path is None:
                if index in completed_whole:
                    continue
                completed_whole.add(index)
                if document['lines'] and _try_add_ranges(
                        specs, modes, outline, index, [(0, len(document['lines']))],
                        per_doc_budget, total_budget):
                    continue
                if document['nodes']:
                    for node in (candidate for candidate in document['nodes'] if not candidate['parents']):
                        _add_node(specs, modes, outline, index, node,
                                  per_doc_budget, total_budget)
                continue
            key = (index, tuple(path))
            if key in seen:
                continue
            seen.add(key)
            node = next(candidate for candidate in document['nodes'] if candidate['path'] == path)
            _add_node(specs, modes, outline, index, node,
                      per_doc_budget, total_budget)
    output, sizes = _render_context(specs, modes, outline)
    if any(size > per_doc_budget for size in sizes) or len(output) > total_budget:
        raise ValueError('Internal budget check failed; no output was returned')
    return output


def _index_sources(values, output):
    if values:
        sources = [Path(value) for value in values]
    else:
        sources = sorted(Path('docs/specs').glob('*.md'), key=lambda path: path.as_posix())
    output_path = Path(output)
    filtered = []
    for source in sources:
        if source.resolve() == output_path.resolve():
            continue
        if source.is_absolute() or '..' in source.parts:
            raise ValueError('Index source paths must be relative to the repository: ' + str(source))
        filtered.append(source)
    return sorted(filtered, key=lambda path: path.as_posix())


def build_index(values=(), output='docs/specs/index.md'):
    sources = _index_sources(values, output)
    rows = ['# Spec Index', '',
            'Generated by `python3 -B scripts/harness/spec_context.py index`; edit descriptions in their source Specs.', '',
            '| Spec | Path | Description |', '| --- | --- | --- |']
    for source in sources:
        document = parse_document(source.read_bytes())
        if not document['description']:
            raise ValueError('Missing one-line YAML description: ' + source.as_posix())
        title = next((node['title'] for node in document['nodes'] if node['level'] == 1), source.stem)
        title = title.replace('|', '\\|').replace('[', '\\[').replace(']', '\\]')
        path = source.as_posix()
        relative_link = Path(os.path.relpath(source, Path(output).parent)).as_posix()
        relative_link = quote(relative_link, safe='/-._~')
        description = document['description'].replace('|', '\\|').replace('\n', ' ')
        rows.append('| [' + title + '](' + relative_link + ') | ' + path + ' | ' + description + ' |')
    return '\n'.join(rows) + '\n'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('list', 'read', 'context', 'index'))
    parser.add_argument('sources', nargs='*',
                        help='paths for list/index/context, or path::Full heading > Subheading for read/context')
    parser.add_argument('--outline', action='store_true', help='context: return route only, without body text')
    parser.add_argument('--per-doc-budget', type=int, default=DEFAULT_PER_DOC_BUDGET,
                        help='context: maximum Unicode code points per document (default: 9400)')
    parser.add_argument('--total-budget', type=int, default=DEFAULT_TOTAL_BUDGET,
                        help='context: maximum Unicode code points in the complete output (default: 9500)')
    parser.add_argument('--output', default='docs/specs/index.md', help='index output path')
    parser.add_argument('--check', action='store_true', help='index: check generated content without writing')
    args = parser.parse_args()
    try:
        if args.action == 'list':
            if len(args.sources) != 1:
                raise ValueError('list expects exactly one Markdown path')
            data = Path(args.sources[0]).read_text(encoding='utf-8')
            print(json.dumps([{'heading_path': n['path'], 'start_line': n['start'] + 1,
                               'end_line': n['end']} for n in headings(data)[1]], ensure_ascii=False, indent=2))
        elif args.action == 'read':
            if len(args.sources) != 1:
                raise ValueError('read expects exactly one path::Full heading > Subheading selector')
            name, path = selector(args.sources[0])
            print(render(extract(Path(name).read_bytes(), path), name))
        elif args.action == 'context':
            if not args.sources:
                raise ValueError('context expects at least one document path or heading selector')
            sys.stdout.write(context(args.sources, args.per_doc_budget, args.total_budget, args.outline))
        else:
            if args.outline:
                raise ValueError('--outline is only valid for context')
            generated = build_index(args.sources, args.output)
            output = Path(args.output)
            if args.check:
                if not output.is_file() or output.read_text(encoding='utf-8') != generated:
                    raise ValueError('Generated Spec index is missing or stale: ' + output.as_posix())
                print('Spec index is current: ' + output.as_posix())
            else:
                if not output.exists() or output.read_text(encoding='utf-8') != generated:
                    output.parent.mkdir(parents=True, exist_ok=True)
                    output.write_text(generated, encoding='utf-8')
                print('Generated Spec index: ' + output.as_posix())
    except (OSError, UnicodeError, ValueError) as error:
        parser.exit(1, str(error) + '\n')


if __name__ == '__main__':
    main()
