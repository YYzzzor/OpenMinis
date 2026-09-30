---
description: MinisX iOS 聊天语音输入的权限、采集、流式或分段识别、草稿编辑、停止发送、失败恢复和资源边界。
---

# MinisX iOS 语音输入生命周期

导航：[Spec 索引](index.md)；语音 Provider 的通用实例与模型组规则见 [iOS Provider 与模型路由](ios-provider-model-routing.md)；命令行 `apple-speech` 能力只在 [iOS 设备能力](ios-device-data-capabilities.md)中列举，不等同于本文聊天输入流程。

状态：现行交互约定与 2026-09-29 当前实现并列记录。主要证据为 [VoiceInputPanel.swift](../../src/ios/Views/Chat/Voice/VoiceInputPanel.swift)、[InlineVoiceInputView.swift](../../src/ios/Views/Chat/Voice/InlineVoiceInputView.swift)、[VoiceComposerPanel.swift](../../src/ios/Views/Chat/Voice/VoiceComposerPanel.swift)、[VoiceActivityDetector.swift](../../src/ios/Providers/Voice/VoiceActivityDetector.swift)、[VoiceInputModels.swift](../../src/ios/Providers/Voice/VoiceInputModels.swift)、[VoiceProviderResolver.swift](../../src/ios/Providers/Voice/VoiceProviderResolver.swift) 和 [VoiceComposerLifecycleTests.swift](../../src/ios/MinisTests/VoiceComposerLifecycleTests.swift)。本轮未运行测试或真机录音。

## 用户模型：语音生成可编辑草稿

语音输入是 composer 的一种输入方式，不是“录完立即发送”。识别文字持续进入同一可编辑草稿；用户可以停止、等待识别收尾、用键盘修改、继续录音，最后由普通发送动作提交。发送前不得隐藏或绕过当前草稿。

面板应区分：等待、正在开启麦克风、采集中、识别/收尾中、可编辑结果和失败。`isBusyForComposer` 是编辑和发送门禁：权限请求、最终音频派发、未完成识别、重试或流式 finish 尚未结束时，不允许提前发送一个不完整草稿。

## 权限与启动

录音至少需要麦克风权限；使用系统 ASR 时还需要 Speech Recognition 权限。显式点击麦克风可以触发授权请求；基于上次输入模式的自动进入只能在权限已经授予时启动，不能在冷启动制造权限弹窗风暴。

权限拒绝、没有可用 ASR Provider 和音频引擎启动失败是不同错误，必须给出可操作提示。第三方 ASR 缺凭证不能伪装成“网络错误”；系统 ASR 的在线/离线选择仍受语言、设备和系统可用性限制。

重复点击不能启动第二套 capture。离开聊天或切换键盘时，要使尚未完成的启动请求失效，停止采集，并保留已经显示的草稿。

## 单一音频采集所有者

一次 composer 录音只有一个 `VoiceActivityDetector`/audio engine 负责麦克风采集。流式 ASR session 接收这个 capture 的 PCM；不得另起一套麦克风引擎同时做 VAD 或上传，否则会产生 AVAudioSession 争用、重复音频和错序回调。

语音采集与回复朗读互斥：开始采集时停止或抑制 TTS，结束后才允许恢复。App 内其他音频子系统通过 `AudioSessionCoordinator` 声明意图并按优先级切换，不能各自永久占用 session。

当前资源护栏是实现现状：无语音约 30 秒自动停止；进入后台约 15 秒后停止/收尾；单次连续 capture 总上限约 5 分钟。调整这些数值需要同步 UI 文案、生命周期测试和真机资源验证。

## Provider 解析与 failover

每次新 capture 开始前重新解析 ASR 选择。第三方候选必须支持 audio input/ASR，所属实例启用且本设备有可用凭证。现行要求是区分显式 System、第三方配置不可用和系统识别不可用；不能把配置错误静默包装成已成功的系统识别。

已核实的当前偏差：[VoiceProviderResolver.swift](../../src/ios/Providers/Voice/VoiceProviderResolver.swift) 对显式 System 和第三方组不存在、成员全部过滤都可能返回空候选链；[VoiceInputPanel.swift](../../src/ios/Views/Chat/Voice/VoiceInputPanel.swift) 在无 active candidate 时选择 System，空链转写也直接调用系统引擎。当前结果未保留这两类空链的不同原因，因此不能宣称所有第三方配置错误均先得到独立提示。系统回退仍受 Speech 权限、语言和在线/离线可用性限制，走到该路径不证明识别成功。

第三方配置失效时应报错、提示后回退还是自动回退，仍待维护者确认；本段记录现状，不把自动回退升级为最终交互约定。

