# B 波形平滑与资源边界审查

用户直接授权：“好的, 按照 B 的方式调整动画吧”。确认参数：40 ms 一阶平滑（时间常数，不是40 ms后立即抵达终点），0.6倍灵敏度，上升/回落同速，无停留无弹跳。用户还明确要求资源开销始终合理、审查重点关注；全文规范以 --spec 显式携带。

本轮只审波形组件和数据通路的增量。main/40ac6a5上已存在语音UI、实时识别和Build5发布修改；基准diff包含历史工作，不把它们误判为此次改动。VoiceWaveformView.swift是本轮核心改写；VoiceComposerPanel/InlineVoiceInputView/ShortVoiceComposerPreview仅换成专用波形源。VoiceInputPanel将音量从@Published迁到独立@Observable源，新录音reset，PCM统计改为直接遍历，保持既有感知曲线。AIChatView与VoiceActivityDetector仅提供现有调用上下文，本轮不修改。

检查：
- B参数与第一阶指数衰减一致；中途换目标从当前显示值继续；上升下降同速、数值有界且有限。
- 20个柱，按需局部绘制，不借助全局SwiftUI animation或每帧Task；显示更新请求不超过60Hz，系统可降频；动画结束或稳定输入应停止逐帧工作。
- Source更新不广播VoiceInputViewModel.objectWillChange；上层只持有Source引用，读取levels发生在波形叶子。不得引入全页动画或旧文字/波形交叉渐隐。
- 场景非活动、视图移除/卸载及reduceMotion时停止显示回调；弱引用防止display link保活控件；无需定时轮询。
- PCM计算没有整块Float数组复制及逐柱临时平方数组，仍保留旧RMS感知曲线；不更改识别音频、请求周期或文本合并。
- 报告区分静态资源边界、局部测试和真正CPU/GPU/能耗测量；没有真机测量，不能声称零开销、60fps恒定或功耗验收。

验证由主Agent另行记录。测试使用合成音量/PCM和指定Simulator，非真人录音。此次不上传TestFlight、不安装真机、不提交或推送。请仅输出与本次改动及上述要求相关、可定位且有触发条件的发现；区分已确认缺陷和需要运行证据的风险。没有运行证据不得猜测实际帧率或耗电结果。
