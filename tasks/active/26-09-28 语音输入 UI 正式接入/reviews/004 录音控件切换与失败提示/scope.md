# 录音控件切换与失败提示：局部复审

用户反馈：点击麦克风时录音波形点与“语音设置”文字重叠；语音失败胶囊持续过久。本轮已授权修复，保留已认可的布局与外层背景伸缩。

仅审查两处增量：
1. VoiceComposerPanel.body 删除整个面板的 .animation(..., value: phase)，改成位于 ComposerSurface 前的 .transaction(value: phase) { animation=nil; disablesAnimations=true }。待机、录音、转录内容原本条件分支不变；录音 Canvas 和停止动作不变；无状态/数据逻辑改动。此前文字/语音模式的 ComposerContentTransition 事务不变。
2. VoiceInputViewModel.report 仅将 MinisToast.show 的duration从2.2改成1.0，并更新旧compact面板注释。lastFailure、silent、日志、重试、录音启动等均不变。MinisToast 的实现不在本快照，主Agent已本地读取确认该参数是淡出等待时间、既有淡出0.3秒，未改全局行为。

只读这两处及必要的 InlineVoiceInputView phase/statusText 衔接，不审计整个main以来的语音改造。base patch包含之前任务增量，不能全部当成本轮新代码。之前003审核关注点（nil animation回调、底部逐步露出、Canvas不是键盘验收、停止生成按钮样式）有独立处理记录，本轮不改相关路径。

主Agent已核对：正式Debug Simulator构建通过；diff --check；同一iPhone18Pro/iOS27模拟器实际入口+待机麦克风两次点击的录像，逐帧可见isStarting期间recording-phase仅有波形与停止键，旧设置/麦克风退出，失败回idle直接替换。明显可见胶囊约1.167与1.133秒（像素阈值估计），错误行保留。
边界：麦克风暂时拒绝并已恢复授权，不采集音频，未声称持续实际录音、全部转录状态、真实服务商解析失败均已运行测试。没有添加实现镜像单元测试。录像/用户截图不外发，你只能静态核对，不声称亲自看过录像。

本轮仅发送先前用户已明确允许发送到DeepSeek的五个文件中的三个：VoiceComposerPanel、VoiceInputPanel、InlineVoiceInputView，加此审核说明。目的地仍DeepSeek/deepseek-flash，无凭据/会话/截图或无关资料。
