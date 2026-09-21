# 任务目录与归档验证

## 自动测试

命令：`python3 -B -m unittest discover -s scripts/harness -p 'test_*.py' -v`。
结果：Ran 42 tests，OK (skipped=1)。其中一个既有非 UTF-8 文件名测试因 macOS 平台文件名限制跳过；其他 41 项通过。原始日志 evidence/tests-full.log。

重点覆盖：默认不 read_bytes 归档文件；任务记录不进入三类 patch；active→archive 的旧路径删除正文不出现在审查；只纳入明确选择记录；显式归档权限门；同目录邻居不自动纳入；暂存 blob 与模式变化能检出；归档中冲突仍阻止审查；旧 manifest 维持原语义。

## 迁移与入口

原有 10 任务：9 done 移 archive，1 blocked 留 active。本次另建 active 任务，完成后也会归档。原 119 文件完整移动；102 个审查/证据/检查点保留原字节，普通作者维护文档仅修正路径与链接。

默认 rg 搜索和发现不列 archive；显式归档文件仍可访问，Git 不忽略任务正文。docs/tasks 已不存在；维护中文档链接全有效。旧提案、原审查清单和历史检查点保留原路径，不伪造旧快照更新。

## 证据范围

本次不改 App 源码；只验证 Harness 和迁移。子 Agent 独立核查了有效规则与脚本实现，未发现阻断不一致。Pi 材料限定为本次 Harness 代码、规则、所选任务与验证记录，不含 App 源码或归档任务正文。

## 迁移映射与复核后验证

完整的机器可读迁移清单见 [migration.json](migration.json)，包括 10 个任务状态与旧/新路径、119 个文件的原/当前 SHA-256、原始字节数，以及 102 个须保持原字节的证据文件标记。原始迁移前清单仍在 evidence/migration-before.json，原路径映射在 evidence/migration-map.json。后续需要回退时依据这些文件按任务移动，不覆盖期间新增工作。历史任务正文不为复核而默认展开。

Pi 001 返回 reviewed / nonblocking。主 Agent 在 export 后、其它改动前实际运行 check --repo 仍成功，确认新 selected-only 策略下未选择的 reviews 目录不触发 stale；已修正操作说明，不能把 check 成功等同全仓未变化。旧路径搜索忽略规则已补入并在临时目录验证。迁移清单与当前文件再次核对，原始数量与 SHA 一致。
