import XCTest
@testable import Minis

/// 锁定生产 Responses 转换器对工具结果图片的排序。
final class ResponsesToolResultImageOrderTests: XCTestCase {
    private func convert(_ messages: [AgentMessage], supportsImages: Bool = true) -> [[String: Any]] {
        let model = LLMModel(
            id: "test-responses-model",
            displayName: "Test Responses Model",
            provider: "OpenAI",
            modalityOverride: supportsImages ? .vision : .textOnly
        )
        let provider = OpenAIAgentProvider(provider: OpenAIProvider(apiKey: "test-key", model: model))
        return provider.convertMessagesResponsesAPI(messages)
    }

    private func toolResult(
        _ id: String,
        _ content: String,
        image: Data? = nil
    ) -> AgentContentPart {
        .toolResult(
            id: id,
            name: "test_tool",
            content: content,
            isError: false,
            imageData: image,
            imageMimeType: image == nil ? nil : "image/png"
        )
    }

    private func kind(_ entry: [String: Any]) -> String? {
        entry["type"] as? String ?? entry["role"] as? String
    }

    private func imageURL(_ entry: [String: Any]) -> String? {
        guard entry["role"] as? String == "user",
              let content = entry["content"] as? [[String: Any]],
              let image = content.first,
              image["type"] as? String == "input_image" else {
            return nil
        }
        return image["image_url"] as? String
    }

    func testSingleImageAndTextToolResultsKeepOriginalResultOrderWithImageFirstOrLast() {
        let image = Data([0x01])
        let cases: [([AgentContentPart], [String])] = [
            ([toolResult("call-image|fc-image", "image result", image: image), toolResult("call-text|fc-text", "text result")], ["call-image", "call-text"]),
            ([toolResult("call-text|fc-text", "text result"), toolResult("call-image|fc-image", "image result", image: image)], ["call-text", "call-image"]),
        ]

        for (parts, expectedCallIds) in cases {
            let input = convert([AgentMessage(role: .user, parts: parts)])
            let outputs = input.filter { $0["type"] as? String == "function_call_output" }

            XCTAssertEqual(outputs.compactMap { $0["call_id"] as? String }, expectedCallIds)
            XCTAssertEqual(input.prefix(2).compactMap { $0["type"] as? String }, ["function_call_output", "function_call_output"])
            XCTAssertEqual(input.compactMap(imageURL), ["data:image/png;base64,AQ=="])
        }
    }

    func testMultipleToolImagesAreAppendedAfterEveryToolOutputInPartOrder() {
        let first = Data([0x01])
        let second = Data([0x02])
        let input = convert([
            AgentMessage(role: .user, parts: [
                toolResult("call-a", "A", image: first),
                toolResult("call-b", "B", image: second),
                toolResult("call-c", "C"),
            ]),
        ])

        XCTAssertEqual(Array(input.prefix(3)).compactMap { $0["type"] as? String }, [
            "function_call_output", "function_call_output", "function_call_output",
        ])
        XCTAssertEqual(input.compactMap(imageURL), [
            "data:image/png;base64,AQ==",
            "data:image/png;base64,Ag==",
        ])
    }

    func testAdjacentResultMessagesReplayAsOneBatchAndImagesStopBeforeNextChatMessage() {
        let history = [
            AgentMessage(role: .assistant, parts: [
                .toolUse(id: "call-a|fc-a", name: "tool", input: [:]),
                .toolUse(id: "call-b|fc-b", name: "tool", input: [:]),
            ]),
            AgentMessage(role: .user, parts: [toolResult("call-a|fc-a", "A", image: Data([0x0A]))]),
            AgentMessage(role: .user, parts: [toolResult("call-b|fc-b", "B", image: Data([0x0B]))]),
            AgentMessage(role: .assistant, parts: [.text("first batch finished")]),
            AgentMessage(role: .assistant, parts: [.toolUse(id: "call-c|fc-c", name: "tool", input: [:])]),
            AgentMessage(role: .user, parts: [toolResult("call-c|fc-c", "C", image: Data([0x0C]))]),
            AgentMessage(role: .user, parts: [.text("next user turn")]),
        ]
        let input = convert(history)

        XCTAssertEqual(input.compactMap(kind), [
            "function_call", "function_call",
            "function_call_output", "function_call_output", "user", "user",
            "assistant", "function_call", "function_call_output", "user", "user",
        ])
        XCTAssertEqual(input.compactMap(imageURL), [
            "data:image/png;base64,Cg==",
            "data:image/png;base64,Cw==",
            "data:image/png;base64,DA==",
        ])
        XCTAssertEqual(input.last?["content"] as? String, "next user turn")
    }

