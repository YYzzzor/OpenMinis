import SwiftUI

/// 正式输入面板与 Canvas 共用的布局参数；尺寸单位为 pt。
enum VoiceComposerStyle {
    static let textSize: CGFloat = 17
    /// 短句区域先保留约四行，内容较长时增高并在上限内滚动。
    static let textMinHeight: CGFloat = 104
    static let textMaxHeight: CGFloat = 160
    static let contentPadding: CGFloat = 12
    static let cornerRadius: CGFloat = 24
    /// 点击区域与图标尺寸分开，保证小图标也能容易点中。
    static let buttonSize: CGFloat = 44
    static let iconSize: CGFloat = 18
    static let controlSpacing: CGFloat = 14
    static let sectionSpacing: CGFloat = 8
    static let statusMinHeight: CGFloat = 18
    /// 标题与正文的固定负间距；正文 8pt 顶部内边距使首行字形仍落在按钮触摸区下方。
    static let headerBodySpacing: CGFloat = -7.5
    /// 正文行距基准值，随后按正文 Dynamic Type 比例缩放。
    static let transcriptLineSpacing: CGFloat = 4
    static let pageInset: CGFloat = 12
    static let transitionDuration: Double = 0.32
    static let slowMotionMultiplier: Double = 3
}

/// 模式切换只让外层背景伸缩，内容在同一帧替换，避免 UIKit 旧文字与新面板交叠。
/// 只覆盖模式改变的事务；录音状态、转录文字等后续更新保留各自的动画。
struct ComposerContentTransition: ViewModifier {
    let isVoice: Bool

    func body(content: Content) -> some View {
        content
            .transaction(value: isVoice) { transaction in
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
    }
}

enum VoiceComposerPhase: Equatable {
    case idle, recording, transcribing
}

/// 只负责展示；真实录音、发送和设置由调用方提供，预览不需要启动服务。
struct VoiceComposerPanel<SendControl: View>: View {
    let transcript: String
    let phase: VoiceComposerPhase
    let title: String
    let statusText: String
    let languageLabel: String
    let waveformSource: VoiceWaveformSource
    var drawsSurface = true
    var canRecord = true
    var onRetry: (() -> Void)? = nil
    let onStop: () -> Void
    let onRecord: () -> Void
    let onKeyboard: () -> Void
    let onSettings: () -> Void
    @ViewBuilder var sendControl: () -> SendControl

    @State private var measuredTextHeight: CGFloat = 0
    @ScaledMetric(relativeTo: .body) private var textSize = VoiceComposerStyle.textSize
    @ScaledMetric(relativeTo: .body) private var textLineSpacing = VoiceComposerStyle.transcriptLineSpacing
    @ScaledMetric(relativeTo: .body) private var textMinHeight = VoiceComposerStyle.textMinHeight
    @ScaledMetric(relativeTo: .body) private var textMaxHeight = VoiceComposerStyle.textMaxHeight
    @ScaledMetric(relativeTo: .caption) private var statusMinHeight = VoiceComposerStyle.statusMinHeight

    var body: some View {
        VStack(spacing: VoiceComposerStyle.sectionSpacing) {
            VStack(spacing: VoiceComposerStyle.headerBodySpacing) {
                HStack {
                    Text(title).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(action: onKeyboard) {
                        Label("键盘输入", systemImage: "keyboard")
                            .font(.caption)
                            .frame(minHeight: VoiceComposerStyle.buttonSize)
                    }
                    .buttonStyle(.plain)
                    .disabled(phase == .transcribing)
                    .accessibilityHint("保留文字；录音中切换会先结束录音并完成转录")
                    .accessibilityIdentifier("voice.keyboard")
                }
                // 负间距会覆盖按钮触摸区域的下缘，抬高标题层级以保留键盘按钮命中。
                .zIndex(1)

                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(transcript.isEmpty ? "识别文字会显示在这里" : transcript)
                                .font(.system(size: textSize))
                                .lineSpacing(textLineSpacing)
                                .foregroundStyle(transcript.isEmpty ? .tertiary : .primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 8)
                                .padding(.horizontal, 5)
                                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                                    measuredTextHeight = $0
                                }
                            Color.clear.frame(height: 1).id("voiceTextTail")
                        }
                    }
                    .frame(height: min(max(textMinHeight, measuredTextHeight), textMaxHeight))
                    .contentShape(Rectangle())
                    .onTapGesture { if phase == .idle { onKeyboard() } }
                    .accessibilityLabel(transcript.isEmpty ? "语音草稿为空" : transcript)
                    .accessibilityAction(named: Text("编辑文字")) {
                        if phase == .idle { onKeyboard() }
                    }
                    .onChange(of: transcript) { _, _ in proxy.scrollTo("voiceTextTail", anchor: .bottom) }
                }
            }

            if phase == .recording {
                HStack(spacing: VoiceComposerStyle.controlSpacing) {
                    waveform
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel("录音波形")
                    circleButton("结束录音", symbol: "stop.fill", action: onStop)
                        .accessibilityHint("结束录音后检查文字，不会发送")
                        .accessibilityIdentifier("voice.stop")
                }
            } else if phase == .transcribing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在转录…").font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(height: VoiceComposerStyle.buttonSize)
            } else {
                HStack(spacing: 8) {
                    Button(action: onSettings) {
                        ViewThatFits(in: .horizontal) {
                            Label("语音设置 · \(languageLabel)", systemImage: "slider.horizontal.3")
                            Text("语音设置")
                        }
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(minHeight: VoiceComposerStyle.buttonSize)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("voice.settings")
                    Spacer(minLength: 0)
                    circleButton("继续说话", symbol: "mic", action: onRecord)
                        .disabled(!canRecord)
                        .accessibilityIdentifier("voice.record")
                    sendControl()
                        .frame(minWidth: VoiceComposerStyle.buttonSize, minHeight: VoiceComposerStyle.buttonSize)
                }
            }

            // 同一提示行始终位于面板内，停止录音只改变文案。
            HStack(spacing: 6) {
                Text(statusText)
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if let onRetry {
                    Button("重试", action: onRetry).font(.caption)
                }
            }
            .frame(maxWidth: .infinity, minHeight: statusMinHeight)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("voice.status")
        }
        .padding(VoiceComposerStyle.contentPadding)
        // 待机设置行、录音波形和转录进度在同一帧替换，不能交叉淡入淡出。
        // 只限制内容事务，外层输入容器仍保留模式切换时的伸缩动画。
        .transaction(value: phase) { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
        .modifier(ComposerSurface(voiceStyle: true, isEnabled: drawsSurface))
    }

    private var waveform: some View {
        VoiceWaveformView(source: waveformSource)
        .frame(height: VoiceComposerStyle.buttonSize)
    }

    private func circleButton(_ label: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: VoiceComposerStyle.iconSize, weight: .medium))
                .frame(width: VoiceComposerStyle.buttonSize, height: VoiceComposerStyle.buttonSize)
                .foregroundStyle(.primary)
                .background(.primary.opacity(0.06), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// 语音检查态的发送外观；按钮动作仍由聊天页决定发送还是排队。
struct VoiceComposerSendLabel: View {
    var isEnabled = true

    var body: some View {
        Image(systemName: "arrow.up")
            .font(.system(size: VoiceComposerStyle.iconSize, weight: .medium))
            .frame(width: VoiceComposerStyle.buttonSize, height: VoiceComposerStyle.buttonSize)
            .foregroundStyle(Color(uiColor: .systemBackground))
            .background(isEnabled ? Color.primary : Color.secondary.opacity(0.35), in: Circle())
            .contentShape(Circle())
    }
}
