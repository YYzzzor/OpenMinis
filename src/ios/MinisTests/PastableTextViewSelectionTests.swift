import XCTest
import SwiftUI
import UIKit
@testable import Minis

@MainActor
final class PastableTextViewSelectionTests: XCTestCase {
    private final class State {
        var text: String
        var textWrites = 0
        var isFocused = false
        var hasSelection = false
        var selectionWrites = 0
        var isScrollable = false
        var isAtScrollBottom = true
        var caretLocations: [Int] = []

        init(text: String = "") {
            self.text = text
        }
    }

    private struct Fixture {
        let state: State
        let textView: UITextView
        let coordinator: PastableTextView.Coordinator
    }

    private func makeFixture(text: String = "") -> Fixture {
        let state = State(text: text)
        let representable = PastableTextView(
            text: Binding(
                get: { state.text },
                set: { state.text = $0; state.textWrites += 1 }
            ),
            isFocused: Binding(
                get: { state.isFocused },
                set: { state.isFocused = $0 }
            ),
            hasSelection: Binding(
                get: { state.hasSelection },
                set: { state.hasSelection = $0; state.selectionWrites += 1 }
            ),
            isScrollable: Binding(
                get: { state.isScrollable },
                set: { state.isScrollable = $0 }
            ),
            isAtScrollBottom: Binding(
                get: { state.isAtScrollBottom },
                set: { state.isAtScrollBottom = $0 }
            ),
            placeholder: "",
            onPasteImage: { _ in },
            onPasteFile: { _ in },
            onReturnKey: nil,
            onArrowUp: nil,
            onArrowDown: nil,
            onTab: nil,
            onCaretChange: { state.caretLocations.append($0) },
            onSelectionReplace: nil,
            desiredCaret: nil,
            maxHeightOverride: nil
        )
        let textView = UITextView()
        textView.text = text
        return Fixture(state: state, textView: textView, coordinator: representable.makeCoordinator())
    }

    /// A main-queue barrier lets callbacks queued by the coordinator run first.
    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    func testSelectionDuringViewUpdateIsNotPublishedSynchronously() async {
        let fixture = makeFixture(text: "0123456789abcdef")
        fixture.coordinator.isUpdatingView = true
        let programmaticRange = NSRange(location: 4, length: 2)
        fixture.textView.selectedRange = programmaticRange
        XCTAssertEqual(fixture.textView.selectedRange, programmaticRange)

        fixture.coordinator.textViewDidChangeSelection(fixture.textView)

        XCTAssertTrue(fixture.state.caretLocations.isEmpty)
        XCTAssertFalse(fixture.state.hasSelection)
        XCTAssertEqual(fixture.state.selectionWrites, 0)

        fixture.coordinator.isUpdatingView = false
        await drainMainQueue()

        XCTAssertEqual(fixture.state.caretLocations, [4])
        XCTAssertTrue(fixture.state.hasSelection)
        XCTAssertEqual(fixture.state.selectionWrites, 1)
    }

    func testProgrammaticSelectionChangesPublishOnlyTheLatestRange() async {
        let fixture = makeFixture(text: "0123456789abcdef")
        fixture.coordinator.isUpdatingView = true

        for range in [
            NSRange(location: 2, length: 0),
            NSRange(location: 6, length: 3),
            NSRange(location: 14, length: 2)
        ] {
            fixture.textView.selectedRange = range
            XCTAssertEqual(fixture.textView.selectedRange, range)
            fixture.coordinator.textViewDidChangeSelection(fixture.textView)
        }

        XCTAssertTrue(fixture.state.caretLocations.isEmpty)
        XCTAssertEqual(fixture.state.selectionWrites, 0)

        fixture.coordinator.isUpdatingView = false
        await drainMainQueue()

        XCTAssertEqual(fixture.state.caretLocations, [14])
        XCTAssertTrue(fixture.state.hasSelection)
        XCTAssertEqual(fixture.state.selectionWrites, 1)
    }

    func testUserSelectionPublishesImmediatelyAndCancelsQueuedUpdate() async {
        let fixture = makeFixture(text: "0123456789abcdef")
        fixture.coordinator.isUpdatingView = true
        let programmaticRange = NSRange(location: 3, length: 1)
        fixture.textView.selectedRange = programmaticRange
        XCTAssertEqual(fixture.textView.selectedRange, programmaticRange)
        fixture.coordinator.textViewDidChangeSelection(fixture.textView)

        fixture.coordinator.isUpdatingView = false
        let userRange = NSRange(location: 8, length: 0)
        fixture.textView.selectedRange = userRange
        XCTAssertEqual(fixture.textView.selectedRange, userRange)
        fixture.coordinator.textViewDidChangeSelection(fixture.textView)

        XCTAssertEqual(fixture.state.caretLocations, [8])
        XCTAssertFalse(fixture.state.hasSelection)

        await drainMainQueue()

        XCTAssertEqual(fixture.state.caretLocations, [8], "the stale queued callback must not write back again")
        XCTAssertFalse(fixture.state.hasSelection)
    }

    func testNextRealTextChangeAfterSendClearStillUpdatesBinding() async {
        let fixture = makeFixture(text: "sent text")
        fixture.state.text = ""
        fixture.coordinator.isUpdatingView = true
        fixture.textView.text = ""
        fixture.textView.selectedRange = NSRange(location: 0, length: 0)
        fixture.coordinator.textViewDidChangeSelection(fixture.textView)

        fixture.coordinator.isUpdatingView = false
        fixture.textView.text = "n"
        let newTextCaret = NSRange(location: 1, length: 0)
        fixture.textView.selectedRange = newTextCaret
        XCTAssertEqual(fixture.textView.selectedRange, newTextCaret)
        fixture.coordinator.textViewDidChange(fixture.textView)

        XCTAssertEqual(fixture.state.text, "n")
        XCTAssertEqual(fixture.state.textWrites, 1)

        await drainMainQueue()
        XCTAssertEqual(fixture.state.text, "n")
        let publishedCarets = fixture.state.caretLocations
        XCTAssertFalse(publishedCarets.isEmpty)
        XCTAssertTrue(publishedCarets.allSatisfy({ $0 == 1 }), "the queued clear callback must not restore the cleared caret")
    }
}