fallback 组按成员顺序，load-balance 组在每次 capture 重新生成 seed 并旋转起始成员。一个片段内最多完整尝试候选链一次；某成员成功后，同一 capture 的后续片段优先从该 sticky 成员开始。只有当前成员失败才前进，不能并发向多个 ASR Provider 上传同一音频。

## 流式与分段识别

支持 `VoiceStreamingCapable` 的 Provider 可以产生 partial、final、finished 和 failed 事件；其他 Provider 在 VAD 停顿或用户停止后发送完整 WAV 片段。

- partial 是当前片段的完整修订稿，可能变短或清空，必须整体替换，不能只做字符串追加。
- final 固化当前 segment 并推进 segment id；空 final 也必须推进，避免后续片段永久阻塞。
- 分段请求可能乱序完成，正文按预留 sequence 顺序释放；早片段失败应以空结果解锁后续成功文字。
- 每轮流式录音使用 generation。键盘编辑、重新录音、发送、离场或 reset 会让旧 generation 失效；迟到回调不能覆盖新草稿。

流式失败时已显示的 partial 保留并标为未确认，用户可以编辑或重试；空结果给出“未识别到语音”，原有草稿不应消失。

## 停止、编辑、继续与发送

用户停止时先停止 capture，再 flush 尾部音频并等待所有已排队识别结束；收尾完成前保持 busy。VAD 从未判定语音但已有足够原始音频时，当前实现会尝试 raw fallback，避免“说了但没触发 VAD”导致完全丢失。

切到键盘时先完成或取消当前 capture，直接读取 ViewModel 最终 transcript 交给文本 composer，不依赖视图卸载时序。用户手工编辑期间暂停录音结果写入；若批处理结果迟到且可能覆盖编辑，丢弃并明确提示，而不是静默改回机器文本。

继续录音以当前编辑后的草稿为 base，新识别片段追加其后。发送动作必须先让旧 generation 失效并清空/重置语音状态，发送后迟到的 final 不能重新填回 composer。

## 错误和重试

至少区分并持久显示最近一次失败：录音过短、没有识别到语音、编辑期间结果被丢弃、麦克风拒绝、Speech 权限拒绝、无可用 Provider、转录失败、启动失败。Toast 可以短暂提示，但面板需保留完整原因和手动重试入口。

自动重试只能重用明确保存的片段音频，并受 generation/取消状态约束。退出、发送或开始新录音后，旧重试不得继续修改 transcript。错误日志不得记录凭证；调试保存原始音频属于高敏感诊断能力，必须遵守调试构建、保留期限和用户知情边界。

## 场景与验收

### 场景 A：说话、停止、编辑、发送

停止后先显示收尾状态；最终片段到齐才开放编辑/发送。用户修改文字后发送，消息内容等于编辑稿；任何迟到识别回调都不能改写已发送内容或空 composer。

### 场景 B：连续两个分段乱序返回

第二段先完成时先缓存，第一段完成或失败后再按录音顺序释放；最终 transcript 不倒序，也不会因第一段失败丢掉第二段。

### 场景 C：流式中间结果反复修订

同一 segment 的较短 partial 替换较长 partial；final 固化一次；相同或更老 segment 的迟到 partial/final 被忽略。用户始终看到 base 草稿加已定稿段和当前段。

### 场景 D：切换键盘或离开页面

待启动权限任务和 capture 被取消，草稿保留；旧音频/识别回调失效；没有后台重新开麦或页面消失后覆盖草稿。

### 场景 E：首选云 ASR 不可用

候选链只按顺序尝试可用成员，同一片段不并发上传；成功成员成为本次 capture 的 sticky 起点。全部失败时显示每类可理解原因并保留草稿/可重试音频。

还应区分“有候选但逐个失败”和“过滤后为空”。空链场景按[Provider 解析与 failover](#provider-解析与-failover)记录当前 System 路径及系统权限/不可用结果，不能把默认回退当成用户已选 System，或提前判定成功；未决提示策略另行确认。

## 待验证与待确认

- 待验证：iOS 26 真机的首次权限、系统在线/离线 ASR、耳机/电话中断、后台 15 秒收尾、5 分钟上限、长录音内存和各云 Provider failover。
- 待验证：现有 `VoiceComposerLifecycleTests` 只提供静态测试证据；本轮没有运行。波形视觉参数和实时文字体验也不能由这些测试替代。
- 待确认：流式失败后“未确认 partial”发送时是否需要额外确认；当前实现允许用户保留并编辑，但尚无独立产品决定记录。
- 待验证与待确认：第三方配置失效后的空候选链、System 权限拒绝或不可用；最终降级及提示策略见[Provider 解析与 failover](#provider-解析与-failover)，没有因本轮文档修订升级为运行保证。
