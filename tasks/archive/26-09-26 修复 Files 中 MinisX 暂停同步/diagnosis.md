# MinisX Files 暂停同步：诊断与未完成项

日期：2026-09-26。结论：**尚未修复，不满足验收。** 试验补丁已撤回，FileProvider 源码与任务开始时相同。保留同一个文件域及既有数据，没有清缓存、删除域、卸载、重置设备或更改系统权限。

## 本轮确证

1. 独立 iOS 27.0 设备 FEB53464-BDF7-4193-893B-D06D0414DBBD 的 Files 仍显示“已暂停与MinisX同步”，根目录仅有 shared；只读文字是原能力设计。系统 dump 的 scheduling state 为 running，不能说整个同步引擎断开。
2. 系统已接收8条 FP snapshot 记录（含 root/trash），工作集枚举返回6项。memory、skills 的落地任务失败，3个后代等待 parentCreation。失败在系统将项目写入 **Library/CloudStorage/FE145987-EB1F-43AB-8A94-0440CDF773FF** 的复制区，不是 App Group 源目录的 createItem 回调。先前只查 App Group 的 chmod/ACL 无法说明此处失败。
3. 11:16:34–35 实时日志显示系统通过 FPDaemonConnection host proxy 创建 dataless 目录，再在 metadata 阶段报 cannotSetMetadata → EPERM。报错掩码仍是 requested=8119226119、failed=8085606151；没有公开字段定义，未猜测具体失败位。FP_throttle 按项记录，domain-wide error 为0。
4. memory/skills 在系统 metadata 中 locked=1，shared locked=0。但域根目录同样呈现 cap:r-------- / m:rwxel，系统仍已成功落地；因此“只要 readonly/locked 就必然失败”不成立。根目录建立和子目录创建可能走不同路径，这只是后续待验证假设，**不能把 locked 认定为根因**。实际复制区根目录为0700、无 uchg/schg，不能将数据库 locked 与宿主不可变文件标志直接等同。
5. 用户明确授权的独立 iOS 26.4 对照设备 93383C87-F673-4F10-9737-8EFFFEB1CA63 也显示相同暂停界面，并出现同一 memory/skills 错误链。它保留既有 MinisX 1.13/build1，DTSDKName=iphonesimulator27.0、MinimumOS=26.0；本次仅启动、打开 Files、只读采样，随后恢复关机。两台都用 SDK27 构建，因此结果排除了“仅 iOS27 模拟器才出现”，不能区分 SDK、共同宿主环境和应用实现，也不是同源 Xcode26/27 对照。

## 已否定的最小补丁

在 FileProviderItem 增加与原 capabilities 一致的 fileSystemFlags；目录加 userExecutable，只有原有可写项加 userWritable；在 anchor 中混入 flags，让已有域重放元数据。没有 chmod、没有给 memory/skills 开写权限。

- Xcode27/SDK27 Debug build 成功；主App与3个扩展 MinimumOSVersion=26.0；签名校验通过。
- 11:14:42 新扩展确实重放6项，anchor 从 16aed41e351b7ceb 变成 c65f168353cfb493。
- 原错误处于长退避，不能直接用旧数据库行评判补丁。一次同版本覆盖安装触发系统正常更新重试，11:16:34–35 的新请求仍以 m:rwxl 创建目录并报相同EPERM，因此该具体补丁在本设备、本次实际重试中未解决问题；不能据此排除所有元数据修复。公开 fileSystemFlags 与报错私有 FPFSSetMetadataFlags 不是同一标志集合，未建立位对应关系。
- 精确撤回本任务两段新增代码，重建成功并恢复安装到FEB设备。失败补丁存于 work/rejected-explicit-flags.patch；恢复后 FileProvider 目录没有 Git diff。

## 第二项已否定的有界试验

SDK27 的公开 namespacePolicy 可要求提前枚举目录。仅 memory 使用 materializeEagerly，skills 保持 inherited 作同域对照；capabilities/contentPolicy 不变。此策略会影响缓存保留，并不适用于iOS26.4，故仅作诊断。

