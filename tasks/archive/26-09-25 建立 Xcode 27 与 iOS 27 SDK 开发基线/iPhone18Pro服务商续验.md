# iPhone 18 Pro：已配置服务商的实际验证

日期：2026-09-26，约09:12—09:28（Asia/Shanghai）。用户明确要求改用名为“iPhone 18 Pro”的模拟器。精确UDID：479131C9-8187-44E7-8510-A499D7AC3034；iOS27.0。已安装MinisX 1.13 / build1，DTXcode2700、Xcode27A266a、SDK iphonesimulator27.0、MinimumOS26.0。本轮未重新构建或安装App。

## 本轮结论

| 检查 | 结果与具体证据 |
|---|---|
| 已配置服务商的实际请求 | 通过。新建“SDK27 迁移冒烟测试”，使用现有Default Models分组中DeepSeek / DeepSeek-V4.1-Flash，三次请求全部得到回复；没有改服务商或模型全局配置。 |
| 短回复 | 09:19:30发送，收到精确的SDK27_CHAT_OK。 |
| 较长回复与后台完成 | 第二轮生成30条样本文本，2805字符，末尾SDK27_STREAM_DONE。发送后切到系统设置，采样约12秒时isRunning变为false，返回App可见完整结果。此为短时间后台完成证据，不代表超过系统宽限窗口的长任务已验证。 |
| 真实AI任务的Live Activity | 初始“增强后台运行”为关闭，因此前两次请求没有创建任务Activity，符合当前代码的开关条件。临时开启后，第三轮40条虚构花园样本文本成功返回3847字符及SDK27_ACTIVITY_DONE；09:24:41创建633E0831-9B92-41AF-8CE5-CF4C14233D64，09:24:53转为completed。 |
| 灵动岛 | 同一活动compactLeading、compactTrailing、expanded的系统WidgetRenderer日志均为LIVE；截图仍未呈现覆盖层。系统渲染证据增强，但视觉外观仍未完成验收，尚不能区分捕获限制和实际显示异常。 |
| File Provider | 在这台模拟器也复现“已暂停与MinisX同步”；位置可见，根目录仅显示shared及只读标记。未修改或读取文件正文，未重启、重置域或清理数据。本轮未读取它的私有FileProvider数据库，不能把另一台设备的具体错误链直接套用到它。 |
| SwiftUI运行警告 | 在09:19:29与09:21:07的普通消息发送期间，出现Publishing changes from within view updates is not allowed；每个时间点有两条重复诊断。本轮没有注入XCTest夹具，说明警告不仅见于上一轮临时夹具。未观察到崩溃、回复丢失或消息重复，尚未定位具体调用点，也没有iOS26对照来证明是新回归。 |
| 工具调用 | 三条助手回复均无toolCalls，验证未让模型操作文件、日历或记忆。没有覆盖Agent工具执行、附件处理或其他服务商。 |

本轮通过真实发送按钮发出请求；AXe键盘输入未写入，改用应用自身已认证debug.inputText接口写入草稿，再核对界面并发送。已只读确认8321端口所属进程为目标UDID内的Minis，不接触其他模拟器。通过正常localhost配对获取临时调试令牌，没有关闭认证、读取服务商API Key或修改产品代码。配对令牌已通过debug.auth.revoke撤销，本地凭据文件已移除。

## 测试数据与恢复

验证会话ID：0CC4F8A2-DEC9-4C8C-BEBC-F0AF693F7980。保留三条用户测试消息、三条助手回复供用户查看，最终App停留在该验证会话。第二条回复包含模型生成的“测试通过”等示例句子，这些内容不是本报告的验收证据；只用实际发送、完成状态、存储读回、界面和系统日志判断结果。

初始增强后台运行=false、后台朗读=false、实时活动=true、任务通知=true、隐私模式=false。开启增强后台会自动开启后台朗读；第三轮结束后已将前两项恢复false，另外三项未改。验证恢复界面已保存。模拟器剪贴板已按原始字节恢复；原内容未展示或纳入证据包。没有停止现有App进程、删除会话、改服务商配置、请求新系统权限、修改源码、提交或推送。

## 证据与边界

- [真实短回复](/Users/huyuanzhao/Documents/Codex/2026-09-25/ve/outputs/61-real-provider-response.png)
- [返回App后的完整回复末尾](/Users/huyuanzhao/Documents/Codex/2026-09-25/ve/outputs/62-real-background-response.png)
- [常用模拟器File Provider暂停](/Users/huyuanzhao/Documents/Codex/2026-09-25/ve/outputs/63-fileprovider-paused-primary.png)
- [后台设置恢复](/Users/huyuanzhao/Documents/Codex/2026-09-25/ve/outputs/64-primary-settings-restored.png)

原始采样、限定范围的日志及本轮验证消息存入证据包。初始既有聊天画面、剪贴板原内容和调试凭据未纳入交付。横屏两项按用户要求不再测试。iOS26实际运行、真机签名、发布、超过约30秒的后台持续运行、其他模型与完整测试套件仍未覆盖。流式状态日志可见text/streaming，但本轮没有逐帧证明输出动画、自动滚动或每个中间文本片段的正确性。
