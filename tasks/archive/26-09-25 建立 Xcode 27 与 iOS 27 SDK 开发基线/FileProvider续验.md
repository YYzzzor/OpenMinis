# File Provider 暂停同步原因审计

## 结论

已确认目标模拟器的 File Provider 系统数据库记录了 `memory` 和 `skills` 两个顶层项的创建失败：错误链最终落到 POSIX `EPERM`，内部原因是 `cannotCreate → cannotSetMetadata`，并各自安排了重试。这是同步失败的直接系统证据，也是 Files 显示“已暂停与 MinisX 同步”的首要候选原因。

但目前**不能确认这是整个域进入“已暂停”的唯一或最初根因**。两次 `last_error` 时间都在 app-launch/旋转测试期间，应用启动会向已注册域发出刷新信号；没有测试前的 `FP_throttle` 快照证明同一错误已经存在。错误只记录在 `memory`、`skills` 项上，`domain_wide_error=0`、错误类别为空；系统日志另有扩展请求 grace timer 超时。错误中使用的 `FPFSSetMetadataFlags` 是系统私有类型，当前 Xcode 27.0 iPhoneSimulator SDK 公共 File Provider 头文件没有其字段定义，所以无法从原始掩码确定具体失败的是哪一种元数据属性。

因此，当前已知的是**可重复观察到的按项元数据写入失败**；Files 整体暂停的根因仍未证实。现有证据不支持通过增加 reset generation 或移除域来处理它。

## 范围与方法

仅检查模拟器 `FEB53464-BDF7-4193-893B-D06D0414DBBD` 的既有文件和状态，以及 OpenMinis File Provider 源码；没有修改仓库、数据库或模拟器文件，没有重置域、重启设备或运行测试。SQLite 以只读 URI `mode=ro` 打开；没有读取 `tasks/archive/` 或其他设备。

读取了已有的 `work/fileprovider-trace.log`、`work/fileprovider-process.log`、`work/fileprovider-runtime.log`、`work/fileprovider-sample.txt` 和 `work/42-fileprovider-after-reboot.json`，并核对目标设备的 File Provider 数据库、`Domains.plist` 与 App Group 中对应目录的权限和扩展属性。最后一次只读数据库快照在 2026-09-26 00:18（Asia/Shanghai）；父任务提供的两轮测试时间分别为 00:12:39–00:13:02 和第二轮结束于 00:15:55。

## 直接证据

- 重启后的 Files AX 树含有原文“已暂停与MinisX同步”。目标设备的 `Domains.plist` 记录该域 `Enabled=true`、`Connected=false`；但该 plist 的修改时间为 2026-09-22 00:05，早于这次重启和当前采样，且这是系统内部持久状态文件，不能单独视为采样时刻的实时连接状态。
- 目标设备 `FileProvider/<domain UUID>/database/db` 的 `FP_throttle` 有 `item_id=memory` 和 `item_id=skills` 两行。两行均为 `kind=0`、`job_type=1`、`state=1`、`retry_count=11`；`domain_wide_error=0`、`domain_wide_error_category=NULL`。`last_error` 是归档的 NSError，解出的链为：

  ```text
  NSPOSIXErrorDomain code 1
    → libfssync.DocumentWharfError code 4
      → libfssync.VFSFileError code 22
        cannotCreate(Optional(...cannotSetMetadata(
          requested rawValue: 8119226119,
          failed rawValue: 8085606151)))
  ```

  POSIX code 1 对应 `EPERM`。两项最近错误时间分别是 00:12:48 和 00:15:44，后续重试时间分别约为 00:48:21 和 00:49:42。父任务提供的时间线表明，两个错误都落在 app launch/旋转验证窗口内；应用启动会触发已有域刷新。因此它们证明刷新时确有失败，但不能证明暂停前已经发生，也不能仅凭时间认定是测试操作造成。
- 错误项指向 App Group `MinisFileProvider/memory` 和 `MinisFileProvider/skills` 两个目录。目录在目标设备容器内均为 UID 501、GID 20、模式 `0755`；其中现存 Markdown 文件为 `0644`。目录和 `memory/SOUL.md` 没有 ACL 或扩展属性；`skills/skill-creator/SKILL.md` 只有 `com.apple.TextEncoding` 扩展属性。没有观察到权限或 ACL 明显拒绝属主访问的证据。上述检查只读了元数据，没有读取文件正文。
- 已有扩展日志显示 23:34:16 扩展进程启动、RunningBoard/XPC 握手成功、App Group 容器查找成功；`FPSyncTrace` 随后记录 extension `init` 成功，并枚举到现存项目。23:37:51 的增量枚举记录旧、新 anchor 相同且 `count=6`，表示这次没有新变化可提交；它不是“枚举器没有返回”，也不证明系统已完成物化或同步。
- 同期 `fileproviderd` 日志在 23:32:47 和 23:34:43 记录 `extension request grace timer ran out`；另有 23:33:17、23:35:13 的 networking grace-period 结束通知。扩展进程日志还记录两条 `EXExtensionContextClass not defined or invalid type` 和一条 libdispatch BUG 诊断。现有进程样本的主线程在扩展服务主循环等待；没有看到崩溃或持续 CPU 执行的证据。这些日志说明扩展运行/请求完成也值得关注，但没有指出超时对应哪个回调，不能据此认定它就是暂停的根因。

## 源码对照与边界

`src/ios/FileProvider/FileProviderEnumerator.swift` 的完整枚举会调用 `didEnumerate` 和 `finishEnumerating`；增量枚举在 anchor 未变时正常结束，在 anchor 变化时调用 `didUpdate` 后正常结束。已有 trace 与这两条路径相符。`FileProviderExtension.init` 建立 App Group 根目录和固定子目录；目录读取及 App Group 查找均有成功记录。当前源码中 `registerFileProviderDomain()` 在域已注册时只调用 `signalEnumerator`，并不会在普通启动时删除并重建域。

虽然源码注释提到过去的伪造 Trash 目录可能令框架暂停同步，但目标 App Group 树的既有清单和扩展启动摘要没有发现该保留标识目录或已恢复内容的迹象，不能把这条历史缺陷套用到本次故障。

私有掩码只能报告为原始数值。当前 Xcode 27.0 iPhoneSimulator SDK 的公开头文件中没有 `FPFSSetMetadataFlags` 定义，故不能确认失败位对应文件权限、扩展属性或其他字段。另因 `FP_throttle` 没有暂停前快照，也没有比测试时间更早的 `cannotSetMetadata` 载荷，无法判断错误是否早于 UI 测试或是否启动于更早的一次系统尝试。`domain_wide_error=0` 也限制了将两条按项失败直接等同于整个域暂停的推断。

## 处置建议

保持当前域与数据不变；不要仅为消除暂停标签而提高 reset generation、移除域或清空 File Provider 数据。若需要继续定因，应先获得能把私有掩码映射到具体元数据字段的 Apple 诊断信息，并在不重置域的前提下确认一次普通域刷新是否仍为这两个目录产生同一错误。当前审计到此为止，没有提出代码补丁。

## 主Agent证据核对

23:37:51增量枚举记录来自同一FEB模拟器的实时App Group trace，而非上一轮work/fileprovider-trace.log副本。主Agent于2026-09-26续验时直接读取核对，并将限定行保存为work/fileprovider-enumeration-followup.log；该时间早于两轮旋转测试。
