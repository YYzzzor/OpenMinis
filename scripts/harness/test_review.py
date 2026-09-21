"""Behavioral tests using disposable Git repositories and fake Pi processes."""
import json
import errno
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import review


class ReviewTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.repo = self.root / 'repo'
        self.repo.mkdir()
        self.git('init', '-q')
        self.git('config', 'user.email', 'test@example.invalid')
        self.git('config', 'user.name', 'Harness Test')
        self.write('task.md', 'Implement behavior A; verify A.')
        self.write('code.py', 'original\n')
        self.write('.gitignore', 'ignored\n')
        self.git('add', '.')
        self.git('commit', '-qm', 'baseline')
        self.bundle = self.root / 'round'

    def git(self, *args):
        return subprocess.check_output(['git', '-C', str(self.repo), *args]).decode().strip()

    def write(self, name, content):
        (self.repo / name).write_text(content)

    def prepare(self):
        return review.prepare(self.repo, 'HEAD', 'task.md', self.bundle)


    def task_file(self, name, content):
        path = self.repo / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
        return path

    def test_default_does_not_read_or_export_unselected_task_records(self):
        names = ['tasks/archive/old/task.md', 'tasks/active/other/task.md',
                 'docs/tasks/active/legacy/task.md']
        for name in names:
            self.task_file(name, 'PRIVATE TASK BASE\n')
        self.git('add', '.')
        self.git('commit', '-qm', 'task records')
        for name in names:
            self.task_file(name, 'PRIVATE TASK STAGED\n')
        self.git('add', '.')
        for name in names:
            self.task_file(name, 'PRIVATE TASK UNSTAGED\n')
        original = Path.read_bytes

        def guarded(path):
            if path.is_relative_to(self.repo.resolve()) and review.task_record(path.relative_to(self.repo.resolve()).as_posix()):
                self.fail('Unselected task content was read: ' + str(path))
            return original(path)

        with patch.object(Path, 'read_bytes', guarded):
            self.prepare()
            manifest = review.verify(self.bundle, self.repo)
        self.assertEqual(manifest['state']['task_record_policy'], 'selected-only')
        for name in names:
            self.assertNotIn(name, manifest['state']['files'])
            self.assertFalse((self.bundle / 'snapshot' / name).exists())
        for path in (self.bundle / 'patches').iterdir():
            self.assertNotIn('PRIVATE TASK', path.read_text())
        self.task_file(names[0], 'different archive content')
        self.git('add', names[0])
        review.verify(self.bundle, self.repo)

    def test_archiving_does_not_leak_deleted_task_bodies_into_patches(self):
        old = self.task_file('docs/tasks/active/old/task.md', 'PRIVATE LEGACY BODY\n')
        active = self.task_file('tasks/active/done/task.md', 'PRIVATE ACTIVE BODY\n')
        self.git('add', '.')
        self.git('commit', '-qm', 'before archive')
        old.unlink()
        active.unlink()
        self.task_file('tasks/archive/done/task.md', 'PRIVATE ACTIVE BODY\n')
        self.git('add', '.')
        self.prepare()
        for path in (self.bundle / 'patches').iterdir():
            self.assertNotIn('PRIVATE', path.read_text())

    def test_selected_active_task_only_includes_explicit_requirements(self):
        task = 'tasks/active/current/task.md'
        self.task_file(task, 'Read sibling evidence.md only if requested.')
        self.task_file('tasks/active/current/evidence.md', 'Do not auto-load.')
        review.prepare(self.repo, 'HEAD', task, self.bundle)
        self.assertTrue((self.bundle / 'requirements' / task).exists())
        self.assertTrue((self.bundle / 'snapshot' / task).exists())
        self.assertFalse((self.bundle / 'snapshot/tasks/active/current/evidence.md').exists())
        self.git('add', task)
        with self.assertRaisesRegex(review.ReviewError, 'stale'):
            review.verify(self.bundle, self.repo)

    def test_archived_requirement_requires_opt_in_and_only_selected_file_is_read(self):
        archived = 'tasks/archive/old/task.md'
        self.task_file(archived, '# Archived\n## Scope\nKnown history.\n')
        self.task_file('tasks/archive/old/evidence.md', 'Unselected evidence.')
        for kwargs in ({'task': archived}, {'task': 'task.md', 'specs': [archived]},
                       {'task': 'task.md', 'spec_sections': [archived + '::Archived > Scope']},
                       {'task': 'task.md', 'spec_references': [archived + '::Archived > Scope']}):
            with self.subTest(kwargs=kwargs):
                with self.assertRaisesRegex(review.ReviewError, '--include-archive'):
                    review.prepare(self.repo, 'HEAD', output=self.bundle, **kwargs)
                self.assertFalse(self.bundle.exists())
        review.prepare(self.repo, 'HEAD', archived, self.bundle, include_archive=True)
        review.verify(self.bundle, self.repo)
        self.assertTrue((self.bundle / 'requirements' / archived).exists())
        self.assertFalse((self.bundle / 'snapshot/tasks/archive/old/evidence.md').exists())
        self.task_file(archived, 'Changed selected archive requirement.')
        with self.assertRaisesRegex(review.ReviewError, 'stale'):
            review.verify(self.bundle, self.repo)
        with self.assertRaisesRegex(review.ReviewError, 'nonignored'):
            review.prepare(self.repo, 'HEAD', archived, self.root / 'excluded',
                           exclusions=['tasks/archive'], include_archive=True)

    def test_legacy_bundle_without_policy_keeps_original_archive_binding(self):
        archived = 'tasks/archive/old/task.md'
        self.task_file(archived, 'Legacy archive content.')
        self.git('add', '.')
        self.git('commit', '-qm', 'legacy records')
        self.prepare()
        # 构造旧 schema fixture：历史快照曾包含整个记录树，不重写其绑定策略。
        manifest = json.loads((self.bundle / 'manifest.json').read_text())
        manifest['state'] = review.state(self.repo.resolve(), 'HEAD', ['task.md'])
        destination = self.bundle / 'snapshot' / archived
        destination.parent.mkdir(parents=True)
        destination.write_bytes((self.repo / archived).read_bytes())
        manifest['artifacts'] = review.artifact_hashes(self.bundle)
        manifest.pop('snapshot_id')
        manifest['snapshot_id'] = review.digest(review.encoded(manifest))
        review.atomic_json(self.bundle / 'manifest.json', manifest)
        review.verify(self.bundle, self.repo)
        self.task_file(archived, 'Legacy binding must still notice this change.')
        with self.assertRaisesRegex(review.ReviewError, 'stale'):
            review.verify(self.bundle, self.repo)
        review.verify(self.bundle)

    def test_section_requirements_embed_only_required_context_and_bind_full_sources(self):
        self.write('spec.md', '# Spec\nGlobal condition.\n## A\nRequired behavior.\n## B\nOptional behavior.\n')
        snapshot = review.prepare(self.repo, 'HEAD', 'task.md', self.bundle,
                                  spec_sections=['spec.md::Spec > A'],
                                  spec_references=['spec.md::Spec > B'])
        manifest = review.verify(self.bundle, self.repo)
        request = (self.bundle / 'request.md').read_text()
        self.assertIn('Required behavior.', request)
        self.assertIn('Global condition.', request)
        self.assertNotIn('Optional behavior.', request)
        self.assertNotIn('Optional behavior.', (self.bundle / 'manifest.json').read_text())
        self.assertNotIn('Required behavior.', (self.bundle / 'manifest.json').read_text())
        self.assertEqual(manifest['spec_selections'][0]['segments'][-1],
                         {'start_line': 3, 'end_line': 4, 'role': 'selected subtree'})
        self.assertIn('Optional reference: requirements/spec.md :: Spec > B', request)
        self.assertEqual((self.bundle / 'requirements/spec.md').read_bytes(), (self.repo / 'spec.md').read_bytes())
        self.assertEqual(manifest['snapshot_id'], snapshot)
        self.assertEqual(manifest['spec_selections'][0]['source_sha256'], manifest['state']['requirements']['spec.md'])
        self.write('spec.md', (self.repo / 'spec.md').read_text() + 'Outside selected section changed.\n')
        with self.assertRaisesRegex(review.ReviewError, 'stale'):
            review.verify(self.bundle, self.repo)
        (self.bundle / 'request.md').write_text(request.replace('Required behavior.', 'Altered behavior.'))
        with self.assertRaisesRegex(review.ReviewError, 'integrity'):
            review.verify(self.bundle)

    def test_whole_spec_remains_mandatory(self):
        self.write('spec.md', '# Spec\nAll required.\n')
        review.prepare(self.repo, 'HEAD', 'task.md', self.bundle, specs=['spec.md'])
        request = (self.bundle / 'request.md').read_text()
        self.assertIn('Requirements:\n- requirements/task.md\n- requirements/spec.md\n', request)
        self.assertEqual(review.verify(self.bundle)['spec_selections'], [])

    def test_missing_section_rejects_bundle_without_partial_output(self):
        self.write('spec.md', '# Spec\nOnly text.\n')
        with self.assertRaisesRegex(ValueError, 'Missing'):
            review.prepare(self.repo, 'HEAD', 'task.md', self.bundle,
                           spec_sections=['spec.md::Spec > Missing'])
        self.assertFalse(self.bundle.exists())

    def fake_pi(self, body):
        pi = self.root / 'fake-pi'
        pi.write_text('#!/usr/bin/env python3\nimport sys,json,time\nfrom pathlib import Path\n'
                      'if "--version" in sys.argv:\n print("fake 1.0"); sys.exit(0)\n' + body)
        pi.chmod(0o755)
        return str(pi)

    def report_body(self, conclusion='no_findings'):
        return ('m=json.loads(Path("manifest.json").read_text())\n'
                'print(json.dumps({"snapshot_id":m["snapshot_id"],"conclusion":' + repr(conclusion) +
                ',"coverage":"Changed behavior and task","limitations":"Tests not executed", "findings":[]}))\n')

    def test_dirty_snapshot_captures_both_index_and_actual_code(self):
        self.write('code.py', 'staged\n')
        self.git('add', 'code.py')
        self.write('code.py', 'unstaged\n')
        self.write('new.py', 'new\n')
        self.write('ignored', 'excluded')
        self.prepare()
        manifest = review.verify(self.bundle, self.repo)
        self.assertEqual((self.bundle / 'snapshot/code.py').read_text(), 'unstaged\n')
        self.assertTrue((self.bundle / 'snapshot/new.py').exists())
        self.assertFalse((self.bundle / 'snapshot/ignored').exists())
        self.assertIn('+staged', (self.bundle / 'patches/staged.patch').read_text())
        self.assertIn('+unstaged', (self.bundle / 'patches/unstaged.patch').read_text())
        self.assertIn('?? new.py', manifest['state']['status'])
        with self.assertRaises(review.ReviewError):
            self.prepare()

    def test_stale_code_requirements_and_index_are_detected(self):
        self.prepare()
        original = (self.repo / 'task.md').read_text()
        self.write('task.md', 'Changed acceptance')
        with self.assertRaisesRegex(review.ReviewError, 'stale'):
            review.verify(self.bundle, self.repo)
        self.write('task.md', original)
        self.write('code.py', 'modified')
        with self.assertRaisesRegex(review.ReviewError, 'stale'):
            review.verify(self.bundle, self.repo)
        review.verify(self.bundle)  # The old snapshot remains independently verifiable.

    def test_staging_same_worktree_invalidates_git_binding(self):
        self.write('code.py', 'modified')
        self.prepare()
        self.git('add', 'code.py')
        with self.assertRaisesRegex(review.ReviewError, 'stale'):
            review.verify(self.bundle, self.repo)

    def test_tampering_detected(self):
        self.prepare()
        (self.bundle / 'snapshot/code.py').write_text('tampered')
        with self.assertRaisesRegex(review.ReviewError, 'integrity'):
            review.verify(self.bundle)

    @unittest.skipUnless(os.name == 'posix', 'Requires POSIX byte filenames')
    def test_non_utf8_filename_roundtrip_and_staleness(self):
        name = os.fsdecode(b'bad\xffname.py')
        try:
            self.write(name, 'original bytes')
        except UnicodeEncodeError:
            self.skipTest('Filesystem encoding rejects byte filenames')
        except OSError as error:
            if error.errno in (errno.EINVAL, errno.EILSEQ):
                self.skipTest('Filesystem rejects non-UTF-8 filenames')
            raise
        self.write('规范.md', '# 规范\n保留旧版 Unicode 编码。\n')
        review.prepare(self.repo, 'HEAD', 'task.md', self.bundle, specs=['规范.md', name])
        manifest = review.verify(self.bundle, self.repo)
        self.assertIn(name, manifest['state']['files'])
        self.assertEqual((self.bundle / 'snapshot' / name).read_bytes(), b'original bytes')
        self.assertEqual((self.bundle / 'requirements' / name).read_bytes(), b'original bytes')
        self.assertIn('规范.md'.encode(), (self.bundle / 'manifest.json').read_bytes())
        self.assertIn(r'bad\udcffname.py', (self.bundle / 'request.md').read_text())
        self.write(name, 'changed bytes')
        with self.assertRaisesRegex(review.ReviewError, 'stale'):
            review.verify(self.bundle, self.repo)

    def test_modified_or_truncated_reports_reject_check_and_export(self):
        self.prepare()
        review.run(self.bundle, 'deepseek', 'model', self.fake_pi(self.report_body()), 5)
        for name in ('report.txt', 'report.json', 'report.md'):
            path = self.bundle / name
            original = path.read_bytes()
            for replacement in (b'', original + b'altered'):
                with self.subTest(name=name, replacement=replacement[:10]):
                    path.write_bytes(replacement)
                    with self.assertRaisesRegex(review.ReviewError, 'Report integrity mismatch'):
                        review.verify(self.bundle)
                    output = self.root / 'tampered-export'
                    with self.assertRaisesRegex(review.ReviewError, 'Report integrity mismatch'):
                        review.export(self.bundle, self.repo, output)
                    self.assertFalse(output.exists())
                    path.write_bytes(original)
        review.verify(self.bundle, self.repo)

    def test_report_surrogate_is_preserved_and_rendered_as_escape(self):
        self.prepare()
        body = ('m=json.loads(Path("manifest.json").read_text())\n'
                'print(json.dumps(dict(snapshot_id=m["snapshot_id"], conclusion="no_findings", '
                'coverage=chr(0xdcff), limitations="Static only", findings=[])))\n')
        result = review.run(self.bundle, 'deepseek', 'model', self.fake_pi(body), 5)
        self.assertEqual(result['state'], 'reviewed')
        self.assertEqual(json.loads((self.bundle / 'report.json').read_text())['coverage'], chr(0xdcff))
        self.assertIn(r'\udcff', (self.bundle / 'report.md').read_text(encoding='utf-8'))
        review.verify(self.bundle, self.repo)
        review.export(self.bundle, self.repo, self.root / 'surrogate-export')

    def test_deleted_files_preserved_in_diff(self):
        (self.repo / 'code.py').unlink()
        self.prepare()
        self.assertFalse((self.bundle / 'snapshot/code.py').exists())
        self.assertIn('deleted file', (self.bundle / 'patches/base-to-worktree.patch').read_text())


    def test_unselected_archive_index_conflict_still_blocks_review(self):
        name = 'tasks/archive/conflict/task.md'
        blob = self.git('hash-object', 'code.py')
        entries = ''.join('100644 ' + blob + ' ' + str(stage) + '\t' + name + '\n' for stage in (1, 2, 3))
        subprocess.run(['git', '-C', str(self.repo), 'update-index', '--index-info'],
                       input=entries.encode(), check=True)
        with self.assertRaisesRegex(review.ReviewError, 'Resolve index conflicts'):
            self.prepare()
        self.assertFalse(self.bundle.exists())

    def test_reject_symlink_and_unfinished_operation(self):
        (self.repo / 'link').symlink_to('code.py')
        with self.assertRaisesRegex(review.ReviewError, 'Symlinks'):
            self.prepare()
        (self.repo / 'link').unlink()
        (self.repo / '.git/MERGE_HEAD').write_text(self.git('rev-parse', 'HEAD'))
        with self.assertRaisesRegex(review.ReviewError, 'Unfinished'):
            self.prepare()
        self.assertFalse(self.bundle.exists())

    def test_reject_submodule(self):
        self.git('update-index', '--add', '--cacheinfo', '160000,' + self.git('rev-parse', 'HEAD') + ',dep')
        with self.assertRaisesRegex(review.ReviewError, 'Submodules'):
            self.prepare()

    def test_explicit_submodule_exclusion_records_gitlink(self):
        commit = self.git('rev-parse', 'HEAD')
        self.git('update-index', '--add', '--cacheinfo', '160000,' + commit + ',dep')
        review.prepare(self.repo, 'HEAD', 'task.md', self.bundle, exclusions=['dep'])
        manifest = review.verify(self.bundle, self.repo)
        self.assertEqual(manifest['state']['excluded_gitlinks']['dep']['index_commit'], commit)
        self.assertFalse((self.bundle / 'snapshot/dep').exists())
        self.assertIn('- dep', (self.bundle / 'request.md').read_text())
        self.assertNotIn('diff --git a/dep', (self.bundle / 'patches/base-to-worktree.patch').read_text())

    def test_explicit_directory_exclusion_omits_contents(self):
        (self.repo / 'generated').mkdir()
        (self.repo / 'generated/output').write_text('not reviewed')
        review.prepare(self.repo, 'HEAD', 'task.md', self.bundle, exclusions=['generated'])
        self.assertFalse((self.bundle / 'snapshot/generated').exists())
        with self.assertRaises(review.ReviewError):
            review.prepare(self.repo, 'HEAD', 'task.md', self.root / 'bad', exclusions=['task.md'])

    def test_reject_inside_repo_and_ignored_requirement(self):
        with self.assertRaises(review.ReviewError):
            review.prepare(self.repo, 'HEAD', 'task.md', self.repo / 'round')
        self.write('ignored', 'secret')
        with self.assertRaisesRegex(review.ReviewError, 'nonignored'):
            review.prepare(self.repo, 'HEAD', 'ignored', self.bundle)

    def test_successful_review_retains_binding_and_readonly_flags(self):
        snapshot = self.prepare()
        pi = self.fake_pi(self.report_body())
        result = review.run(self.bundle, 'deepseek', 'explicit-model', pi, 5)
        self.assertEqual(result['state'], 'reviewed')
        self.assertEqual(result['snapshot_id'], snapshot)
        self.assertIn('--no-context-files', result['command'])
        self.assertIn('--no-extensions', result['command'])
        self.assertIn('read,grep,find,ls', result['command'])
        self.assertTrue((self.bundle / 'report.md').exists())
        self.assertIn(snapshot, (self.bundle / 'report.txt').read_text())
        with self.assertRaisesRegex(review.ReviewError, 'already started'):
            review.run(self.bundle, 'deepseek', 'model', pi)

    def test_partial_failed_timeout_and_unable_are_not_success(self):
        bodies = ['print("partial response")', 'print("error");sys.exit(2)',
                  'print("partial",flush=True);time.sleep(5)', self.report_body('unable')]
        for n, body in enumerate(bodies):
            with self.subTest(n=n):
                self.bundle = self.root / ('round-' + str(n))
                self.prepare()
                pi = self.fake_pi(body)
                with self.assertRaises(review.ReviewError):
                    review.run(self.bundle, 'deepseek', 'model', pi, 0.2)
                self.assertEqual(json.loads((self.bundle / 'status.json').read_text())['state'], 'incomplete')
                self.assertTrue((self.bundle / 'report.txt').exists())

    def test_report_binding_and_completeness(self):
        with self.assertRaises(review.ReviewError):
            review.validate_report(json.dumps({'snapshot_id': 'wrong'}), 'expected')
        report = {'snapshot_id': 'expected', 'conclusion': 'blocking', 'coverage': 'all',
                  'limitations': 'none', 'findings': [{'id': 'R1'}]}
        with self.assertRaises(review.ReviewError):
            review.validate_report(json.dumps(report), 'expected')

    def test_export_requires_freshness_and_preserves_original_report(self):
        self.prepare()
        review.run(self.bundle, 'deepseek', 'model', self.fake_pi(self.report_body()), 5)
        output = self.root / 'export'
        review.export(self.bundle, self.repo, output)
        self.assertEqual((output / 'report.txt').read_bytes(), (self.bundle / 'report.txt').read_bytes())
        self.write('task.md', 'new acceptance')
        with self.assertRaisesRegex(review.ReviewError, 'stale'):
            review.export(self.bundle, self.repo, self.root / 'stale-export')

    def test_json_list_report_is_incomplete(self):
        with self.assertRaisesRegex(review.ReviewError, 'object'):
            review.validate_report('[]', 'snapshot')

    def test_missing_executable_is_durable_failure(self):
        self.prepare()
        with self.assertRaises(review.ReviewError):
            review.run(self.bundle, 'deepseek', 'model', str(self.root / 'missing'))
        status = json.loads((self.bundle / 'status.json').read_text())
        self.assertEqual(status['state'], 'incomplete')


if __name__ == '__main__':
    unittest.main()
