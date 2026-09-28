import Foundation
import Speech
import AVFoundation
import AudioToolbox

/// 仅管理识别请求；麦克风由既有采集器独占，避免同时启动两个录音引擎。
@MainActor
final class SystemVoiceStreamingSession: VoiceStreamingSession {
    private let recognizer: SFSpeechRecognizer
    private let onDevice: Bool
    private let eventRelay: VoiceStreamingEventRelay
    nonisolated private let inputPipe: SystemVoiceAudioInputPipe
    nonisolated private let callbackRelay: RecognitionCallbackRelay

    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var activeSegmentID: Int?
    private var nextSegmentID = 0
    private var isFinishing = false
    private var isTerminal = false
    private var timeoutTask: Task<Void, Never>?
    private let startedAt = ProcessInfo.processInfo.systemUptime

    init(
        recognizer: SFSpeechRecognizer,
        onDevice: Bool,
        onEvent: @escaping @MainActor (VoiceStreamingEvent) -> Void
    ) {
        self.recognizer = recognizer
        self.onDevice = onDevice
        self.eventRelay = VoiceStreamingEventRelay(onEvent: onEvent)
        self.inputPipe = SystemVoiceAudioInputPipe()
        self.callbackRelay = RecognitionCallbackRelay()
        self.callbackRelay.setHandler { [weak self] segmentID, callback in
            self?.receive(callback, segmentID: segmentID)
        }
        VoiceLog.log("live start locale=\(recognizer.locale.identifier) onDevice=\(onDevice)")
        startNextSegment()
    }

    nonisolated func append(buffer: AVAudioPCMBuffer) {
        switch inputPipe.append(buffer) {
        case .accepted:
            break
        case .rolloverStarted(let segmentID):
            Task { @MainActor [weak self] in
                self?.handleRolloverStarted(segmentID: segmentID)
            }
        case .overflow:
            Task { @MainActor [weak self] in
                self?.fail("Recognition could not keep up with incoming audio")
            }
        case .ignored:
            break
        }
    }

    func finish() {
        guard !isTerminal, !isFinishing else { return }
        isFinishing = true
        VoiceLog.log("live finish requested t=\(String(format: "%.3f", ProcessInfo.processInfo.systemUptime - startedAt))s")
        if let segmentID = inputPipe.finishInput() {
            scheduleTimeout(for: segmentID)
        }
    }

    func cancel() {
        guard !isTerminal else { return }
        isTerminal = true
        timeoutTask?.cancel()
        timeoutTask = nil
        inputPipe.close()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        activeSegmentID = nil
        callbackRelay.invalidate()
        eventRelay.invalidate()
    }

    private func startNextSegment() {
        guard !isTerminal else { return }
        let segmentID = nextSegmentID
        nextSegmentID += 1

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = onDevice
        request.addsPunctuation = true
        request.taskHint = .dictation

        let startResult = inputPipe.start(request, segmentID: segmentID)
        guard startResult != .closed else {
            fail("Recognition session is no longer active")
            return
        }

        activeSegmentID = segmentID
        recognitionRequest = request
        let inputPipe = self.inputPipe
        let callbackRelay = self.callbackRelay
        recognitionTask = recognizer.recognitionTask(with: request) { result, error in
            if let result {
                let text = result.bestTranscription.formattedString
                if !text.isEmpty {
                    inputPipe.noteRecognizedText(segmentID: segmentID)
                }

                if result.isFinal {
                    let lastSegment = result.bestTranscription.segments.last
                    let recognizedAudioEnd = lastSegment.map { $0.timestamp + $0.duration }
                    let disposition = inputPipe.recognitionFinished(
                        segmentID: segmentID,
                        recognizedAudioEnd: recognizedAudioEnd
                    )
                    callbackRelay.enqueue(
                        segmentID: segmentID,
                        callback: .final(text: text, disposition: disposition)
                    )
                    return
                }

                callbackRelay.enqueue(segmentID: segmentID, callback: .partial(text: text))
            }

            if let error {
                let nsError = error as NSError
                let errorInfo = RecognitionErrorInfo(
                    domain: nsError.domain,
                    code: nsError.code,
                    message: nsError.localizedDescription
                )
                let hasText = inputPipe.hasRecognizedText(segmentID: segmentID)
                let disposition = inputPipe.recognitionFailed(
                    segmentID: segmentID,
                    isNoSpeech: errorInfo.isDocumentedNoSpeech,
                    hasRecognizedText: hasText
                )
                callbackRelay.enqueue(
                    segmentID: segmentID,
                    callback: .failure(error: errorInfo, disposition: disposition)
                )
            }
        }

        if startResult == .startedAndFinished {
            scheduleTimeout(for: segmentID)
        }
    }

