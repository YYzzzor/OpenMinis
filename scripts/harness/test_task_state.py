import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import task_state


class RecoveryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.git('init', '-q')
        self.git('config', 'user.email', 'test@example.invalid')
        self.git('config', 'user.name', 'Test')
        (self.root / 'task.md').write_text('Status: active\nPending proposal: not approved\n')
        (self.root / 'code').write_text('before')
        self.git('add', '.')
        self.git('commit', '-qm', 'initial')

    def git(self, *args):
        return task_state.git(self.root, *args)

    def test_checkpoint_matches_and_detects_same_status_content_change(self):
        (self.root / 'code').write_text('dirty one')
        first = task_state.state(self.root, 'task.checkpoint.json')
        task_state.atomic_json(self.root / 'task.checkpoint.json', first)
        self.assertEqual(first, task_state.state(self.root, 'task.checkpoint.json'))
        (self.root / 'code').write_text('dirty two')
        second = task_state.state(self.root, 'task.checkpoint.json')
        self.assertEqual(first['status'], second['status'])
        self.assertNotEqual(first['files'], second['files'])

    def test_staging_and_untracked_and_operations(self):
        first = task_state.state(self.root, 'task.checkpoint.json')
        (self.root / 'code').write_text('changed')
        self.git('add', 'code')
        (self.root / 'new').write_text('untracked')
        (self.root / '.git/MERGE_HEAD').write_bytes(self.git('rev-parse', 'HEAD'))
        second = task_state.state(self.root, 'task.checkpoint.json')
        self.assertNotEqual(first['index'], second['index'])
        self.assertEqual(second['file_count'], first['file_count'] + 1)
        self.assertIn('MERGE_HEAD', second['operations'])

    def test_failed_replace_preserves_previous_checkpoint(self):
        p = self.root / 'task.checkpoint.json'
        task_state.atomic_json(p, {'old': True})
        with patch('task_state.os.replace', side_effect=OSError('interrupted')):
            with self.assertRaises(OSError):
                task_state.atomic_json(p, {'old': False})
        self.assertEqual(json.loads(p.read_text()), {'old': True})
        self.assertFalse(list(self.root.glob('.task.checkpoint.json*')))

    def test_inspection_does_not_change_pending_proposal(self):
        original = (self.root / 'task.md').read_bytes()
        script = Path(task_state.__file__).resolve()
        result = subprocess.run(['python3', str(script), 'inspect', str(self.root/'task.md')], capture_output=True)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(json.loads(result.stdout)['result'], 'missing_checkpoint')
        self.assertEqual((self.root / 'task.md').read_bytes(), original)


if __name__ == '__main__':
    unittest.main()
