import XCTest
@testable import Minis

@MainActor
final class RetryThinkingBlockTests: XCTestCase {

    private enum TestStreamError: Error {
        case interrupted
    }

    private struct TestProvider: AgentProvider {
        let name = "retry-thinking-test"
        let model = LLMModel(
            id: "retry-thinking-test",
            displayName: "Retry Thinking Test",
            provider: "Test"
        )
        let defaultMaxTokens = 1

        func streamAgentMessageClamped(
            messages: [AgentMessage],
            systemPrompt: String?,
            tools: [AgentToolDefinition],
            maxTokens: Int,
            thinkingLevel: ThinkingLevel
        ) async throws -> AsyncThrowingStream<AgentStreamEvent, Error> {
            AsyncThrowingStream { continuation in
                continuation.finish()
            }
        }
    }

    private func stream(
        _ events: [AgentStreamEvent],
        interrupted: Bool = false
    ) -> AsyncThrowingStream<AgentStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            if interrupted {
                continuation.finish(throwing: TestStreamError.interrupted)
            } else {
                continuation.finish()
            }
        }
    }

    func testRetryKeepsCommittedBlocksButDropsOnlyFailedStreamingTail() async {
        let committedThinking = AssistantBlock(kind: .thinking, content: "earlier reasoning")
        let committedText = AssistantBlock(kind: .text, content: "earlier answer")
        let failedThinking = AssistantBlock(kind: .thinking, content: "failed reasoning")
        let failedText = AssistantBlock(kind: .text, content: "failed partial answer")
        let streamingTool = AssistantBlock(
            kind: .shellTool(command: "pwd"),
            content: "",
            toolStatus: .streaming(bytes: 0)
        )
        let completedTool = AssistantBlock(
            kind: .shellTool(command: "date"),
            content: "done",
            toolStatus: .success
        )
        let message = ChatMessage(
            role: .assistant,
            content: "",
            blocks: [
                committedThinking,
                committedText,
                failedThinking,
                failedText,
                streamingTool,
                completedTool,
            ]
        )
        let viewModel = AIChatViewModel()
        viewModel.kernelStatus = .failed("Stop before starting a provider request")
        viewModel.messages = [message]
        viewModel.committedBlockCount = 2

        viewModel.retry()
        await viewModel.currentTask?.value

        XCTAssertEqual(message.blocks.map(\.id), [
            committedThinking.id,
            committedText.id,
            completedTool.id,
        ])
    }

    func testFallbackNoticeShiftsBothCommitBoundariesBeforeRetry() async {
        let committedText = AssistantBlock(kind: .text, content: "earlier answer")
        let failedThinking = AssistantBlock(kind: .thinking, content: "failed reasoning")
        let message = ChatMessage(
            role: .assistant,
            content: "",
            blocks: [committedText, failedThinking]
        )
        let info = AssistantBlock(kind: .info, content: "Switched provider")
        var committedBlockCount = 1
        var previousCommittedBlockCount = 1

        AIChatViewModel.prependFallbackInfoBlock(
            info,
            to: message,
            committedBlockCount: &committedBlockCount,
            previousCommittedBlockCount: &previousCommittedBlockCount
        )

        XCTAssertEqual(committedBlockCount, 2)
        XCTAssertEqual(previousCommittedBlockCount, 2)

        let viewModel = AIChatViewModel()
        viewModel.kernelStatus = .failed("Stop before starting a provider request")
        viewModel.messages = [message]
        viewModel.committedBlockCount = committedBlockCount

        viewModel.retry()
        await viewModel.currentTask?.value

        XCTAssertEqual(message.blocks.map(\.id), [info.id, committedText.id])
    }

    func testRetryDoesNotEraseCommittedContentWhenBoundaryExceedsBlockCount() async {
        let committedText = AssistantBlock(kind: .text, content: "earlier answer")
        let committedThinking = AssistantBlock(kind: .thinking, content: "earlier reasoning")
        let message = ChatMessage(
            role: .assistant,
            content: "",
            blocks: [committedThinking, committedText]
        )
        let viewModel = AIChatViewModel()
        viewModel.kernelStatus = .failed("Stop before starting a provider request")
        viewModel.messages = [message]
        viewModel.committedBlockCount = 5

        viewModel.retry()
        await viewModel.currentTask?.value

        XCTAssertEqual(message.blocks.map(\.id), [committedThinking.id, committedText.id])
    }

    func testRetryEntryReplacesInterruptedThinkingWithSingleNewBlock() async throws {
        let viewModel = AIChatViewModel()
        viewModel.kernelStatus = .failed("Stop before starting a provider request")
        let message = ChatMessage(role: .assistant, content: "", blocks: [])
        viewModel.messages = [message]
        let provider = TestProvider()

        do {
            _ = try await viewModel.processStreamEvents(
                stream: stream([.thinkingDelta("failed reasoning")], interrupted: true),
                msgIdx: 0,
                provider: provider
            )
            XCTFail("The interrupted stream should throw")
        } catch TestStreamError.interrupted {
            // Expected: the failed stream leaves its in-flight Thinking block in the UI.
        }

        XCTAssertEqual(message.blocks.filter { $0.kind == .thinking }.count, 1)

        viewModel.committedBlockCount = 0
        viewModel.retry()
        await viewModel.currentTask?.value

        XCTAssertTrue(message.blocks.isEmpty)

        _ = try await viewModel.processStreamEvents(
            stream: stream([
                .thinkingDelta("retry reasoning"),
                .done(stopReason: .endTurn),
            ]),
            msgIdx: 0,
            provider: provider
        )

        let thinkingBlocks = message.blocks.filter { $0.kind == .thinking }
        XCTAssertEqual(thinkingBlocks.count, 1)
        XCTAssertEqual(thinkingBlocks.first?.content, "retry reasoning")
    }
}