11:29:05 系统已接收新策略：memory=2、skills=0。11:29:36–37 实际新重试两项仍失败，日志仍把请求标为 dir dls，记录了已创建 inode 和随后 cannotSetMetadata 错误；本次截取未包含底层 sim_makeDatalessFileAt 调用，不能声称对第二项试验完整追踪了该系统调用。该具体策略未解决本次故障，故同样撤回。记录：work/namespace-experiment.patch、fp-namespace-retry.log、build-namespace.log。11:32:58恢复扩展重放后，所有namespacePolicy均回到0（inherited），anchor回到原16aed41e351b7ceb；文件域数据库UUID仍为A6056822-6F35-4E64-986D-A36F16164E8F。最终构建成功；既有文件哈希保留。最终截图为outputs/12-final-original-policy.png。

## 数据与共享任务边界

App Group 中既有2个普通文件均存在且 SHA256 与基线一致；15个 MinisChat 文件均存在，12个字节一致。变化仅在 alarm-labels.db-shm、alarm-labels.db-wal、minis-config-audit.db-shm 三个 SQLite 运行边车；未读取聊天正文，没有创建会话或请求模型。不把这些边车变化说成消息丢失，也不声称整个应用存储字节完全不变。

本任务未编辑 BUILDING.md、工程文件、ChatInputBar.swift 或其他任务文件。另一任务在执行中修改了聊天输入和测试，工程文件也出现其构建期间的变化；均保留，不冒称全仓差异完全等于开工基线。构建前检查进程，未发现并发 xcodebuild；两任务设备分别为FEB与479。本任务没有操作常用479设备。

没有提交、推送、新建分支/worktree，也没有将旧迁移任务完成或归档。

## 独立检查与局限

只读子Agent独立核对了公共SDK和原始日志，确认补丁无效、capabilities 别名无缺失、系统落地任务与扩展 createItem 不同。主Agent已核实日志与diff。经用户明确授权，将限定快照发给 DeepSeek v4 Pro，通过 Pi 完成一次只读独立审查。快照 5fa4f1b94828a2e647ac3cd958753284bf3d34f3313198c477f3fa039079b57a；原报告返回 nonblocking，但这是诊断材料审查结果，不是修复验收。审查未运行测试，未读取完整原始日志；主Agent已逐条核实3项意见，补充日志定位、根目录反例并收窄两个试验结论。原报告与处理记录已保存，更新后的诊断没有再次外发复审。

Apple公开SDK规定 allowsReading 与 allowsContentEnumerating 同位，allowsWriting 与 allowsAddingSubItems 同位；fileSystemFlags 只有POSIX和显示标志，没有公开的“关闭锁定目录”选项。依据：Xcode27 NSFileProviderItem.h；[Apple元数据文档](https://developer.apple.com/documentation/fileprovider/nsfileprovideritemprotocol/filesystemflags)。

Apple曾确认另一个只读FileProvider下载问题，但限定macOS26 Intel，原作者称26.5已修复；它不是本例的定因证据：[Apple DTS讨论](https://developer.apple.com/forums/thread/805882)。

尚未验证：暂停提示消除、完整目录枚举与文件读写恢复、真机、同源SDK对照。File Provider失败不代表CloudKit聊天同步失败。

## 后续判断点

现有证据不足以提交应用补丁。优先在独立最小复现中对比只读/可写目录，或对比真机及SDK构建，识别系统拒绝的准确字段；这些新增验证应先明确设备、安装身份和数据边界。不要用重置域或放宽只读能力代替修复。

## 证据索引

- outputs/03-locations.png：iOS27初始暂停。
- outputs/12-final-original-policy.png：最终恢复原实现及原策略后仍暂停。
- outputs/26-05-minisx-paused.png：iOS26.4对照。
- work/fp-before-dump.txt、fp-flags-replayed-dump.txt、fp-restored-dump.txt、fp-ios26-dump.txt：系统状态。
- work/fp-retry-stream.log：新重试、host proxy及失败；重点1262–1638行。
- work/host-fp-restore-stream.log：宿主桥接调用，未揭示拒绝的具体字段。
- work/build-flags.log、build-restored.log、build-namespace.log、build-final-restored.log：构建成功日志，仍含既有构建警告。
- outputs/独立审查处理.md、独立审查原报告.md：审查边界、三项发现与逐项处理；补充证据只在本地保存，未再次外发。
- work/final-integrity.json：数据哈希核对，不包含文件正文。
