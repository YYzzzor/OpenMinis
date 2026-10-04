import XCTest
import UIKit

@MainActor
final class VoiceDraftUITests: XCTestCase {
    private let productBundleIdentifier = "com.yyzzzor.minisx"
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: productBundleIdentifier)
    }

    override func tearDown() {
        let keyboardButton = app.buttons["voice.keyboard"]
        if app.state == .runningForeground,
           keyboardButton.exists,
           keyboardButton.isEnabled,
           keyboardButton.isHittable {
            keyboardButton.tap()
        }
        super.tearDown()
    }

    func testSingleLineDraftSurvivesVoiceReturnAndAcceptsMoreTyping() {
        activateInstalledProduct()
        let draft = "语音草稿单行保留"
        replaceComposerText(with: draft)

        enterVoiceAndReturnImmediately()

        let textView = composerTextView()
        XCTAssertEqual(textView.value as? String, draft)
        textView.typeText("继续输入")
        XCTAssertEqual(textView.value as? String, draft + "继续输入")
    }

    func testMultilineDraftSurvivesTwoVoiceRoundTrips() {
        activateInstalledProduct()
        let draft = "第一行草稿\n第二行完整保留"
        replaceComposerText(with: draft)

        for _ in 0..<2 {
            enterVoiceAndReturnImmediately()
            XCTAssertEqual(composerTextView().value as? String, draft)
        }
    }

    func testLongDraftScrollsAndKeyboardReturnRemainsUsable() {
        activateInstalledProduct()
        let repeatedChinese = String(repeating: "语音草稿滚动验证", count: 14)
        let draft = String(repeating: repeatedChinese, count: 3)
        replaceComposerText(with: draft)

        let micButton = app.buttons["voice.enter"]
        XCTAssertTrue(micButton.waitForExistence(timeout: 5))
        XCTAssertTrue(micButton.isHittable)
        micButton.tap()

        let transcriptScroll = app.scrollViews.matching(
            NSPredicate(format: "label == %@", draft)
        ).firstMatch
        XCTAssertTrue(transcriptScroll.waitForExistence(timeout: 5), "Voice transcript should expose a scroll view containing the complete draft")
        let footer = app.descendants(matching: .any)["voice.status"]
        XCTAssertTrue(footer.waitForExistence(timeout: 5))
        let visibleFooter = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            footer.exists && footer.isHittable && footer.frame.maxY <= self.app.frame.maxY - 20
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [visibleFooter], timeout: 6), .completed,
                       "Voice footer should settle inside the screen at the selected font size")
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "voice-long-draft-before-scroll"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        transcriptScroll.swipeUp()

        let keyboardButton = app.buttons["voice.keyboard"]
        XCTAssertTrue(keyboardButton.waitForExistence(timeout: 5))
        XCTAssertTrue(keyboardButton.isEnabled)
        XCTAssertTrue(keyboardButton.isHittable, "Keyboard target should remain available after scrolling the transcript")
        keyboardButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.94)).tap()
        waitForComposerAndKeyboard()
        XCTAssertEqual(composerTextView().value as? String, draft)
    }

    func testVoicePanelShowsWholeDraftAndMicCancelsOpenSlashMenu() {
        activateInstalledProduct()
        let draft = "斜杠菜单恢复完整原稿"
        replaceComposerText(with: draft)

        let slashButton = app.buttons.matching(
            NSPredicate(format: "label == %@", "/")
        ).firstMatch
        XCTAssertTrue(slashButton.waitForExistence(timeout: 5), "Composer slash button should be available")
        XCTAssertTrue(slashButton.isHittable)
        slashButton.tap()

        let clearCommand = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Clear")
        ).firstMatch
        XCTAssertTrue(clearCommand.waitForExistence(timeout: 5), "Slash menu should open before entering voice")

        let micButton = app.buttons["voice.enter"]
        XCTAssertTrue(micButton.waitForExistence(timeout: 5))
        XCTAssertTrue(micButton.isHittable)
        micButton.tap()

        let wholeDraft = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", draft)
        ).firstMatch
        XCTAssertTrue(wholeDraft.waitForExistence(timeout: 5), "Voice panel should expose the complete original draft")

        let keyboardButton = app.buttons["voice.keyboard"]
        XCTAssertTrue(keyboardButton.waitForExistence(timeout: 5))
        XCTAssertTrue(keyboardButton.isEnabled, "Return to the keyboard immediately without dictating speech")
        keyboardButton.tap()

        XCTAssertEqual(composerTextView().value as? String, draft)
    }

    private func activateInstalledProduct() {
        app.activate()
        if app.state == .notRunning {
            app.launch()
        }
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15), "Installed MinisX app should become active")
        let keyboardButton = app.buttons["voice.keyboard"]
        if keyboardButton.waitForExistence(timeout: 2), keyboardButton.isEnabled, keyboardButton.isHittable {
            keyboardButton.tap()
        }
        XCTAssertTrue(app.buttons["voice.enter"].waitForExistence(timeout: 15), "Chat composer should be visible in keyboard mode")
    }

    private func composerTextView() -> XCUIElement {
        let visibleTextViews = app.textViews.allElementsBoundByIndex.filter(\.isHittable)
        guard let field = visibleTextViews.max(by: { $0.frame.maxY < $1.frame.maxY }) else {
            XCTFail("Expected the visible chat composer UITextView")
            return app.textViews.firstMatch
        }
        return field
    }

    private func replaceComposerText(with draft: String) {
        let field = composerTextView()
        let originalValue = field.value as? String ?? ""
        field.tap()
        if originalValue == draft { return }

        if !originalValue.isEmpty && originalValue != draft {
            field.press(forDuration: 1.0)
            let selectAll = menuAction(labels: ["Select All", "全選", "全选"])
            XCTAssertTrue(selectAll.waitForExistence(timeout: 4), "Select All should be available for existing composer text")
            selectAll.tap()
            field.typeText(XCUIKeyboardKey.delete.rawValue)
        }

        if draft.contains("\n") || draft.count > 80 {
            pasteText(draft, into: field)
        } else if originalValue != draft {
            field.typeText(draft)
        }
        XCTAssertEqual(field.value as? String, draft)
    }

    private func pasteText(_ text: String, into field: XCUIElement) {
        // Paste inserts whole text atomically, avoiding Return-key preferences that could send a message.
        UIPasteboard.general.string = text
        field.press(forDuration: 1.0)
        let paste = menuAction(labels: ["Paste", "粘贴", "貼上"])
        XCTAssertTrue(paste.waitForExistence(timeout: 4), "Paste should be available for multiline draft setup")
        paste.tap()
        UIPasteboard.general.string = nil
    }

    private func menuAction(labels: [String]) -> XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "label IN %@", labels)
        ).firstMatch
    }

    private func enterVoiceAndReturnImmediately() {
        let micButton = app.buttons["voice.enter"]
        XCTAssertTrue(micButton.waitForExistence(timeout: 5))
        XCTAssertTrue(micButton.isHittable)
        micButton.tap()

        let keyboardButton = app.buttons["voice.keyboard"]
        XCTAssertTrue(keyboardButton.waitForExistence(timeout: 5))
        XCTAssertTrue(keyboardButton.isEnabled, "Keyboard handoff should be available while recording")
        XCTAssertTrue(keyboardButton.isHittable)
        keyboardButton.tap()

        waitForComposerAndKeyboard()
    }

    private func waitForComposerAndKeyboard() {
        XCTAssertTrue(app.textViews.firstMatch.waitForExistence(timeout: 10), "Composer should return after voice capture finishes")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10), "Keyboard focus should return to the composer")
    }
}
