# 两行最小高度与布局边界

本轮只审查以下新变化：
1. ChatInputBar.swift 的 ChatInputTypography 从 private 变为模块内可见，新增 @MainActor minimumTextHeight = ceil(按 FontSettings 缩放后的 UIFont.lineHeight * 2)。
2. AIChatView.swift 的 composerBody 自然高度分支在 fixedSize 后增加 frame(minHeight: ChatInputTypography.minimumTextHeight, alignment: .top)。

AIChatView 相对 HEAD 的其它 diff 是此前已存在的语音输入工作，不属于本轮新增；仅在与上述两行最小高度有直接交互时检查，不要求修复或验收整套语音功能。

确认目标：空白和单行时保留两行文字空间，文字从上方输入，超过两行继续原有增长、120pt 上限和滚动；已有 iPad pinned-height 分支保持。字体设置由 AIChatView 已有 @ObservedObject fontSettings 驱动重绘。额外留白放在 SwiftUI frame 内，UIKit view 仍保持自然内容高度。

关注 modifier 顺序、顶部对齐、字号缩放、清空/发送后的回落、iPad 手动高度及是否引入不必要的反复布局或资源开销。docs/specs/resource-efficiency.md 全文是必读要求。

验证边界：本轮是小范围尺寸修改，不新增只复述公式的测试；检查实际调用及编译。未安装/启动模拟器或真机；不能把静态无问题或编译成功称为完整运行/视觉验收。用户后续实际使用验收保持开放。
