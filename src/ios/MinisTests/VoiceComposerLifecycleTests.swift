import XCTest
@testable import Minis

final class VoiceComposerLifecycleTests: XCTestCase {
    func testLaterSegmentWaitsForEarlierRecognition() {
        var buffer = VoiceTranscriptOrderBuffer()
        let first = buffer.reserve()
        let second = buffer.reserve()
        XCTAssertEqual(buffer.resolve(second, text: "今天天气怎么样"), [])
        XCTAssertTrue(buffer.hasPending)
        XCTAssertEqual(buffer.resolve(first, text: "你好"), ["你好", "今天天气怎么样"])
        XCTAssertFalse(buffer.hasPending)
        XCTAssertEqual(buffer.resolve(first, text: "重复回调"), [])
    }

    func testFailedSegmentDoesNotBlockLaterText() {
        var buffer = VoiceTranscriptOrderBuffer()
        let failed = buffer.reserve()
        let next = buffer.reserve()
        XCTAssertEqual(buffer.resolve(next, text: "保留这一句"), [])
        XCTAssertEqual(buffer.resolve(failed, text: ""), ["保留这一句"])
        XCTAssertFalse(buffer.hasPending)
    }

    func testResetDropsBufferedText() {
        var buffer = VoiceTranscriptOrderBuffer()
        _ = buffer.reserve()
        let later = buffer.reserve()
        _ = buffer.resolve(later, text: "旧草稿")
        buffer.reset()
        XCTAssertFalse(buffer.hasPending)
        let fresh = buffer.reserve()
        XCTAssertEqual(buffer.resolve(fresh, text: "新草稿"), ["新草稿"])
    }

    @MainActor
    func testKeyboardHandoffKeepsDraftAndIgnoresLateAudio() {
        let vm = VoiceInputViewModel()
        vm.setTranscript("你好，今天天气怎么样")
        vm.reset(clearTranscript: false)
        vm.voiceActivityDidEnd(audioData: Data([1, 2, 3]), reason: .manualFlush)
        XCTAssertEqual(vm.transcript, "你好，今天天气怎么样")
        XCTAssertFalse(vm.isBusyForComposer)
        XCTAssertFalse(vm.isCaptureActive)
        vm.clearAndRearm()
        XCTAssertEqual(vm.transcript, "")
        XCTAssertFalse(vm.isBusyForComposer)
    }

    @MainActor
    func testLeavingBeforeStartTaskRunsInvalidatesStart() async {
        let vm = VoiceInputViewModel()
        vm.setTranscript("已有文字")
        vm.startFromComposer()
        XCTAssertTrue(vm.isStarting)
        XCTAssertTrue(vm.isBusyForComposer)
        vm.reset(clearTranscript: false)
        await Task.yield()
        XCTAssertFalse(vm.isStarting)
        XCTAssertFalse(vm.isCaptureActive)
        XCTAssertFalse(vm.isBusyForComposer)
        XCTAssertEqual(vm.transcript, "已有文字")
    }

    func testRealtimeRevisionsReplaceWholeCurrentPhrase() {
        var draft = VoiceStreamingDraft(base: "你好")
        draft.update(segmentID: 0, text: "今天天气怎么样呀", isFinal: false)
        XCTAssertEqual(draft.text, "你好 今天天气怎么样呀")
        draft.update(segmentID: 0, text: "今天怎么样", isFinal: false)
        XCTAssertEqual(draft.text, "你好 今天怎么样")
        draft.update(segmentID: 0, text: "", isFinal: false)
        XCTAssertEqual(draft.text, "你好")
        draft.update(segmentID: 0, text: "今天天气怎么样？", isFinal: true)
        draft.update(segmentID: 0, text: "重复终稿", isFinal: true)
        draft.update(segmentID: 0, text: "迟到中间结果", isFinal: false)
        draft.update(segmentID: 1, text: "明天呢", isFinal: false)
        XCTAssertEqual(draft.text, "你好 今天天气怎么样？ 明天呢")
    }

    @MainActor
    func testRealtimeTailFinalAndLateCallbacksAfterFinish() {
        let vm = VoiceInputViewModel()
        vm.setTranscript("原草稿")
        let generation = vm.beginStreamingDraft()
        vm.receiveStreamingEvent(.partial(segmentID: 0, text: "没有说完"), generation: generation)
        vm.receiveStreamingEvent(.final(segmentID: 0, text: "完整尾句。"), generation: generation)
        vm.receiveStreamingEvent(.finished, generation: generation)
        vm.receiveStreamingEvent(.partial(segmentID: 1, text: "迟到"), generation: generation)
        XCTAssertEqual(vm.transcript, "原草稿 完整尾句。")
        XCTAssertFalse(vm.isBusyForComposer)
        XCTAssertFalse(vm.hasUnconfirmedTranscript)
    }

    @MainActor
    func testKeyboardEditsAndNewRecordingRejectOldGeneration() {
        let vm = VoiceInputViewModel()
        vm.setTranscript("你好")
        let old = vm.beginStreamingDraft()
        vm.receiveStreamingEvent(.partial(segmentID: 0, text: "旧句"), generation: old)
        vm.setTranscript("键盘改好的文字")
        let fresh = vm.beginStreamingDraft()
        vm.receiveStreamingEvent(.final(segmentID: 0, text: "迟到旧句"), generation: old)
        vm.receiveStreamingEvent(.partial(segmentID: 0, text: "新句"), generation: fresh)
        XCTAssertEqual(vm.transcript, "键盘改好的文字 新句")
        vm.reset(clearTranscript: false)
        vm.receiveStreamingEvent(.final(segmentID: 0, text: "离场迟到"), generation: fresh)
        XCTAssertEqual(vm.transcript, "键盘改好的文字 新句")
    }

    @MainActor
    func testRealtimeFailurePreservesVisiblePartialAndSendInvalidatesCallbacks() {
        let vm = VoiceInputViewModel()
        let generation = vm.beginStreamingDraft()
        vm.receiveStreamingEvent(.partial(segmentID: 0, text: "保留未确认尾句"), generation: generation)
        vm.receiveStreamingEvent(.failed("测试收尾超时"), generation: generation)
        XCTAssertEqual(vm.transcript, "保留未确认尾句")
        XCTAssertTrue(vm.hasUnconfirmedTranscript)
        XCTAssertNotNil(vm.transcribeError)
        XCTAssertFalse(vm.isBusyForComposer)
        vm.clearAndRearm()
        vm.receiveStreamingEvent(.final(segmentID: 0, text: "发送后迟到"), generation: generation)
        XCTAssertEqual(vm.transcript, "")
    }

    @MainActor
    func testEmptyRealtimeResultReportsNoSpeechAndPreservesOriginalDraft() {
        let vm = VoiceInputViewModel()
        vm.setTranscript("原有草稿")
        let generation = vm.beginStreamingDraft()
        vm.receiveStreamingEvent(.final(segmentID: 0, text: ""), generation: generation)
        vm.receiveStreamingEvent(.finished, generation: generation)
        XCTAssertEqual(vm.transcript, "原有草稿")
        XCTAssertEqual(vm.lastFailure, .noSpeechRecognized)
        XCTAssertFalse(vm.isBusyForComposer)
        XCTAssertFalse(vm.hasUnconfirmedTranscript)
    }
}
