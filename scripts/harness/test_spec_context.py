"""Section boundaries and prerequisite retention for fixed review inputs."""
import unittest
import os
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import patch

import spec_context


class SectionTests(unittest.TestCase):
    def test_nested_selection_preserves_conditions_without_unrelated_siblings(self):
        data = b'Global scope\n# Spec\nOnly platform X.\n## Execute\nOnly idempotent calls.\n### Retry\nRetry once.\n#### Exception\nNever retry Y.\n### Cancel\nUnrelated.\n## Other\nOther.\n'
        result = spec_context.extract(data, ['Spec', 'Execute', 'Retry'])
        text = spec_context.render(result, 'spec.md')
        for expected in ('Global scope', 'Only platform X.', 'Only idempotent calls.', 'Never retry Y.'):
            self.assertIn(expected, text)
        self.assertNotIn('Unrelated.', text)
        self.assertEqual(result['segments'][-1]['start_line'], 6)
        self.assertEqual(result['segments'][-1]['end_line'], 9)

    def test_fenced_headings_do_not_terminate_sections(self):
        for fence in ('```', '~~~~'):
            data = ('# Spec\n## A\n' + fence + '\n# Fake\n' + fence + '\nStill A\n## B\nOther\n').encode()
            result = spec_context.extract(data, ['Spec', 'A'])
            self.assertIn('Still A', result['segments'][-1]['text'])
            with self.assertRaisesRegex(ValueError, 'Missing'):
                spec_context.extract(data, ['Fake'])

    def test_full_paths_disambiguate_and_duplicate_paths_fail(self):
        data = b'# Spec\n## A\n### Retry\nA\n## B\n### Retry\nB\n'
        self.assertIn('B\n', spec_context.extract(data, ['Spec', 'B', 'Retry'])['segments'][-1]['text'])
        with self.assertRaisesRegex(ValueError, 'Missing'):
            spec_context.extract(data, ['Retry'])
        with self.assertRaisesRegex(ValueError, 'Ambiguous'):
            spec_context.extract(b'# Spec\n## A\nOne\n## A\nTwo\n', ['Spec', 'A'])

    def test_invalid_selectors_and_setext_not_silently_accepted(self):
        for value in ('spec.md', 'spec.md::', '::Title', 'spec.md::Title > '):
            with self.assertRaises(ValueError):
                spec_context.selector(value)
        with self.assertRaisesRegex(ValueError, 'Missing'):
            spec_context.extract(b'Title\n=====\nText\n', ['Title'])

    def test_extract_keeps_accepting_markdown_horizontal_rule_frontmatter(self):
        data = b'---\n# Spec\n## A\nBody\n'
        result = spec_context.extract(data, ['Spec', 'A'])
        self.assertEqual(result['segments'][0]['role'], 'preamble')
        self.assertEqual(result['segments'][0]['text'], '---\n')
        self.assertIn('# Spec\n', result['segments'][1]['text'])
        self.assertIn('Body\n', result['segments'][-1]['text'])


