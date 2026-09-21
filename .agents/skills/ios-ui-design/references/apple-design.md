# Apple 依据与项目应用

本文件按问题提供来源与应用提示；无需每次通读所有外链。整理日期：2026-09-20。以下为简要转述与项目判断，不是 Apple 官方文件的复制，也不是永久固定的参数表。

## 1. 信息层级、导航与系统组件

**官方依据：** [Get to know the new design system — WWDC25](https://developer.apple.com/videos/play/wwdc2025/356/) 讨论内容与控制层的关系，以及跨界面结构和过渡的一致性；[Build a UIKit app with the new design — WWDC25](https://developer.apple.com/videos/play/wwdc2025/284/) 展示标准组件的适配路径。

**项目应用：** 先识别页面主要任务，再选择导航、分组和操作位置。系统组件是首先评估的选项；已有自定义聊天列表或 SwiftUI/UIKit 桥接不因此成为缺陷。保留自定义的理由应指向产品行为，而不是仅说“更有设计感”。

**可观察检查：** 用户是否知道当前所在位置、下一步和退出方式；相同操作是否在相邻页面保持一致；键盘出现后主要操作是否仍可用。

## 2. 排版与可读性

**官方依据：** [The details of UI typography — WWDC20](https://developer.apple.com/videos/play/wwdc2020/10175/) 解释系统字体随字号变化的设计，以及字距、行距和字重对阅读的影响。

**项目应用：** 从语义文字样式和系统字体开始，结合真实中文与长内容检验层级。不要把网页里的固定字距或演讲中的拉丁文字示例直接套给所有字号和语言。

**可观察检查：** 主次文字是否可分辨，较大文字是否挤掉操作，长标题和多行错误信息是否仍能读懂。Dynamic Type 指用户调整系统文字大小后，界面文字与布局作相应适配。

## 3. 反馈、动效与连续性

**官方依据：** [Designing Fluid Interfaces — WWDC18](https://developer.apple.com/videos/play/wwdc2018/803/) 强调及时响应、可改变方向和连续交互；[HIG：Motion](https://developer.apple.com/design/human-interface-guidelines/motion) 建议让动效服务于理解，反馈简短且明确，避免给高频操作增加多余动作，并尽可能允许取消。

**项目应用：** 不把“即时反馈”理解为请求立即成功。例如发消息时先显示发送状态，完成后再显示成功；实际取消可用性取决于业务实现。新增动效前确认目的；保留系统已提供的细微反馈，不能用“高频就禁用全部动画”的规则一律删除。

**可观察检查：** 按下是否及时响应，拖动与释放是否连贯，退出路径是否可理解，快速连续操作是否跳变或等待，读取长消息时是否被反复动画打扰。

## 4. 材质与层级

**官方依据：** [Meet Liquid Glass — WWDC25](https://developer.apple.com/videos/play/wwdc2025/219/) 区分浮于内容之上的导航/控制层与内容层，说明过度使用或叠加玻璃会损害层级，以及系统材质的辅助功能适配。

**项目应用：** 当任务需要采用或调整材质时，先说明它如何区分操作和内容；不默认把消息气泡、列表、输入内容和每个容器都改成玻璃。iOS 26 最低版本不等于每个组件都必须使用 Liquid Glass。实际 API 选择交由现有原生开发能力核实。

**可观察检查：** 背景内容滚动或变化时，按钮和文字是否仍清楚；减少透明度、提高对比度后，信息层级与操作是否仍成立。

## 5. 无障碍与验证

**官方依据：** [Make your app visually accessible — WWDC20](https://developer.apple.com/videos/play/wwdc2020/10020/) 讨论颜色、对比度、文字适配和系统辅助设置；[Principles of inclusive app design — WWDC25](https://developer.apple.com/videos/play/wwdc2025/316/) 讨论多种获取信息和操作的方式。后续入口为 [HIG：Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)；本次该网页只返回脚本外壳，以上原则依据已读取的 WWDC 正文。

**项目应用：** 验证受本次改动影响的文字适配、辅助朗读的标签与顺序、可点击区域、对比度，以及减少动态效果后的替代表达。对尺寸或对比度作数值判断时，查当前平台和组件的官方指导，不混用 CSS 像素与 iOS 点。

**可观察检查：** 不依赖颜色、移动或触感也能理解关键状态；开启 VoiceOver 后仍可完成主要操作。静态截图、源码核查、模拟器交互、真机观察分别报告，不互相替代。

## 6. 借鉴 Emil 的部分与适配边界

参考 [apple-design](https://github.com/emilkowalski/skills/blob/main/skills/apple-design/SKILL.md)、[emil-design-eng](https://github.com/emilkowalski/skills/blob/main/skills/emil-design-eng/SKILL.md) 和 [animate](https://github.com/emilkowalski/skills/blob/main/skills/animate/SKILL.md) 的整理方式：从目的和使用场景开始，把抽象原则变成判断问题、建议与观察方法。仅借鉴组织思路，未导入上游技能内容或执行其流程。

这组技能大量面向网页。CSS、DOM、React、网页组件库和浏览器性能规则不直接适用于 SwiftUI/UIKit；作者规定的固定时长、曲线、全面禁用某类动画或自动阻断规则，不视作 Apple 官方要求。本项目根据目标、系统行为和证据决定是否采用，不新建 `plans/` 体系或重复 Harness 审批。

HIG 页面若只返回脚本外壳，可读取同一 Apple 域名下对应的文档数据。例如 [Motion 的官方数据](https://developer.apple.com/tutorials/data/design/human-interface-guidelines/motion.json)。无法读取正文时说明限制，不把搜索摘要当作完整核查；历史 WWDC 用于理解原则，具体版本能力需要另行核实。
