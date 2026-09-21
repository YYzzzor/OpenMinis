# 任务记录

任务记录独立于 docs/，位于仓库根的 tasks/。

- active/：planned、active、blocked 的任务。默认仅列出标题和状态，选定后阅读正文。
- archive/：done、cancelled 的任务及附件。完成或取消后移入，保留创建日期名称；归档不等于删除。

默认不搜索或读取 archive/，不递归跟随历史任务和附件作为背景；active 无匹配时不自动回退。只有用户点名或当前任务明确需要某份历史证据时，先说明原因，再按具体路径读取必要文件。

调用方法和记录约定见 [Harness 操作说明](../docs/harness/operations.md) 与 [任务记录格式](../docs/harness/record-formats.md)。历史审查材料和检查点保留原始路径，不因目录迁移重写其版本绑定。

根 .ignore 让普通 rg 搜索和文件发现默认略过 archive；它不影响 Git 跟踪。确需历史内容时显式给出文件路径，避免对整个归档执行无范围搜索。
