import XCTest
import Combine
import UIKit
import SwiftUI
@testable import Minis

final class VoiceWaveformTests: XCTestCase {
    @MainActor
    func testWaveformChangesDoNotBroadcastChatModelChanges() {
        let model = VoiceInputViewModel()
        var notifications = 0
        let subscription = model.objectWillChange.sink { notifications += 1 }
        for step in 0..<120 {
            model.waveformSource.update(Array(repeating: Float(step % 20) / 20, count: 20))
        }
        XCTAssertEqual(notifications, 0, "波形输入不得让观察语音模型的聊天页刷新")
        withExtendedLifetime(subscription) {}
    }

    @MainActor
    func testPCMLevelsKeepExistingPerceptualGainWithoutTemporaryChunks() {
        let samples = Array(repeating: Float(0.01), count: 512)
        let data = samples.withUnsafeBytes { Data($0) }
        let levels = VoiceInputViewModel.computeWaveformLevels(from: data)
        XCTAssertEqual(levels.count, 20)
        let expected: Float = sqrt(0.14) * 0.95
        for level in levels { XCTAssertEqual(level, expected, accuracy: 0.00001) }
    }

    @MainActor
    func testEmptyAndMalformedPCMRemainBoundedAndFinite() {
        let samples: [Float] = [.nan, .infinity, -.infinity, 0]
        let invalid = samples.withUnsafeBytes { Data($0) }
        for input in [Data(), Data([0, 1, 2]), invalid] {
            let levels = VoiceInputViewModel.computeWaveformLevels(from: input)
            XCTAssertEqual(levels.count, 20)
            XCTAssertTrue(levels.allSatisfy { $0.isFinite && $0 >= 0.04 && $0 <= 1 })
        }
    }

    func testFortyMillisecondFollowMatchesSelectedDemoAndRetargetsContinuously() {
        var filter = VoiceWaveformSmoother()
        let initial = filter.presentationLevels[0]
        filter.setTarget(Array(repeating: 1, count: 20), reduceMotion: false)
        XCTAssertEqual(filter.targetLevels[0], 0.8, accuracy: 0.00001)
        _ = filter.advance(deltaTime: 0.04)
        let expected = initial + (0.8 - initial) * Float(1 - exp(-1.0))
        XCTAssertEqual(filter.presentationLevels[0], expected, accuracy: 0.00001)
        let beforeRetarget = filter.presentationLevels
        filter.setTarget(Array(repeating: 0, count: 20), reduceMotion: false)
        XCTAssertEqual(filter.presentationLevels, beforeRetarget, "新目标不能重置当前显示位置")
        _ = filter.advance(deltaTime: 0.04)
        XCTAssertLessThan(filter.presentationLevels[0], beforeRetarget[0])
        XCTAssertGreaterThanOrEqual(filter.presentationLevels[0], filter.targetLevels[0])
    }

    func testFollowDoesNotDependOnRefreshCadenceAndEventuallySleeps() {
        var sixty = VoiceWaveformSmoother()
        var thirty = VoiceWaveformSmoother()
        sixty.setTarget(Array(repeating: 1, count: 20), reduceMotion: false)
        thirty.setTarget(Array(repeating: 1, count: 20), reduceMotion: false)
        for _ in 0..<6 { _ = sixty.advance(deltaTime: 1.0 / 60) }
        for _ in 0..<3 { _ = thirty.advance(deltaTime: 1.0 / 30) }
        XCTAssertEqual(sixty.presentationLevels[0], thirty.presentationLevels[0], accuracy: 0.00001)
        for _ in 0..<60 { _ = sixty.advance(deltaTime: 1.0 / 60) }
        XCTAssertTrue(sixty.isSettled)
        XCTAssertEqual(sixty.presentationLevels, sixty.targetLevels)
    }

    @MainActor
    func testWindowSceneAndReduceMotionStopDisplayLink() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 360, height: 480))
        let controller = UIViewController()
        window.rootViewController = controller
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        let view = VoiceWaveformDrawingView(frame: CGRect(x: 12, y: 12, width: 300, height: 44))
        controller.view.addSubview(view)
        view.configure(levels: Array(repeating: 1, count: 20), sceneIsActive: true, reduceMotion: false)
        XCTAssertTrue(view.isAnimating)
        view.configure(levels: Array(repeating: 1, count: 20), sceneIsActive: false, reduceMotion: false)
        XCTAssertFalse(view.isAnimating)
        view.configure(levels: Array(repeating: 0.1, count: 20), sceneIsActive: true, reduceMotion: true)
        XCTAssertFalse(view.isAnimating)
        view.configure(levels: Array(repeating: 1, count: 20), sceneIsActive: true, reduceMotion: false)
        XCTAssertTrue(view.isAnimating)
        view.removeFromSuperview()
        XCTAssertFalse(view.isAnimating)
    }


    @MainActor
    func testNativeLeafReceivesSourceAndStopsAfterSettling() async throws {
        let source = VoiceWaveformSource()
        let controller = UIHostingController(rootView: VoiceWaveformView(source: source)
            .frame(width: 300, height: 44).environment(\.scenePhase, .active))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 360, height: 480))
        window.rootViewController = controller
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        func findDrawingView(_ view: UIView) -> VoiceWaveformDrawingView? {
            if let drawing = view as? VoiceWaveformDrawingView { return drawing }
            for child in view.subviews {
                if let found = findDrawingView(child) { return found }
            }
            return nil
        }
        let drawing = try XCTUnwrap(findDrawingView(controller.view))
        XCTAssertFalse(drawing.isAnimating)
        source.update(Array(repeating: 1, count: 20))
        // App 首次启动可推迟 SwiftUI 交付更新；等待真实目标与停止状态，
        // 而不是把宿主启动延迟误算作波形的 40ms 时间常数。
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            let height = drawing.layer.sublayers?.first?.bounds.height ?? 0
            if height > 19 && !drawing.isAnimating { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let bars = try XCTUnwrap(drawing.layer.sublayers)
        XCTAssertEqual(bars.count, 20)
        XCTAssertEqual(bars[0].bounds.height, 44 * 0.76 * 0.8, accuracy: 0.01, "独立源变更必须真正到达可见波形")
        XCTAssertEqual(bars[0].position.y, drawing.bounds.midY, accuracy: 0.01)
        XCTAssertFalse(drawing.isAnimating, "稳定输入收敛后不应继续逐帧回调")
        let attachment = XCTAttachment(image: UIGraphicsImageRenderer(bounds: drawing.bounds).image { context in
            drawing.layer.render(in: context.cgContext)
        })
        attachment.name = "B waveform native settled state"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

}
