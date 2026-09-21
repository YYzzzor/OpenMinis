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


    def test_archive_is_not_read_or_bound_by_default(self):
        archived = self.root / 'tasks/archive/old/task.md'
        archived.parent.mkdir(parents=True)
        archived.write_text('archive baseline')
        self.git('add', '.')
        self.git('commit', '-qm', 'archive baseline')
        original = Path.read_bytes

        def guarded(path):
            if path == archived:
                self.fail('Archived content was read without opt-in')
            return original(path)

        with patch.object(Path, 'read_bytes', guarded):
            first = task_state.state(self.root, 'task.checkpoint.json')
        archived.write_text('archive staged')
        self.git('add', 'tasks/archive')
        archived.write_text('archive unstaged')
        with patch.object(Path, 'read_bytes', guarded):
            self.assertEqual(first, task_state.state(self.root, 'task.checkpoint.json'))
        included = task_state.state(self.root, 'task.checkpoint.json', archive_scope=['tasks/archive/old'])
        self.assertEqual(included['file_count'], first['file_count'] + 1)
        archived.write_text('archive changed')
        self.assertNotEqual(included['files'], task_state.state(
            self.root, 'task.checkpoint.json', archive_scope=['tasks/archive/old'])['files'])

    def test_archived_task_cli_needs_explicit_opt_in(self):
        archived = self.root / 'tasks/archive/old/task.md'
        archived.parent.mkdir(parents=True)
        archived.write_text('Status: done')
        script = Path(task_state.__file__).resolve()
        rejected = subprocess.run(['python3', str(script), 'checkpoint', str(archived)], capture_output=True)
        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn(b'--include-archive', rejected.stderr)
        self.assertFalse(archived.with_suffix('.checkpoint.json').exists())
        saved = subprocess.run(['python3', str(script), 'checkpoint', str(archived), '--include-archive'], capture_output=True)
        self.assertEqual(saved.returncode, 0, saved.stderr)
        checked = subprocess.run(['python3', str(script), 'inspect', str(archived), '--include-archive'], capture_output=True)
        self.assertEqual(checked.returncode, 0, checked.stderr)


    def test_archival_migration_hashes_staged_metadata_without_old_body(self):
        active = self.root / 'tasks/active/done/task.md'
        active.parent.mkdir(parents=True)
        active.write_text('PRIVATE OLD TASK BODY\n')
        self.git('add', '.')
        self.git('commit', '-qm', 'before archive')
        archived = self.root / 'tasks/archive/done/task.md'
        archived.parent.mkdir(parents=True)
        active.rename(archived)
        self.git('add', '.')
        original_git = task_state.git
        observed_diffs = []

        def checked_git(root, *args):
            result = original_git(root, *args)
            if args[0] == 'diff':
                self.assertIn('--raw', args)
                self.assertIn('--no-abbrev', args)
                self.assertIn('--no-renames', args)
                self.assertNotIn('--binary', args)
                self.assertNotIn(b'PRIVATE OLD TASK BODY', result)
                observed_diffs.append(result)
            return result

        original_read = Path.read_bytes

        def guarded_read(path):
            if path == archived:
                self.fail('Migration caused passive archive reading')
            return original_read(path)

        with patch('task_state.git', checked_git), patch.object(Path, 'read_bytes', guarded_read):
            migrated = task_state.state(self.root, 'task.checkpoint.json')
        self.assertTrue(observed_diffs)
        self.assertIn(b'tasks/active/done/task.md', observed_diffs[0])
        code = self.root / 'code'
        code.write_text('staged one')
        self.git('add', 'code')
        code.write_text('unchanged visible working tree')
        first = task_state.state(self.root, 'task.checkpoint.json')
        code.write_text('staged two')
        self.git('add', 'code')
        code.write_text('unchanged visible working tree')
        second = task_state.state(self.root, 'task.checkpoint.json')
        self.assertEqual(first['files'], second['files'])
        self.assertEqual(first['status'], second['status'])
        self.assertNotEqual(first['index'], second['index'])
        self.assertNotEqual(migrated['index'], second['index'])

    def test_archive_scope_reads_only_target_and_not_neighbors(self):
        target = self.root / 'tasks/archive/target/task.md'
        target.parent.mkdir(parents=True)
        target.write_text('selected task')
        attachment = target.parent / 'evidence.md'
        attachment.write_text('selected task attachment')
        neighbor = self.root / 'tasks/archive/neighbor/task.md'
        neighbor.parent.mkdir(parents=True)
        neighbor.write_text('unselected neighbor')
        original = Path.read_bytes

        def guarded(path):
            if path == neighbor:
                self.fail('Opt-in read neighboring archive task')
            return original(path)

        with patch.object(Path, 'read_bytes', guarded):
            single = task_state.state(self.root, 'task.checkpoint.json', ['tasks/archive/target/task.md'])
            directory = task_state.state(self.root, 'task.checkpoint.json', ['tasks/archive/target'])
        self.assertEqual(directory['file_count'], single['file_count'] + 1)
        neighbor.write_text('changed unselected neighbor')
        self.git('add', 'tasks/archive/neighbor')
        self.assertEqual(directory, task_state.state(self.root, 'task.checkpoint.json', ['tasks/archive/target']))
        attachment.write_text('changed selected attachment')
        self.assertNotEqual(directory['files'], task_state.state(
            self.root, 'task.checkpoint.json', ['tasks/archive/target'])['files'])
        with self.assertRaisesRegex(ValueError, 'specific archived task'):
            task_state.state(self.root, 'task.checkpoint.json', ['tasks/archive'])

    def test_active_cli_opt_in_does_not_load_archive_tree(self):
        archived = self.root / 'tasks/archive/old/task.md'
        archived.parent.mkdir(parents=True)
        archived.write_text('old archive')
        script = Path(task_state.__file__).resolve()
        task = self.root / 'task.md'
        saved = subprocess.run(['python3', str(script), 'checkpoint', str(task), '--include-archive'], capture_output=True)
        self.assertEqual(saved.returncode, 0, saved.stderr)
        archived.write_text('changed archive')
        self.git('add', 'tasks/archive')
        checked = subprocess.run(['python3', str(script), 'inspect', str(task), '--include-archive'], capture_output=True)
        self.assertEqual(checked.returncode, 0, checked.stderr)


    def test_single_file_archive_cli_does_not_include_neighbor_records(self):
        archived = self.root / 'tasks/archive/old.md'
        archived.parent.mkdir(parents=True)
        archived.write_text('selected single-file record')
        neighbor = archived.parent / 'other.md'
        neighbor.write_text('neighbor record')
        script = Path(task_state.__file__).resolve()
        saved = subprocess.run(['python3', str(script), 'checkpoint', str(archived), '--include-archive'], capture_output=True)
        self.assertEqual(saved.returncode, 0, saved.stderr)
        neighbor.write_text('changed neighbor record')
        checked = subprocess.run(['python3', str(script), 'inspect', str(archived), '--include-archive'], capture_output=True)
        self.assertEqual(checked.returncode, 0, checked.stderr)
        archived.write_text('changed selected record')
        changed = subprocess.run(['python3', str(script), 'inspect', str(archived), '--include-archive'], capture_output=True)
        self.assertEqual(changed.returncode, 2, changed.stderr)
        self.assertEqual(json.loads(changed.stdout)['result'], 'changed')

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
