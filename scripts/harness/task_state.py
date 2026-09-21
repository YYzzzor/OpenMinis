"""保存与核对恢复检查点；只读 Git，不自动修正工作区。"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile


def git(root, *args):
    return subprocess.check_output(['git', '-C', str(root), *args])


def atomic_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(dir=path.parent, prefix='.' + path.name)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as f:
            json.dump(value, f, ensure_ascii=True, indent=2)
            f.write('\n')
            f.flush()
            os.fsync(f.fileno())
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


ARCHIVE_ROOTS = ('tasks/archive', 'docs/tasks/archive')


def within(name, scopes):
    return any(name == scope or name.startswith(scope + '/') for scope in scopes)


def state(root, excluded, archive_scope=()):
    archive_scope = tuple(archive_scope)
    if any(Path(name).is_absolute() or '..' in Path(name).parts or
           name in ARCHIVE_ROOTS or not within(name, ARCHIVE_ROOTS) for name in archive_scope):
        raise ValueError('Archive scope must name a specific archived task, not the archive root')
    scope = ['--', '.', *[':(literal,exclude)' + name for name in (excluded, *ARCHIVE_ROOTS)]]
    selected_scope = ['--', *[':(literal)' + name for name in archive_scope], ':(literal,exclude)' + excluded]
    paths = git(root, 'ls-files', '-z', '--cached', '--others', '--exclude-standard').split(b'\0')
    hashes = {}
    for raw in sorted(set(paths)):
        if not raw:
            continue
        name = os.fsdecode(raw)
        p = root / name
        if name == excluded or (within(name, ARCHIVE_ROOTS) and not within(name, archive_scope)):
            continue
        if p.is_symlink():
            data, kind = os.fsencode(os.readlink(p)), 'symlink'
        elif p.is_file():
            data, kind = p.read_bytes(), str(p.stat().st_mode & 0o111)
        else:
            data, kind = b'<missing-or-submodule>', 'other'
        hashes[name] = [kind, hashlib.sha256(data).hexdigest()]
    operations = []
    for name in ['MERGE_HEAD', 'CHERRY_PICK_HEAD', 'REVERT_HEAD', 'rebase-merge', 'rebase-apply']:
        p = Path(os.fsdecode(git(root, 'rev-parse', '--git-path', name)).strip())
        if not p.is_absolute():
            p = root / p
        if p.exists():
            operations.append(name)
    status_args = ('status', '--porcelain=v1', '-z', '--untracked-files=all')
    # 暂存区只需绑定 blob 标识与模式；禁用重命名检测，避免读取已归档的旧正文。
    index_args = ('diff', '--cached', '--raw', '--no-abbrev', '--no-renames', '--no-ext-diff', '--no-textconv', '-z')
    status = git(root, *status_args, *scope)
    index = git(root, *index_args, *scope)
    if archive_scope:
        status += git(root, *status_args, *selected_scope)
        index += git(root, *index_args, *selected_scope)
    status = status.decode('utf-8', 'surrogateescape')
    return dict(head=git(root, 'rev-parse', 'HEAD').decode().strip(),
                branch=git(root, 'rev-parse', '--abbrev-ref', 'HEAD').decode().strip(),
                status=status, operations=operations,
                files=hashlib.sha256(json.dumps(hashes, sort_keys=True, ensure_ascii=True).encode()).hexdigest(),
                file_count=len(hashes),
                index=hashlib.sha256(index).hexdigest(),
                submodules=git(root, 'submodule', 'status', '--recursive').decode())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['inspect', 'checkpoint'])
    parser.add_argument('task', type=Path)
    parser.add_argument('--include-archive', action='store_true', help='For an archived task, include only that task directory or single-file record')
    args = parser.parse_args()
    task = args.task.resolve(strict=True)
    root = Path(git(task.parent, 'rev-parse', '--show-toplevel').decode().strip())
    checkpoint = task.with_suffix('.checkpoint.json')
    excluded = checkpoint.relative_to(root).as_posix()
    task_name = task.relative_to(root).as_posix()
    is_archived = within(task_name, ARCHIVE_ROOTS)
    if not args.include_archive and is_archived:
        parser.error('Archived tasks need explicit --include-archive; archive is not read by default')
    archive_scope = [task.parent.relative_to(root).as_posix() if task.name == 'task.md' else task_name] if is_archived else []
    current = state(root, excluded, archive_scope)
    if args.action == 'checkpoint':
        atomic_json(checkpoint, dict(task=task.relative_to(root).as_posix(), state=current))
        print('Checkpoint saved:', checkpoint)
        return 0
    if not checkpoint.exists():
        print(json.dumps(dict(result='missing_checkpoint', head=current['head'], branch=current['branch']), indent=2))
        return 2
    old = json.loads(checkpoint.read_text())['state']
    changed = [key for key in current if old.get(key) != current[key]]
    print(json.dumps(dict(result='changed' if changed else 'match', changed=changed,
                          head=current['head'], branch=current['branch'],
                          status=current['status'], operations=current['operations']), indent=2))
    return 2 if changed else 0


if __name__ == '__main__':
    raise SystemExit(main())
