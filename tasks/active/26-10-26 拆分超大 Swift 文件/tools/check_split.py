#!/usr/bin/env python3
"""检查拆分只移动了代码（任务验收 V2）。

比较基准提交与工作区之间所有改动过的 Swift 文件：
- 拆分前：基准提交中这些文件的全部行；
- 拆分后：工作区中这些文件（含新文件）的全部行。

两边都只删去 `private` / `fileprivate` 修饰符（含 `(set)` 形式），行首空白保留、逐字比较，
按多重集合比较，不看行的先后顺序。拆分后多出的行只能是 import、
原有日志声明的副本、注释、空行、`extension X {`、顶格的 `}`
和顶层同名嵌套类型别名（`typealias Section = 外层.Section`）；拆分前独有的行只能是注释或空行。
其余差异逐行报出。修饰符两边都删，所以只检查“删去 private”这一方向。

用法：
  check_split.py [--base main] [--self-test]
"""
import argparse
import collections
import re
import subprocess
import sys

MODIFIER = re.compile(r"\b(?:fileprivate|private)(?:\(set\))? ")
LOGGER = re.compile(r"^(?:(?:private|fileprivate|nonisolated\(unsafe\)) )*let \w+ = (?:AppLogger|Logger|OSLog)\(.*\)\s*$")
EXTENSION_OPEN = re.compile(r"^extension [\w.<>, ]+(?: where [^{]+)? \{\s*$")
# 成员移进 `extension 外层.内层` 后，外层的嵌套类型不再能直接查到；
# 顶层的同名别名恢复原来的名字解析（与上游 1.15 相同）。
NESTED_ALIAS = re.compile(r"^typealias (\w+) = [\w.]+\.\1$")


def git(*args):
    return subprocess.run(["git", *args], check=True, capture_output=True, text=True).stdout


def changed_swift_files(base):
    tracked = git("diff", "--name-status", "--no-renames", base, "--", "*.swift").splitlines()
    untracked = git("ls-files", "--others", "--exclude-standard", "--", "*.swift").splitlines()
    before, after = [], []
    for row in tracked:
        status, path = row.split("\t", 1)
        if status != "A":
            before.append(path)
        if status != "D":
            after.append(path)
    after += untracked
    return before, after


def normalize(line):
    return MODIFIER.sub("", line.rstrip("\n"))


def is_comment_or_blank(line):
    s = line.strip()
    return s == "" or s.startswith(("//", "/*", "*", "*/"))


def allowed_extra(line):
    s = line.strip()
    return (
        is_comment_or_blank(line)
        or s.startswith("import ")
        or s.startswith("@preconcurrency import ")
        or EXTENSION_OPEN.match(line) is not None
        or NESTED_ALIAS.match(line) is not None
        or line == "}"
    )


def compare(before_lines, after_lines):
    before = collections.Counter(normalize(l) for l in before_lines)
    after = collections.Counter(normalize(l) for l in after_lines)
    problems = []
    for line, n in sorted((after - before).items()):
        # 日志声明只能是原文件中已有声明的副本（分类名不变）。
        if LOGGER.match(line) is not None and line in before:
            continue
        if not allowed_extra(line):
            problems.append(f"+{n}  {line!r}")
    for line, n in sorted((before - after).items()):
        if not is_comment_or_blank(line):
            problems.append(f"-{n}  {line!r}")
    return problems


def read_lines(base, before_paths, after_paths):
    before = []
    for p in before_paths:
        before += git("show", f"{base}:{p}").splitlines()
    after = []
    for p in after_paths:
        with open(p, encoding="utf-8") as f:
            after += f.read().splitlines()
    return before, after


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default="main")
    ap.add_argument("--self-test", action="store_true", help="故意改一行，确认脚本能报出来")
    args = ap.parse_args()

    before_paths, after_paths = changed_swift_files(args.base)
    print(f"基准：{args.base}")
    print(f"拆分前文件（{len(before_paths)}）：" + ", ".join(before_paths))
    print(f"拆分后文件（{len(after_paths)}）：{len(after_paths)} 个")
    before, after = read_lines(args.base, before_paths, after_paths)

    if args.self_test:
        # 找一行非注释代码，改掉一个字符，必须被报出。
        idx = next(i for i, l in enumerate(after) if not allowed_extra(l) and "=" in l)
        mutated = after[:idx] + [after[idx].replace("=", "!=", 1)] + after[idx + 1:]
        caught = compare(before, mutated)
        if any("!=" in p for p in caught):
            print(f"反向测试：通过（改动的行被报出：{mutated[idx].strip()!r}）")
        else:
            print("反向测试：失败（改动的行没有被报出）")
            sys.exit(1)

    problems = compare(before, after)
    if problems:
        print(f"发现 {len(problems)} 处其他差异：")
        for p in problems:
            print("  " + p)
        sys.exit(1)
    print("无其他差异")


if __name__ == "__main__":
    main()
