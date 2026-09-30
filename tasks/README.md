# 任务记录

- `active/`：进行中的任务。恢复时只列出标题和状态行，选定后再读正文。
- `archive/`：已完成或已取消的任务，整个目录保留原名移入；归档不等于删除。
- 新任务按 [TEMPLATE.md](TEMPLATE.md) 建立；规则见 [Harness 契约](../docs/harness/contract.md)。

默认不读取 `archive/`，只在需要某条具体历史时按路径读取。根目录的 `.ignore` 让 `rg` 默认跳过 archive，不影响 Git 跟踪。
