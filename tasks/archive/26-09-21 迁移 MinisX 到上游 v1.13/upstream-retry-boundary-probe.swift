import Foundation

enum BlockKind { case text, thinking, info, tool }
enum ToolStatus { case streaming, running, success }
struct AssistantBlock {
    let id: String
    let kind: BlockKind
    let toolStatus: ToolStatus?
    init(_ id: String, _ kind: BlockKind, _ status: ToolStatus? = nil) {
        self.id = id; self.kind = kind; self.toolStatus = status
    }
}
final class ChatMessage {
    var blocks: [AssistantBlock]
    init(_ blocks: [AssistantBlock]) { self.blocks = blocks }
}
enum RetryProbe {
    @MainActor
    static func clearUncommittedStreamTail(_ message: ChatMessage, committedBlockCount: Int) {
        let lowerBound = max(0, min(committedBlockCount, message.blocks.count))
        guard lowerBound < message.blocks.count else { return }
        var kept = Array(message.blocks[0..<lowerBound])
        for block in message.blocks[lowerBound...] {
            if block.kind == .text { continue }
            // [T-dup-thinking-block] Drop uncommitted thinking blocks — not persisted, retry stream will regenerate them.
            if block.kind == .thinking { continue }
            if case .streaming = block.toolStatus { continue }
            if case .running = block.toolStatus { continue }
            kept.append(block)
        }
        message.blocks = kept
    }
}
@MainActor
func runProbe() {
let committed = AssistantBlock("committed answer", .text)
let failed = AssistantBlock("failed thinking", .thinking)
let info = AssistantBlock("fallback info", .info)
let normal = ChatMessage([committed, failed])
RetryProbe.clearUncommittedStreamTail(normal, committedBlockCount: 1)
print("ordinary boundary:", normal.blocks.map(\.id))
let actual = ChatMessage([committed, failed])
actual.blocks.insert(info, at: 0)
RetryProbe.clearUncommittedStreamTail(actual, committedBlockCount: 1)
print("v1.13 fallback insertion, unchanged boundary:", actual.blocks.map(\.id))
let corrected = ChatMessage([committed, failed])
corrected.blocks.insert(info, at: 0)
RetryProbe.clearUncommittedStreamTail(corrected, committedBlockCount: 2)
print("old patch shifts boundary by inserted block:", corrected.blocks.map(\.id))
}
await runProbe()