class BoundedContextTests(unittest.TestCase):
    def write_doc(self, root, name, body):
        path = Path(root) / name
        path.write_text('---\ndescription: 中文路由描述 😀\n---\n' + body, encoding='utf-8')
        return path

    def test_route_and_selected_body_have_independent_expansion_states(self):
        with TemporaryDirectory() as directory:
            path = self.write_doc(directory, 'spec.md',
                                  '# Spec\nParent introduction.\n## A\nAlpha body.\n## B\nBeta body.\n')
            output = spec_context.context([str(path) + '::Spec > A'])
        self.assertIn('Parent introduction.', output)
        self.assertIn('Alpha body.', output)
        self.assertNotIn('Beta body.', output)
        self.assertIn('- Spec (lines 4-9; 本次部分展开)', output)
        self.assertIn('- A (lines 6-7; 本次已展开)', output)
        self.assertIn('- B (lines 8-9; 本次未展开)', output)

    def test_parent_can_be_partial_while_children_keep_exact_states(self):
        with TemporaryDirectory() as directory:
            path = self.write_doc(directory, 'spec.md',
                                  '# Spec\nParent introduction.\n## A\nA small body.\n## B\n' +
                                  ('B' * 900) + '\n')
            outline = spec_context.context([str(path)], outline=True)
            budget = len(outline) + 500
            output = spec_context.context([str(path) + '::Spec'], budget, budget)
        self.assertLessEqual(len(output), budget)
        self.assertIn('A small body.', output)
        self.assertNotIn('B' * 100, output)
        self.assertIn('Spec (lines 4-', output)
        self.assertIn('本次部分展开', output)
        self.assertIn('A (lines', output)
        self.assertIn('本次已展开', output)
        self.assertIn('B (lines', output)
        self.assertIn('本次未展开', output)

    def test_exact_unicode_budgets_include_wrappers_and_multiple_documents(self):
        with TemporaryDirectory() as directory:
            first = self.write_doc(directory, 'first.md', '# One\n## Two\n正文。\n')
            second = self.write_doc(directory, 'second.md', '# Three\n## Four\nBody.\n')
            values = [str(first) + '::One > Two', str(second) + '::Three > Four']
            output = spec_context.context(values)
            exact = spec_context.context(values, 9400, len(output))
            below = spec_context.context(values, 9400, len(output) - 1)
            one_doc = spec_context.context([str(first)])
            one_doc_exact = spec_context.context([str(first)], len(one_doc), len(one_doc))
        self.assertEqual(exact, output)
        self.assertEqual(len(exact), len(output))
        self.assertLessEqual(len(below), len(output) - 1)
        self.assertIn('first.md', output)
        self.assertIn('second.md', output)
        self.assertIn('正文。', output)
        self.assertEqual(one_doc_exact, one_doc)

    def test_mutation_between_calls_uses_one_new_source_version_per_call(self):
        with TemporaryDirectory() as directory:
            path = self.write_doc(directory, 'spec.md', '# Old title\n## Old section\nOld body.\n')
            before_bytes = path.read_bytes()
            before = spec_context.context([str(path) + '::Old title > Old section'])
            path.write_text('---\ndescription: 新版本描述\n---\n# New title\n## New section\nNew body.\n',
                            encoding='utf-8')
            after_bytes = path.read_bytes()
            after = spec_context.context([str(path) + '::New title > New section'])
        self.assertIn(spec_context.hashlib.sha256(before_bytes).hexdigest(), before)
        self.assertIn(spec_context.hashlib.sha256(after_bytes).hexdigest(), after)
        self.assertIn('Old body.', before)
        self.assertNotIn('New body.', before)
        self.assertIn('新版本描述', after)
        self.assertIn('New body.', after)
        self.assertNotIn('Old body.', after)

    def test_large_outline_falls_back_to_discoverable_list_command_under_budget(self):
        with TemporaryDirectory() as directory:
            body = ''.join('## Section ' + str(index).zfill(3) + (' x' * 16) + '\nBody.\n'
                           for index in range(80))
            path = self.write_doc(directory, 'large.md', '# Large Spec\n' + body)
            output = spec_context.context([str(path)], 400, 400, outline=True)
        self.assertLessEqual(len(output), 400)
        self.assertIn('spec_context.py list', output)
        self.assertIn('Route omitted', output)
        self.assertIn('本次未展开', output)
        self.assertNotIn('Section 079', output)

    def test_outline_heading_titles_do_not_count_as_body_expansion(self):
        with TemporaryDirectory() as directory:
            path = self.write_doc(directory, 'spec.md', '# Spec\n## A\nA body.\n')
            output = spec_context.context([str(path)], outline=True)
        self.assertIn('Spec (lines 4-6; 本次未展开)', output)
        self.assertIn('A (lines 5-6; 本次未展开)', output)
        self.assertNotIn('Returned body:', output)

    def test_child_retry_never_drops_required_document_preamble(self):
        with TemporaryDirectory() as directory:
            preamble = 'GLOBAL CONDITION ' + ('P' * 1200) + '\n'
            path = self.write_doc(directory, 'spec.md',
                                  preamble + '# Spec\nParent introduction.\n'
                                  '## Small\nAllowed body.\n')
            output = spec_context.context([str(path) + '::Spec'], 900, 900)
        self.assertLessEqual(len(output), 900)
        self.assertNotIn('Allowed body.', output)
        self.assertNotIn('GLOBAL CONDITION', output)
        self.assertIn('- Small (lines', output)
        self.assertIn('本次未展开', output)

    def test_total_budget_can_skip_larger_roots_route_for_minimal(self):
        with TemporaryDirectory() as directory:
            path = Path(directory) / 'long-title.md'
            path.write_text('---\ndescription: Test\n---\n# ' + ('A' * 100) + '\nBody\n',
                            encoding='utf-8')
            previous_directory = Path.cwd()
            os.chdir(directory)
            try:
                source = 'long-title.md'
                specs, _ = spec_context._context_requests([source], outline=True)
                document = specs[0]['document']
                full = spec_context._route_text(source, document, [], 'full')
                roots = spec_context._route_text(source, document, [], 'roots')
                minimal = spec_context._route_text(source, document, [], 'minimal')
                budget = len(minimal) + 1
                output = spec_context.context([source], 9400, budget, outline=True)
                with self.assertRaisesRegex(ValueError, 'Minimal routes exceed total budget'):
                    spec_context.context([source], 9400, budget - 1, outline=True)
            finally:
                os.chdir(previous_directory)
        self.assertGreater(len(roots), len(full))
        self.assertLessEqual(len(output), budget)
        self.assertIn('Route omitted', output)
        self.assertIn('spec_context.py list', output)

    def test_interleaved_document_selectors_keep_global_body_priority(self):
        with TemporaryDirectory() as directory:
            first = self.write_doc(directory, 'a.md',
                                   '# A\n## First\nFIRST\n## Later\n' + 'L' * 300 + '\n')
            second = self.write_doc(directory, 'b.md',
                                    '# B\n## Second\n' + 'S' * 300 + '\n')
            first_two = [str(first) + '::A > First', str(second) + '::B > Second']
            total_budget = len(spec_context.context(first_two, 9400, 9400))
            original_read_bytes = Path.read_bytes
            reads = []

            def counted_read_bytes(path):
                reads.append(path.resolve())
                return original_read_bytes(path)

            values = [str(first) + '::A > First',
                      str(second) + '::B > Second',
                      str(first) + '::A > Later']
            with patch.object(Path, 'read_bytes', counted_read_bytes):
                output = spec_context.context(values, 9400, total_budget)
        self.assertIn('FIRST', output)
        self.assertIn('S' * 300, output)
        self.assertNotIn('L' * 100, output)
        self.assertCountEqual(reads, [first.resolve(), second.resolve()])
        self.assertEqual(len(reads), 2)
