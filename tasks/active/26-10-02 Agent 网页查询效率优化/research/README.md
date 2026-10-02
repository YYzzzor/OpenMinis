# 研究资料索引

当前任务是[Agent 网页查询效率优化](../task.md)。
两份2026-10-01研究已于2026-10-02集中恢复至本目录。
原阶段研究保留完成状态，网页读取产品尚未实现。

## 阅读顺序

| 顺序 | 文档 | 阅读后可以了解什么 |
| --- | --- | --- |
| 1 | [统一网页读取实施方案](03-web-read-proposal.md) | 当前选定的解决方式及分步实施。 |
| 2 | [原手机会话调查](01-build8-agent-latency/verification.md) | 查询长间隔、95的统计口径及导出缺口。 |
| 3 | [模拟器复现与 Pi 对照](01-build8-agent-latency/reproduction.md) | 导航等待、接口探针及实际运行证据。 |
| 4 | [BrowserUse 与 HTTP 对照](02-browser-http-comparison/verification.md) | 原18案例、5案例复测及完整查询的计时范围。 |

官方设计依据及已确认的 JSON、诊断和分组安排见[设计参考](04-web-read-design-references.md)。

## 目录安排

```text
research/
  README.md
  01-build8-agent-latency/
    history.md          原任务完成记录
    verification.md     手机静态调查
    reproduction.md     模拟器、Pi 与接口实验
    evidence/           原始文件与脚本
  02-browser-http-comparison/
    history.md          原覆盖任务完成记录
    verification.md     对照、复测及流程建议
    evidence/           快照、计时、脚本及 Agent 记录
  03-web-read-proposal.md
  04-web-read-design-references.md
```

## 研究结论的边界

| 证据 | 已知结论 | 尚不能证明什么 |
| --- | --- | --- |
| 原手机会话 | 用时约13分26秒；95对应59工具块和36思考块。 | 导出缺少工具结果，无法还原每次导航耗时。 |
| 前台模拟器高德查询 | 5次导航累计约162秒；约229秒时因接口错误停止。 | 没有最终回答，不能作为成功查询提速基线。 |
| Pi 查询 | 约81秒生成回答。 | 环境、协议、工具及提示不同，不能严格排名框架性能。 |
| 可控延迟页面 | 正文可用后，浏览器仍等待导航完成。 | 尚未定位真实高德页面中阻止完成的具体资源。 |
| 原生 URLSession 探针 | macOS 路线返回了被测内容。 | 不是已实现的 iOS 工具。 |
| 一次完整 Agent 对照 | BrowserUse 11.800秒，现有 iSH HTTP 15.401秒。 | 单次结果不能证明一般性能；定位和工具往返影响总时间。 |

真机锁屏、能耗及新工具完整回归仍未验证。
历史报告和原始实验资料保持原文，当前解释以本任务方案为准。

## 本轮新增验证入口

当前集合保留原18案例，新增48案例，共66个场景。

| 入口 | 用途 |
| --- | --- |
| [测试说明](../validation/README.md) | 区分测试输入、产品和 Agent 证据。 |
| [完整清单](../validation/cases.json) | 查阅48个新增案例的条件及判据。 |
| [分组清单](../validation/groups.json) | 安排20个主要组及5类 Agent 查询。 |
| [结果契约](../validation/result-contract.md) | 查阅模型结果字段和诊断边界。 |
| [iOS 专项步骤](../validation/ios-acceptance.md) | 执行截止时间、隔离、接管和共存验收。 |
| [网页读取 Spec](../../../../docs/specs/ios-web-read.md) | 查阅27条拟议规则。 |
| [验证记录](../verification.md) | 查阅各轮检查及审查处置。 |

## 原位置与当前位置

| 原位置 | 当前目录 |
| --- | --- |
| `tasks/archive/26-10-01 Build 8 Agent 查询耗时排查/` | `01-build8-agent-latency/`。 |
| `tasks/archive/26-10-01 网页获取广覆盖对照测试/` | `02-browser-http-comparison/`。 |

原任务的 `task.md` 只更名为 `history.md`，内容未修改。
历史报告中的 `/private/tmp/minisx-build8-agent-latency` 表示实验当时的位置。
历史 active/archive 绝对路径也保留当时含义。
当前仓库是 `/Users/huyuanzhao/Coding/Projects/OpenMinis`。

原始 JSON、日志和脚本保留绝对路径，便于核对证据。
快照位于各研究的 `evidence/snapshots`、`repeat-snapshots` 或 `followup-snapshots`。
旧脚本依赖当时工作目录及认证缓存。
新实验先适配路径和执行边界，再运行脚本。

原117文件迁移核对见[逐文件记录](../evidence/research-migration-check.json)。
