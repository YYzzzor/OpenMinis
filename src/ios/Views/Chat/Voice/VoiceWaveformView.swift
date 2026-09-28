import Observation
import QuartzCore
import SwiftUI
import UIKit

enum VoiceWaveformConfiguration {
    static let barCount = 20
    static let idleLevel: Float = 0.04
    static let sensitivity: Float = 0.8
    static let smoothingTimeConstant: TimeInterval = 0.040
    static let settleTolerance: Float = 0.001
    static let barWidth: CGFloat = 3
    static let minimumBarHeight: CGFloat = 3
    static let maximumBarHeightFraction: CGFloat = 0.76
    static let minimumFrameRate: Float = 30
    static let preferredFrameRate: Float = 60
    static let maximumFrameRate: Float = 60
}

/// 保存固定 20 根柱子的原始响度；变更只通知读取该属性的波形叶子视图。
@MainActor
@Observable
final class VoiceWaveformSource {
    @ObservationIgnored
    private var storedLevels = Array(
        repeating: VoiceWaveformConfiguration.idleLevel,
        count: VoiceWaveformConfiguration.barCount
    )

    var levels: [Float] {
        access(keyPath: \.levels)
        return storedLevels
    }

    init(levels: [Float] = Array(
        repeating: VoiceWaveformConfiguration.idleLevel,
        count: VoiceWaveformConfiguration.barCount
    )) {
        update(levels)
    }

    /// 输入固定裁剪或补齐到 20 项；非有限值按 0 处理。
    func update(_ levels: [Float]) {
        var changed = false
        for index in 0..<VoiceWaveformConfiguration.barCount {
            let value = Self.sanitizedLevel(at: index, in: levels)
            if storedLevels[index] != value {
                changed = true
                break
            }
        }
        guard changed else { return }

        withMutation(keyPath: \.levels) {
            for index in 0..<VoiceWaveformConfiguration.barCount {
                storedLevels[index] = Self.sanitizedLevel(at: index, in: levels)
            }
        }
    }

    func reset() {
        guard storedLevels.contains(where: { $0 != VoiceWaveformConfiguration.idleLevel }) else { return }
        withMutation(keyPath: \.levels) {
            for index in 0..<VoiceWaveformConfiguration.barCount {
                storedLevels[index] = VoiceWaveformConfiguration.idleLevel
            }
        }
    }

    private static func sanitizedLevel(at index: Int, in levels: [Float]) -> Float {
        guard index < levels.count else { return VoiceWaveformConfiguration.idleLevel }
        let level = levels[index]
        guard level.isFinite else { return 0 }
        return min(max(level, 0), 1)
    }
}

/// 纯数值的一阶平滑器：固定容量、对称升降、重设目标时保留当前显示值。
struct VoiceWaveformSmoother {
    private(set) var presentationLevels: [Float]
    private(set) var targetLevels: [Float]

    init() {
        let idle = VoiceWaveformConfiguration.idleLevel * VoiceWaveformConfiguration.sensitivity
        presentationLevels = Array(repeating: idle, count: VoiceWaveformConfiguration.barCount)
        targetLevels = Array(repeating: idle, count: VoiceWaveformConfiguration.barCount)
    }

    var isSettled: Bool {
        for index in 0..<VoiceWaveformConfiguration.barCount {
            if abs(targetLevels[index] - presentationLevels[index]) > VoiceWaveformConfiguration.settleTolerance {
                return false
            }
        }
        return true
    }

    /// 更新目标但保留当前位置；减少动态效果时直接显示目标。
    mutating func setTarget(_ levels: [Float], reduceMotion: Bool = false) {
        for index in 0..<VoiceWaveformConfiguration.barCount {
            let rawLevel: Float
            if index < levels.count, levels[index].isFinite {
                rawLevel = min(max(levels[index], 0), 1)
            } else if index < levels.count {
                rawLevel = 0
            } else {
                rawLevel = VoiceWaveformConfiguration.idleLevel
            }

            let target = rawLevel * VoiceWaveformConfiguration.sensitivity
            targetLevels[index] = target
            if reduceMotion {
                presentationLevels[index] = target
            }
        }
    }

    /// 按真实经过时间计算一阶响应，刷新频率改变不会改变跟随速度。
    @discardableResult
    mutating func advance(deltaTime: TimeInterval) -> Bool {
        guard deltaTime.isFinite, deltaTime > 0 else { return isSettled }
        let alpha = Float(1 - exp(-deltaTime / VoiceWaveformConfiguration.smoothingTimeConstant))

        for index in 0..<VoiceWaveformConfiguration.barCount {
            let target = targetLevels[index]
            let current = presentationLevels[index]
            let next = current + (target - current) * alpha
            presentationLevels[index] = abs(target - next) <= VoiceWaveformConfiguration.settleTolerance
                ? target
                : next
        }
        return isSettled
    }
}

@MainActor
struct VoiceWaveformView: View {
    let source: VoiceWaveformSource

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VoiceWaveformRepresentable(
            levels: source.levels,
            sceneIsActive: scenePhase == .active,
            reduceMotion: reduceMotion
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityHidden(true)
    }
}