    private func handleRolloverStarted(segmentID: Int) {
        guard !isTerminal, activeSegmentID == segmentID else { return }
        scheduleTimeout(for: segmentID)
    }

    private func receive(_ callback: RecognitionCallback, segmentID: Int) {
        guard !isTerminal, activeSegmentID == segmentID else { return }

        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
        switch callback {
        case .partial(let text):
            VoiceLog.log("live partial segment=\(segmentID) chars=\(text.count) t=\(String(format: "%.3f", elapsed))s")
            eventRelay.enqueue(.partial(segmentID: segmentID, text: text))

        case .final(let text, let disposition):
            VoiceLog.log("live final segment=\(segmentID) chars=\(text.count) t=\(String(format: "%.3f", elapsed))s")
            timeoutTask?.cancel()
            timeoutTask = nil
            eventRelay.enqueue(.final(segmentID: segmentID, text: text))
            recognitionTask = nil
            recognitionRequest = nil
            activeSegmentID = nil

            switch disposition {
            case .expectedRollover, .expectedFinish, .replayedTail:
                continueAfterFinal()
            case .unexpectedNaturalEnd:
                fail("Recognition ended before a safe audio boundary was reached")
            case .stale:
                break
            }

        case .failure(let error, let disposition):
            if case .documentedEmptyEnd = disposition {
                timeoutTask?.cancel()
                timeoutTask = nil
                eventRelay.enqueue(.final(segmentID: segmentID, text: ""))
                recognitionTask = nil
                recognitionRequest = nil
                activeSegmentID = nil
                continueAfterFinal()
            } else if case .stale = disposition {
                break
            } else {
                fail(error.message)
            }
        }
    }

    private func continueAfterFinal() {
        guard !isTerminal else { return }
        if isFinishing, !inputPipe.hasQueuedAudio {
            complete()
            return
        }
        startNextSegment()
    }

    private func scheduleTimeout(for segmentID: Int) {
        timeoutTask?.cancel()
        timeoutTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(4))
            } catch {
                return
            }
            guard let self, !self.isTerminal, self.activeSegmentID == segmentID else { return }
            self.fail("Recognition did not finish before the audio handoff timed out")
        }
    }

    private func complete() {
        guard !isTerminal else { return }
        isTerminal = true
        timeoutTask?.cancel()
        timeoutTask = nil
        inputPipe.close()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        activeSegmentID = nil
        callbackRelay.invalidate()
        eventRelay.enqueue(.finished)
    }

    private func fail(_ message: String) {
        guard !isTerminal else { return }
        isTerminal = true
        timeoutTask?.cancel()
        timeoutTask = nil
        inputPipe.close()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        activeSegmentID = nil
        callbackRelay.invalidate()
        eventRelay.enqueue(.failed(message))
    }
}

private enum RecognitionCallback: Sendable {
    case partial(text: String)
    case final(text: String, disposition: SystemVoiceAudioInputPipe.CompletionDisposition)
    case failure(error: RecognitionErrorInfo, disposition: SystemVoiceAudioInputPipe.FailureDisposition)
}

private struct RecognitionErrorInfo: Sendable {
    let domain: String
    let code: Int
    let message: String

    // Apple 将此错误定义为未识别到语音；不能用它清空已经显示的中间文字。
    var isDocumentedNoSpeech: Bool {
        domain == "kAFAssistantErrorDomain" && code == 1110
    }
}

/// 锁保护请求切换、有界交接队列与最近 PCM 时间窗；已定稿的词不再重放。
/// @unchecked Sendable 仅用于桥接同步音频回调，所有可变状态都由同一锁保护。
final class SystemVoiceAudioInputPipe: @unchecked Sendable {
    enum CompletionDisposition: Sendable, Equatable {
        case expectedRollover
        case expectedFinish
        case replayedTail
        case unexpectedNaturalEnd
        case stale
    }

    enum FailureDisposition: Sendable, Equatable {
        case documentedEmptyEnd
        case failure
        case stale
    }

    enum AppendResult: Sendable {
        case accepted
        case rolloverStarted(Int)
        case overflow
        case ignored
    }

    enum StartResult: Equatable {
        case started
        case startedAndFinished
        case closed
    }