    func testReminderTextBesideToolResultsStaysAfterAllOutputs() {
        let reminder = "<system-reminder>Read the remaining images in a new batch.</system-reminder>"
        let input = convert([
            AgentMessage(role: .user, parts: [
                toolResult("call-image", "image result", image: Data([0x01])),
                .text(reminder),
                toolResult("call-text", "text result"),
            ]),
        ])
        let reminderIndex = input.firstIndex { $0["content"] as? String == reminder }

        XCTAssertEqual(Array(input.prefix(2)).compactMap { $0["type"] as? String }, [
            "function_call_output", "function_call_output",
        ])
        XCTAssertNotNil(reminderIndex)
        XCTAssertGreaterThan(reminderIndex ?? 0, 1)
        XCTAssertEqual(input.compactMap(imageURL), ["data:image/png;base64,AQ=="])
    }

    func testPlainTextToolResultsPreserveCallIdsAndOutputText() {
        let input = convert([
            AgentMessage(role: .user, parts: [
                toolResult("call-a|fc-a", "first"),
                toolResult("call-b|fc-b", "second"),
            ]),
        ])
        let outputs = input.filter { $0["type"] as? String == "function_call_output" }

        XCTAssertEqual(outputs.compactMap { $0["call_id"] as? String }, ["call-a", "call-b"])
        XCTAssertEqual(outputs.compactMap { $0["output"] as? String }, ["first", "second"])
        XCTAssertEqual(input.count, 2)
    }

    func testNonVisionModelKeepsToolOutputsAndDropsToolResultImages() {
        let input = convert([
            AgentMessage(role: .user, parts: [
                toolResult("call-image", "image result", image: Data([0x01])),
                toolResult("call-text", "text result"),
            ]),
        ], supportsImages: false)

        XCTAssertEqual(input.compactMap { $0["type"] as? String }, [
            "function_call_output", "function_call_output",
        ])
        XCTAssertTrue(input.allSatisfy { $0["role"] == nil })
    }

    func testActualUserImageKeepsItsPositionAmongOrdinaryMessages() {
        let input = convert([
            AgentMessage(role: .user, parts: [
                .text("What is in this picture?"),
                .imageData(data: Data([0x01]), mimeType: "image/png"),
            ]),
        ])

        XCTAssertEqual(input.count, 2)
        XCTAssertEqual(input[0]["role"] as? String, "user")
        XCTAssertEqual(input[0]["content"] as? String, "What is in this picture?")
        XCTAssertEqual(imageURL(input[1]), "data:image/png;base64,AQ==")
    }

    func testMatchingReasoningEchoRemainsAtAssistantTurnHead() {
        var assistant = AgentMessage(role: .assistant, parts: [.text("answer")])
        assistant.reasoningEcho = ReasoningEcho(
            providerKind: OpenAIAgentProvider.responsesAPIProviderKind,
            modelId: "test-responses-model",
            items: [.openaiReasoning(id: "rs_test", encryptedContent: "opaque", summary: ["brief thought"])]
        )
        let input = convert([assistant])

        XCTAssertEqual(input.first?["type"] as? String, "reasoning")
        XCTAssertEqual(input.first?["id"] as? String, "rs_test")
        XCTAssertEqual(input.first?["encrypted_content"] as? String, "opaque")
        XCTAssertEqual(input.first?["summary"] as? [[String: String]], [["type": "summary_text", "text": "brief thought"]])
        XCTAssertEqual(input.last?["role"] as? String, "assistant")
        XCTAssertEqual(input.last?["content"] as? String, "answer")
    }
}
