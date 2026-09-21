# 构建与运行原始证据摘要

以下构建末行来自保留原日志；SHA用于绑定完整原件。具体系统调用、编译命令和警告保存在同目录完整日志中。

## build-for-testing-002.log

SHA-256: cca23c61a9b34cc481b1e0380cc6cbd79fff846f957c83204288c1e931d3eb2c

```text
** TEST BUILD SUCCEEDED **
```

## harness-tests-final.log

SHA-256: 97e320a21e6f82ee4b2b261df97812d839c7a6622078d80d9f0a428be72e46f9

```text
test_staging_and_untracked_and_operations (test_task_state.RecoveryTests.test_staging_and_untracked_and_operations) ... ok

----------------------------------------------------------------------
Ran 42 tests in 19.134s

OK (skipped=1)
```

## 产物身份与品牌

built-app-identity.json 为实际编译产物 Info.plist 读取结果；branding-validation.json 为图标哈希、本地化placeholder和名称检查。两份文件在下一轮审查中单独绑定。

## iSH实际执行

首轮快照固定后，iOS26.4测试模拟器的应用内终端执行 uname，结果为 Linux。HID/系统输入法的回车没有触发执行；点击终端自己的回车按钮后取得结果。截图 terminal-uname-26.4.png；未修改产品代码。

## build-r1.log

SHA-256: be53544821ee445f7d089d753ac7a9089ff217dd0a750849c2f84f16c6f99d28

```text
** TEST BUILD SUCCEEDED **
```