    private enum Mode: Equatable {
        case active
        case rolling
        case waiting
        case finishing
        case closed
    }

    private struct QueuedBuffer {
        let buffer: AVAudioPCMBuffer
        let duration: Double
    }

    private struct TimedBuffer {
        let buffer: AVAudioPCMBuffer
        let start: Double
        let duration: Double
    }

    private let lock = NSLock()
    private var mode: Mode = .waiting
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var segmentID: Int?
    private var activeDuration = 0.0
    private var recognizedTextByCurrentSegment = false
    private var finishRequested = false
    private var queuedBuffers: [QueuedBuffer] = []
    private var queuedDuration = 0.0
    private var recentBuffers: [TimedBuffer] = []

    private let maximumSegmentDuration = 45.0
    private let maximumQueuedDuration = 8.5
    private let maximumReplayDuration = 8.0

    func start(_ request: SFSpeechAudioBufferRecognitionRequest, segmentID: Int) -> StartResult {
        lock.lock()
        defer { lock.unlock() }
        guard mode != .closed else { return .closed }

        self.request = request
        self.segmentID = segmentID
        activeDuration = 0
        recognizedTextByCurrentSegment = false
        recentBuffers.removeAll(keepingCapacity: true)
        mode = .active

        for queued in queuedBuffers {
            request.append(queued.buffer)
            recentBuffers.append(TimedBuffer(
                buffer: queued.buffer,
                start: activeDuration,
                duration: queued.duration
            ))
            activeDuration += queued.duration
        }
        queuedBuffers.removeAll(keepingCapacity: true)
        queuedDuration = 0
        trimRecentBuffers()

        if finishRequested {
            request.endAudio()
            mode = .finishing
            return .startedAndFinished
        }
        return .started
    }

    func append(_ buffer: AVAudioPCMBuffer) -> AppendResult {
        lock.lock()
        defer { lock.unlock() }
        guard buffer.frameLength > 0 else { return .ignored }
        let duration = Self.duration(of: buffer)
        guard duration.isFinite, duration > 0 else { return .overflow }

        switch mode {
        case .active:
            guard let request else { return .ignored }
            let start = activeDuration
            guard let retained = Self.copy(buffer, startingAtFrame: 0) else {
                mode = .closed
                self.request = nil
                recentBuffers.removeAll(keepingCapacity: false)
                return .overflow
            }
            request.append(buffer)
            activeDuration += duration
            recentBuffers.append(TimedBuffer(buffer: retained, start: start, duration: duration))
            trimRecentBuffers()
            if activeDuration >= maximumSegmentDuration {
                mode = .rolling
                request.endAudio()
                return .rolloverStarted(segmentID ?? -1)
            }
            return .accepted

        case .rolling, .waiting:
            guard let copy = Self.copy(buffer), queuedDuration + duration <= maximumQueuedDuration else {
                mode = .closed
                request = nil
                queuedBuffers.removeAll(keepingCapacity: false)
                queuedDuration = 0
                return .overflow
            }
            queuedBuffers.append(QueuedBuffer(buffer: copy, duration: duration))
            queuedDuration += duration
            return .accepted

        case .finishing, .closed:
            return .ignored
        }
    }

    func finishInput() -> Int? {
        lock.lock()
        defer { lock.unlock() }
        guard mode != .closed else { return nil }
        finishRequested = true
        switch mode {
        case .active:
            mode = .finishing
            request?.endAudio()
        case .rolling, .waiting, .finishing, .closed:
            break
        }
        return segmentID
    }

    func noteRecognizedText(segmentID: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard self.segmentID == segmentID, mode != .closed else { return }
        recognizedTextByCurrentSegment = true
    }

    func hasRecognizedText(segmentID: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return self.segmentID == segmentID && recognizedTextByCurrentSegment
    }

    func recognitionFinished(segmentID: Int) -> CompletionDisposition {
        recognitionFinished(segmentID: segmentID, recognizedAudioEnd: nil)
    }

