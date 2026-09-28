import XCTest
import AVFoundation
import Speech
@testable import Minis

final class VoiceStreamingAudioPipeTests: XCTestCase {
    private func audio(seconds: Double = 1) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let count = AVAudioFrameCount(seconds * 16_000)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count)!
        buffer.frameLength = count
        buffer.floatChannelData![0].initialize(repeating: 0, count: Int(count))
        return buffer
    }

    func testFreshPipeAcceptsAudioAndStopsAtExplicitEnd() {
        let pipe = SystemVoiceAudioInputPipe()
        XCTAssertEqual(pipe.start(SFSpeechAudioBufferRecognitionRequest(), segmentID: 0), .started)
        guard case .accepted = pipe.append(audio()) else { return XCTFail("首个请求必须接收音频") }
        XCTAssertEqual(pipe.finishInput(), 0)
        guard case .ignored = pipe.append(audio()) else { return XCTFail("停止后不能继续送音频") }
        guard case .expectedFinish = pipe.recognitionFinished(segmentID: 0) else { return XCTFail("应完成主动停止") }
        XCTAssertFalse(pipe.hasQueuedAudio)
        pipe.close()
        XCTAssertEqual(pipe.start(SFSpeechAudioBufferRecognitionRequest(), segmentID: 1), .closed)
    }

    func testRolloverKeepsAudioCapturedWhileAwaitingFinal() {
        let pipe = SystemVoiceAudioInputPipe()
        _ = pipe.start(SFSpeechAudioBufferRecognitionRequest(), segmentID: 0)
        let buffer = audio()
        for _ in 0..<44 { _ = pipe.append(buffer) }
        guard case .rolloverStarted(0) = pipe.append(buffer) else { return XCTFail("长请求应轮换") }
        _ = pipe.append(buffer)
        XCTAssertTrue(pipe.hasQueuedAudio)
        _ = pipe.finishInput()
        guard case .expectedRollover = pipe.recognitionFinished(segmentID: 0) else { return XCTFail("旧请求应完成") }
        XCTAssertEqual(pipe.start(SFSpeechAudioBufferRecognitionRequest(), segmentID: 1), .startedAndFinished)
        XCTAssertFalse(pipe.hasQueuedAudio)
        guard case .expectedFinish = pipe.recognitionFinished(segmentID: 1) else { return XCTFail("停止期间仍需排空尾音频") }
        pipe.close()
    }

    func testNaturalFinalReplaysOnlyUnrecognizedTail() {
        let pipe = SystemVoiceAudioInputPipe()
        _ = pipe.start(SFSpeechAudioBufferRecognitionRequest(), segmentID: 0)
        _ = pipe.append(audio())
        _ = pipe.append(audio())
        guard case .replayedTail = pipe.recognitionFinished(segmentID: 0, recognizedAudioEnd: 1.5) else {
            return XCTFail("自然终稿之后的半秒音频应交接")
        }
        XCTAssertTrue(pipe.hasQueuedAudio)
        XCTAssertEqual(pipe.start(SFSpeechAudioBufferRecognitionRequest(), segmentID: 1), .started)
        // 第二次自然终稿发生在重放音频内部，也必须保留剩下的 0.25 秒。
        guard case .replayedTail = pipe.recognitionFinished(segmentID: 1, recognizedAudioEnd: 0.25) else {
            return XCTFail("交接音频也必须进入新请求的时间线")
        }
        XCTAssertTrue(pipe.hasQueuedAudio)
        pipe.close()
    }

    func testUnsafeNaturalBoundaryFailsInsteadOfDroppingAudio() {
        let pipe = SystemVoiceAudioInputPipe()
        _ = pipe.start(SFSpeechAudioBufferRecognitionRequest(), segmentID: 0)
        for _ in 0..<12 { _ = pipe.append(audio()) }
        guard case .unexpectedNaturalEnd = pipe.recognitionFinished(segmentID: 0, recognizedAudioEnd: 1) else {
            return XCTFail("已超出保留范围的边界不能伪装为安全交接")
        }
        XCTAssertEqual(pipe.start(SFSpeechAudioBufferRecognitionRequest(), segmentID: 1), .closed)
    }

    func testNoSpeechCannotConvertDisplayedPartialIntoSuccessfulEmptyFinal() {
        let pipe = SystemVoiceAudioInputPipe()
        _ = pipe.start(SFSpeechAudioBufferRecognitionRequest(), segmentID: 0)
        _ = pipe.append(audio())
        pipe.noteRecognizedText(segmentID: 0)
        _ = pipe.finishInput()
        guard case .failure = pipe.recognitionFailed(segmentID: 0, isNoSpeech: true, hasRecognizedText: true) else {
            return XCTFail("显示过的文字必须保留为未确认，不能成功清空")
        }
    }

    func testErrorAfterFinalCannotClosePendingNextSegment() {
        let pipe = SystemVoiceAudioInputPipe()
        _ = pipe.start(SFSpeechAudioBufferRecognitionRequest(), segmentID: 0)
        _ = pipe.append(audio())
        _ = pipe.recognitionFinished(segmentID: 0, recognizedAudioEnd: 0.5)
        guard case .stale = pipe.recognitionFailed(segmentID: 0, isNoSpeech: false, hasRecognizedText: false) else {
            return XCTFail("已终稿的请求不能用迟到错误关闭音频交接")
        }
        XCTAssertTrue(pipe.hasQueuedAudio)
        XCTAssertEqual(pipe.start(SFSpeechAudioBufferRecognitionRequest(), segmentID: 1), .started)
        pipe.close()
    }

    func testSubsampleTailDoesNotEndRecording() {
        let pipe = SystemVoiceAudioInputPipe()
        _ = pipe.start(SFSpeechAudioBufferRecognitionRequest(), segmentID: 0)
        _ = pipe.append(audio())
        _ = pipe.append(audio())
        guard case .replayedTail = pipe.recognitionFinished(segmentID: 0, recognizedAudioEnd: 2 - 1e-9) else {
            return XCTFail("不足一个采样点的空尾部不能被当成边界丢失")
        }
        XCTAssertFalse(pipe.hasQueuedAudio)
        XCTAssertEqual(pipe.start(SFSpeechAudioBufferRecognitionRequest(), segmentID: 1), .started)
        pipe.close()
    }
}