@MainActor
private struct VoiceWaveformRepresentable: UIViewRepresentable {
    let levels: [Float]
    let sceneIsActive: Bool
    let reduceMotion: Bool

    func makeUIView(context: Context) -> VoiceWaveformDrawingView {
        VoiceWaveformDrawingView()
    }

    func updateUIView(_ view: VoiceWaveformDrawingView, context: Context) {
        view.configure(
            levels: levels,
            sceneIsActive: sceneIsActive,
            reduceMotion: reduceMotion
        )
    }

    static func dismantleUIView(_ view: VoiceWaveformDrawingView, coordinator: ()) {
        view.stopAnimation()
    }
}

@MainActor
final class VoiceWaveformDrawingView: UIView {
    private let bars: [CALayer]
    private var smoother = VoiceWaveformSmoother()
    private var sceneIsActive = false
    private var reduceMotion = false
    private var displayLink: CADisplayLink?
    private var previousTimestamp: CFTimeInterval?
    private lazy var displayLinkTarget = VoiceWaveformWeakDisplayLinkTarget(owner: self)

    var isAnimating: Bool {
        displayLink != nil
    }

    override init(frame: CGRect) {
        var createdBars: [CALayer] = []
        createdBars.reserveCapacity(VoiceWaveformConfiguration.barCount)
        for _ in 0..<VoiceWaveformConfiguration.barCount {
            let bar = CALayer()
            bar.cornerRadius = VoiceWaveformConfiguration.barWidth / 2
            createdBars.append(bar)
        }
        bars = createdBars

        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        for bar in bars {
            layer.addSublayer(bar)
        }
        refreshBarColor()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: VoiceWaveformDrawingView, _: UITraitCollection) in
            view.refreshBarColor()
        }
        renderBars()
    }

    required init?(coder: NSCoder) {
        return nil
    }

    deinit {
        displayLink?.invalidate()
    }

    func configure(levels: [Float], sceneIsActive: Bool, reduceMotion: Bool) {
        // 先把旧目标推进到当前时间，避免把新采样错误套用到此前的时间段。
        let now = CACurrentMediaTime()
        if let previousTimestamp {
            smoother.advance(deltaTime: max(0, now - previousTimestamp))
            self.previousTimestamp = now
        }
        self.sceneIsActive = sceneIsActive
        self.reduceMotion = reduceMotion
        smoother.setTarget(levels, reduceMotion: reduceMotion || !sceneIsActive)
        if sceneIsActive && window != nil { renderBars() }
        updateAnimationState()
    }

    func stopAnimation() {
        displayLink?.invalidate()
        displayLink = nil
        previousTimestamp = nil
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateAnimationState()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        renderBars()
        updateAnimationState()
    }

    fileprivate func displayLinkDidFire(_ link: CADisplayLink) {
        let timestamp = CACurrentMediaTime()
        let previous = previousTimestamp ?? timestamp
        previousTimestamp = timestamp

        let settled = smoother.advance(deltaTime: max(0, timestamp - previous))
        renderBars()
        if settled {
            stopAnimation()
        }
    }

    private func updateAnimationState() {
        guard window != nil,
              !bounds.isEmpty,
              sceneIsActive,
              !reduceMotion,
              !smoother.isSettled else {
            stopAnimation()
            return
        }
        guard displayLink == nil else { return }

        previousTimestamp = CACurrentMediaTime()
        let link = CADisplayLink(target: displayLinkTarget, selector: #selector(VoiceWaveformWeakDisplayLinkTarget.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(
            minimum: VoiceWaveformConfiguration.minimumFrameRate,
            maximum: VoiceWaveformConfiguration.maximumFrameRate,
            preferred: VoiceWaveformConfiguration.preferredFrameRate
        )
        displayLink = link
        link.add(to: .main, forMode: .common)
    }

    private func refreshBarColor() {
        let color = UIColor.label.resolvedColor(with: traitCollection).cgColor
        for bar in bars {
            bar.backgroundColor = color
        }
    }

    private func renderBars() {
        let width = bounds.width
        let height = bounds.height
        let slotWidth = width / CGFloat(VoiceWaveformConfiguration.barCount)
        let barWidth = min(VoiceWaveformConfiguration.barWidth, slotWidth)
        let maximumHeight = height * VoiceWaveformConfiguration.maximumBarHeightFraction

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for index in 0..<VoiceWaveformConfiguration.barCount {
            let level = CGFloat(smoother.presentationLevels[index])
            let barHeight = max(
                VoiceWaveformConfiguration.minimumBarHeight,
                min(maximumHeight, level * maximumHeight)
            )
            let centerX = (CGFloat(index) + 0.5) * slotWidth
            bars[index].frame = CGRect(
                x: centerX - barWidth / 2,
                y: (height - barHeight) / 2,
                width: barWidth,
                height: barHeight
            )
        }
        CATransaction.commit()
    }
}

@MainActor
private final class VoiceWaveformWeakDisplayLinkTarget: NSObject {
    weak var owner: VoiceWaveformDrawingView?

    init(owner: VoiceWaveformDrawingView) {
        self.owner = owner
    }

    @objc func tick(_ link: CADisplayLink) {
        guard let owner else {
            link.invalidate()
            return
        }
        owner.displayLinkDidFire(link)
    }
}