    func recognitionFinished(
        segmentID: Int,
        recognizedAudioEnd: Double?
    ) -> CompletionDisposition {
        lock.lock()
        defer { lock.unlock() }
        guard self.segmentID == segmentID else { return .stale }

        switch mode {
        case .rolling:
            mode = .waiting
            request = nil
            recentBuffers.removeAll(keepingCapacity: true)
            return .expectedRollover
        case .finishing:
            mode = .waiting
            request = nil
            recentBuffers.removeAll(keepingCapacity: true)
            return .expectedFinish
        case .active:
            guard let recognizedAudioEnd,
                  let replay = replayBuffers(after: recognizedAudioEnd) else {
                mode = .closed
                request = nil
                queuedBuffers.removeAll(keepingCapacity: false)
                queuedDuration = 0
                recentBuffers.removeAll(keepingCapacity: false)
                return .unexpectedNaturalEnd
            }
            mode = .closed
            request = nil
            queuedBuffers = replay
            queuedDuration = replay.reduce(0) { $0 + $1.duration }
            mode = .waiting
            recentBuffers.removeAll(keepingCapacity: true)
            return .replayedTail
        case .waiting, .closed:
            return .stale
        }
    }

    func recognitionFailed(
        segmentID: Int,
        isNoSpeech: Bool,
        hasRecognizedText: Bool
    ) -> FailureDisposition {
        lock.lock()
        defer { lock.unlock() }
        guard self.segmentID == segmentID, mode != .waiting, mode != .closed else { return .stale }

        let expectedEnd = mode == .rolling || mode == .finishing
        if expectedEnd, isNoSpeech, !recognizedTextByCurrentSegment, !hasRecognizedText {
            mode = .waiting
            request = nil
            recentBuffers.removeAll(keepingCapacity: true)
            return .documentedEmptyEnd
        }

        mode = .closed
        request = nil
        queuedBuffers.removeAll(keepingCapacity: false)
        queuedDuration = 0
        return .failure
    }

    var hasQueuedAudio: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !queuedBuffers.isEmpty
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        mode = .closed
        request = nil
        queuedBuffers.removeAll(keepingCapacity: false)
        queuedDuration = 0
        recentBuffers.removeAll(keepingCapacity: false)
    }

    private static func duration(of buffer: AVAudioPCMBuffer) -> Double {
        guard buffer.format.sampleRate > 0 else { return .nan }
        return Double(buffer.frameLength) / buffer.format.sampleRate
    }

    private func trimRecentBuffers() {
        let cutoff = activeDuration - maximumReplayDuration
        while let first = recentBuffers.first,
              first.start + first.duration < cutoff {
            recentBuffers.removeFirst()
        }
    }

    private func replayBuffers(after recognizedAudioEnd: Double) -> [QueuedBuffer]? {
        guard recognizedAudioEnd.isFinite,
              recognizedAudioEnd >= 0,
              recognizedAudioEnd <= activeDuration,
              let oldest = recentBuffers.first,
              recognizedAudioEnd >= oldest.start,
              activeDuration - recognizedAudioEnd <= maximumReplayDuration + 0.1 else {
            return nil
        }

        var replay: [QueuedBuffer] = []
        var replayDuration = 0.0
        for timed in recentBuffers {
            let end = timed.start + timed.duration
            guard end > recognizedAudioEnd else { continue }

            let copy: AVAudioPCMBuffer?
            if timed.start < recognizedAudioEnd {
                let offset = Int(ceil((recognizedAudioEnd - timed.start) * timed.buffer.format.sampleRate))
                // 时间戳可能距缓冲末端不足一帧；没有剩余采样时直接进入下一缓冲。
                if offset >= Int(timed.buffer.frameLength) { continue }
                copy = Self.copy(timed.buffer, startingAtFrame: offset)
            } else {
                copy = timed.buffer
            }
            guard let copy else { return nil }
            let duration = Self.duration(of: copy)
            guard duration.isFinite, duration > 0 else { continue }
            replay.append(QueuedBuffer(buffer: copy, duration: duration))
            replayDuration += duration
        }
        guard replayDuration <= maximumQueuedDuration else { return nil }
        return replay
    }

    private static func copy(
        _ source: AVAudioPCMBuffer,
        startingAtFrame requestedOffset: Int
    ) -> AVAudioPCMBuffer? {
        let frameOffset = max(0, min(requestedOffset, Int(source.frameLength)))
        let remainingFrames = Int(source.frameLength) - frameOffset
        guard remainingFrames > 0,
              let destination = AVAudioPCMBuffer(
                pcmFormat: source.format,
                frameCapacity: AVAudioFrameCount(remainingFrames)
              ) else { return nil }
        destination.frameLength = AVAudioFrameCount(remainingFrames)

        let sourceList = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: source.audioBufferList)
        )
        let destinationList = UnsafeMutableAudioBufferListPointer(destination.mutableAudioBufferList)
        guard sourceList.count == destinationList.count else { return nil }

        for index in sourceList.indices {
            let sourceBuffer = sourceList[index]
            let destinationBuffer = destinationList[index]
            let sourceBytes = Int(sourceBuffer.mDataByteSize)
            guard source.frameLength > 0,
                  sourceBytes % Int(source.frameLength) == 0 else { return nil }
            let bytesPerFrame = sourceBytes / Int(source.frameLength)
            let offsetBytes = frameOffset * bytesPerFrame
            let byteCount = sourceBytes - offsetBytes
            guard byteCount <= Int(destinationBuffer.mDataByteSize) else { return nil }
            if byteCount > 0 {
                guard let sourceData = sourceBuffer.mData, let destinationData = destinationBuffer.mData else {
                    return nil
                }
                memcpy(destinationData, sourceData.advanced(by: offsetBytes), byteCount)
                destinationList[index].mDataByteSize = UInt32(byteCount)
            }
        }
        return destination
    }

    private static func copy(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        copy(source, startingAtFrame: 0)
    }

}

