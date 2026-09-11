"""Section boundaries and prerequisite retention for fixed review inputs."""
import unittest

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