/// 锁保护回调顺序，同一片段尚未派发的中间结果只保留最新修订。
private final class RecognitionCallbackRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@MainActor (Int, RecognitionCallback) -> Void)?
    private var pending: [(Int, RecognitionCallback)] = []
    private var isScheduled = false
    private var isInvalidated = false

    func setHandler(_ handler: @escaping @MainActor (Int, RecognitionCallback) -> Void) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    func enqueue(segmentID: Int, callback: RecognitionCallback) {
        lock.lock()
        guard !isInvalidated else {
            lock.unlock()
            return
        }

        if case .partial = callback,
           let lastIndex = pending.indices.last,
           pending[lastIndex].0 == segmentID,
           case .partial = pending[lastIndex].1 {
            pending[lastIndex] = (segmentID, callback)
        } else {
            pending.append((segmentID, callback))
        }

        let shouldSchedule = !isScheduled
        isScheduled = true
        lock.unlock()

        if shouldSchedule {
            Task { @MainActor [weak self] in self?.drain() }
        }
    }

    func invalidate() {
        lock.lock()
        isInvalidated = true
        pending.removeAll(keepingCapacity: false)
        handler = nil
        lock.unlock()
    }

    @MainActor
    private func drain() {
        lock.lock()
        guard !isInvalidated else {
            isScheduled = false
            pending.removeAll(keepingCapacity: false)
            lock.unlock()
            return
        }
        let events = pending
        pending.removeAll(keepingCapacity: true)
        let handler = self.handler
        isScheduled = false
        lock.unlock()

        for (segmentID, callback) in events {
            handler?(segmentID, callback)
        }
    }
}

/// 合并尚未派发的中间结果，并在主线程按序交付；锁保护队列与取消状态。
private final class VoiceStreamingEventRelay: @unchecked Sendable {
    private let lock = NSLock()
    private let callback: @MainActor (VoiceStreamingEvent) -> Void
    private var pending: [VoiceStreamingEvent] = []
    private var isScheduled = false
    private var isClosed = false
    private var isInvalidated = false

    init(onEvent: @escaping @MainActor (VoiceStreamingEvent) -> Void) {
        callback = onEvent
    }

    func enqueue(_ event: VoiceStreamingEvent) {
        lock.lock()
        guard !isClosed, !isInvalidated else {
            lock.unlock()
            return
        }

        if case .partial(let segmentID, _) = event,
           let index = pending.lastIndex(where: {
               if case .partial(let queuedID, _) = $0 { return queuedID == segmentID }
               return false
           }) {
            pending[index] = event
        } else {
            pending.append(event)
        }

        if case .finished = event { isClosed = true }
        if case .failed = event { isClosed = true }

        if pending.count > 64 {
            pending.removeAll(keepingCapacity: false)
            pending.append(.failed("Recognition updates could not be delivered in time"))
            isClosed = true
        }

        let shouldSchedule = !isScheduled
        isScheduled = true
        lock.unlock()

        if shouldSchedule {
            Task { @MainActor [weak self] in self?.drain() }
        }
    }

    func invalidate() {
        lock.lock()
        isInvalidated = true
        pending.removeAll(keepingCapacity: false)
        lock.unlock()
    }

    @MainActor
    private func drain() {
        lock.lock()
        guard !isInvalidated else {
            isScheduled = false
            pending.removeAll(keepingCapacity: false)
            lock.unlock()
            return
        }
        let events = pending
        pending.removeAll(keepingCapacity: true)
        isScheduled = false
        lock.unlock()

        for event in events {
            callback(event)
        }
    }
}
