import XCTest
import UIKit
import CoreFoundation

@MainActor
final class TestApplication: XCUIApplication {
    private let session = UUID().uuidString
    private var hasLaunched = false
    private static var process: String?
    /// False when the running process was launched with arguments, such as a larger text size, that a reset cannot undo.
    private static var processReusable = true
    private static let observer = NSObject()
    private static var observing = false
    private static var acknowledge: (() -> Void)?

    /// A failed case can stop with a sheet still open, which a fixture reset does not close.
    static func discardProcessAfterFailure() { processReusable = false }

    override func launch() {
        // Reapply this after tests replace launchEnvironment to clear fault injection.
        launchEnvironment["MAILERN_TEST_SESSION"] = session
        let initial = ProcessInfo.processInfo.environment
        launchEnvironment["MAILERN_TEST_ANIMATIONS"] = initial["MAILERN_TEST_ANIMATIONS"]
        guard let path = initial["MAILERN_TEST_CONTROL_FILE"],
              let name = initial["MAILERN_TEST_CONTROL_NAME"] else {
            super.launch()
            return
        }
        if !Self.observing {
            Self.observing = true
            CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                Unmanaged.passUnretained(Self.observer).toOpaque(), { _, _, _, _, _ in
                    DispatchQueue.main.async { TestApplication.acknowledge?() }
                }, (name + ".ack") as CFString, nil, .deliverImmediately)
        }
        let request = UUID().uuidString
        launchEnvironment["MAILERN_TEST_REQUEST_ID"] = request
        launchEnvironment["MAILERN_TEST_CONTROL_FILE"] = path
        launchEnvironment["MAILERN_TEST_CONTROL_NAME"] = name
        let ready = XCTestExpectation(description: "App installed isolated UI fixture \(session)")
        var response: [String: String]?
        Self.acknowledge = {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path + ".ack")),
                  let reply = try? JSONDecoder().decode([String: String].self, from: data),
                  reply["request"] == request, reply["session"] == self.session else { return }
            response = reply
            ready.fulfill()
            Self.acknowledge = nil
        }
        let previous = Self.process
        // Only independent cases reuse a process. Every launch after the first on this
        // object remains an actual relaunch, including persistence and fault tests.
        let reuse = !hasLaunched && launchArguments.isEmpty && Self.processReusable
            && previous != nil && state == .runningForeground
        hasLaunched = true
        if reuse {
            super.activate()
            do {
                try JSONEncoder().encode(launchEnvironment).write(to: URL(fileURLWithPath: path), options: .atomic)
                CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                    CFNotificationName(rawValue: name as CFString), nil, nil, true)
            } catch { XCTFail("Could not request UI fixture reset: \(error)"); return }
        } else {
            super.launch()
        }
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
        Self.acknowledge = nil
        guard let process = response?["process"] else { XCTFail("Missing app process identity"); return }
        if reuse { XCTAssertEqual(process, previous, "Fixture reset must retain the app process") }
        else if let previous { XCTAssertNotEqual(process, previous, "Relaunch must create a new app process") }
        Self.process = process
        Self.processReusable = launchArguments.isEmpty
        print("UI fixture \(reuse ? "reset" : "launch"): session=\(session) process=\(process)")
    }
}

final class ComposeDefaultsToBottomRightUITests: MailernUITestCase {
    @MainActor
    func testComposeDefaultsToBottomRight() {
        continueAfterFailure = false
        let app = TestApplication()
        app.launch()
        let compose = app.buttons["Compose"]
        XCTAssertTrue(compose.isHittable)
        XCTAssertGreaterThan(compose.frame.midY, app.frame.height * 0.7)
        XCTAssertGreaterThan(compose.frame.midX, app.frame.width * 0.5)
        compose.tap()
        XCTAssertTrue(app.navigationBars["New Message"].existsOrWait(timeout: 5))
        // The sender uses the row beside From instead of wrapping in a narrow picker.
        app.buttons["Cc/Bcc, From"].tap()
        let sender = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'From, '")).firstMatch
        XCTAssertTrue(sender.existsOrWait(timeout: 5))
        XCTAssertGreaterThan(sender.frame.width, app.frame.width * 0.6)
        XCTAssertLessThanOrEqual(sender.frame.height, 48)
        // Choosing an account changes the sender and its signature.
        sender.tap()
        XCTAssertTrue(app.buttons["morgan@student.example.com"].existsOrWait(timeout: 3))
        app.buttons["morgan@student.example.com"].tap()
        XCTAssertTrue(sender.label.contains("morgan@student.example.com"))
        XCTAssertEqual(app.textViews["Message body"].value as? String, "\n\nMorgan\nStudent, Example College")
        // The changed sender makes this a draft worth asking about.
        app.buttons["Cancel"].tap(); app.buttons["Delete Draft"].tap()
        waitForComposerDismissal(in: app)
        // Compose does not leave a blank tab selected. ComposerEditorTests checks the tab delegate.
        XCTAssertTrue(app.tabBars.buttons["Inbox"].isSelected)
        // Compose and its dismissal keep a revealed search field where it was.
        app.collectionViews.firstMatch.swipeDown(velocity: .slow)
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.existsOrWait(timeout: 5))
        let before = search.frame
        app.buttons["Compose"].tap()
        XCTAssertTrue(app.navigationBars["New Message"].existsOrWait(timeout: 5))
        app.buttons["Cancel"].tap()
        waitForComposerDismissal(in: app)
        XCTAssertTrue(search.existsOrWait(timeout: 5))
        XCTAssertEqual(search.frame.minY, before.minY, accuracy: 2)
    }
}

final class ThreadCountAlignmentUITests: MailernUITestCase {
    @MainActor
    func testCountStaysCenteredBesideReadAndUnreadSenders() {
        continueAfterFailure = false
        let app = TestApplication()
        app.launch()
        let thread = row("Dinner on Saturday?", in: app)
        for unread in [false, true] {
            XCTAssertEqual(thread.value as? String, unread ? "Unread" : "Read")
            let sender = thread.staticTexts["Casey Rivera, Me"]
            let count = thread.staticTexts["3 messages"]
            XCTAssertTrue(count.exists)
            XCTAssertEqual(count.frame.midY, sender.frame.midY, accuracy: 1)
            XCTAssertGreaterThan(count.frame.minX, sender.frame.maxX)
            if !unread { fullSwipe(thread, right: true) }
        }
    }
}

final class HTMLMailUITests: MailernUITestCase {
    @MainActor
    func testHTMLMailBlocksRemoteImagesAndRoutesLinks() {
        continueAfterFailure = false
        let app = TestApplication()
        app.launch()
        // A peek takes no touches, so it says that images are hidden without an inert button.
        peek("A little less, but better", in: app)
        XCTAssertTrue(app.staticTexts["Remote images are hidden"].existsOrWait(timeout: 10))
        XCTAssertFalse(app.buttons["Load images"].exists)
        XCTAssertTrue(app.webViews.firstMatch.staticTexts["A little less, but better"].existsOrWait(timeout: 10))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.5)).tap()
        waitForAbsence(preview(in: app))
        row("A little less, but better", in: app).tap()
        let page = app.webViews.firstMatch
        XCTAssertTrue(page.staticTexts["A little less, but better"].existsOrWait(timeout: 10))
        let load = app.buttons["Load images"]
        XCTAssertTrue(load.exists)
        load.tap()
        waitForAbsence(load)
        XCTAssertTrue(page.staticTexts["A little less, but better"].existsOrWait(timeout: 10), "The message reloads with images")
        let editors = page.links["the editors"]
        for _ in 0..<4 where !editors.isHittable { app.swipeUp() }
        editors.tap()
        XCTAssertTrue(app.navigationBars["Tip for Sample Weekly"].existsOrWait(timeout: 5))
        let to = app.descendants(matching: .any).matching(identifier: "To").firstMatch
        XCTAssertEqual(to.value as? String, "editors@example.com")
        // The fixture reset between cases does not close sheets presented from a thread.
        app.buttons["Cancel"].tap()
        waitForComposerDismissal(in: app)
    }
}

final class RecipientSearchUITests: MailernUITestCase {
    @MainActor
    func testSearchRecipientsAndPreserveSelection() {
        continueAfterFailure = false
        let app = TestApplication()
        app.launch()
        app.buttons["Compose"].tap()
        app.buttons["Add recipient"].tap()
        XCTAssertTrue(app.navigationBars["Recipients"].existsOrWait(timeout: 5))
        let search = app.searchFields["Search recipients"]
        let recipients = app.collectionViews["recipient-list"]
        XCTAssertTrue(search.isHittable)
        search.tap()
        search.typeText("  jOrDaN  ")
        XCTAssertTrue(recipients.buttons.containing(.staticText, identifier: "Dr. Jordan Lee").firstMatch.exists)
        XCTAssertFalse(recipients.staticTexts["Avery"].exists)
        search.buttons["Clear text"].tap()
        search.typeText("no-such-recipient")
        XCTAssertTrue(app.staticTexts["No recipients found"].exists)
        search.buttons["Clear text"].tap()
        XCTAssertTrue(recipients.staticTexts["Avery"].exists)
        search.typeText("orders@bookshop")
        let bookshop = recipients.buttons.containing(.staticText, identifier: "Bookshop").firstMatch
        XCTAssertTrue(bookshop.exists)
        XCTAssertFalse(recipients.staticTexts["Dr. Jordan Lee"].exists)
        bookshop.tap()
        XCTAssertFalse(app.navigationBars["Recipients"].exists)
        let to = app.descendants(matching: .any).matching(identifier: "To").firstMatch
        XCTAssertEqual(to.value as? String, "orders@bookshop.example")
        app.buttons["Add recipient"].tap()
        XCTAssertTrue(search.existsOrWait(timeout: 3))
        XCTAssertEqual(search.value as? String, "Search recipients")
        search.tap()
        search.typeText("avery")
        recipients.buttons.containing(.staticText, identifier: "Avery").firstMatch.tap()
        XCTAssertEqual(to.value as? String, "orders@bookshop.example, avery@example.com")
    }
}

final class MailFilterBarLayoutAndSearchUITests: MailernUITestCase {
    @MainActor
    func testMailFilterBarLayoutAndSearch() {
        continueAfterFailure = false
        let app = TestApplication()
        app.launch()
        openFilterOptions(in: app)
        app.buttons["Reset filters"].tap()
        app.buttons["Done"].tap()
        let filter = app.buttons["Filter"]
        // Select matches the adjacent toolbar control.
        let select = app.buttons["Select"]
        XCTAssertTrue(select.isHittable)
        XCTAssertEqual(select.frame.height, filter.frame.height, accuracy: 1)
        XCTAssertEqual(select.frame.midY, filter.frame.midY, accuracy: 1)
        // The toggle stays under the user's finger and criteria expand to its left, each time.
        let center = filter.frame.midX
        filter.tap()
        let summary = app.buttons["Filter options"]
        XCTAssertTrue(summary.existsOrWait(timeout: 3))
        XCTAssertEqual(filter.frame.midX, center, accuracy: 1)
        XCTAssertLessThanOrEqual(summary.frame.maxX, filter.frame.minX)
        XCTAssertGreaterThan(summary.frame.width, 70,
                             "The active filter must show its criteria beside the toggle")
        XCTAssertEqual(summary.value as? String, "Unread")
        XCTAssertFalse(row("Dinner on Saturday?", in: app).exists, "The Unread filter hides read mail")
        XCTAssertLessThan(abs(summary.frame.midY - filter.frame.midY), 10)
        XCTAssertLessThan(filter.frame.minX - summary.frame.maxX, 20)
        for title in ["Inbox", "Snoozed", "Settled"] {
            XCTAssertTrue(app.tabBars.buttons[title].exists)
        }
        XCTAssertTrue(app.buttons["Select"].isHittable)
        XCTAssertTrue(app.buttons["Compose"].isHittable)
        filter.tap()
        XCTAssertFalse(summary.exists)
        XCTAssertEqual(filter.value as? String, "Off")
        XCTAssertEqual(filter.frame.midX, center, accuracy: 1)
        // A search drops selections it hides, and Select All acts only on the results.
        app.buttons["Select"].tap()
        row("Course project feedback", in: app).tap()
        XCTAssertTrue(app.staticTexts["1 selected"].exists)
        let search = app.searchFields.firstMatch
        if !search.isHittable { app.swipeDown() }
        search.tap()
        // Return closes the keyboard, which otherwise covers the selection toolbar.
        search.typeText("Dinner\n")
        XCTAssertTrue(row("Dinner on Saturday?", in: app).exists)
        XCTAssertFalse(row("Course project feedback", in: app).exists)
        XCTAssertTrue(app.staticTexts["0 selected"].existsOrWait(timeout: 3))
        app.buttons["Select All"].tap()
        XCTAssertTrue(app.staticTexts["1 selected"].exists)
        app.buttons["Settle"].tap()
        // The All mail scope finds it again in Settled.
        XCTAssertTrue(app.staticTexts["No results"].existsOrWait(timeout: 5))
        app.buttons["All mail"].tap()
        XCTAssertTrue(row("Dinner on Saturday?", in: app).existsOrWait(timeout: 5))
        XCTAssertTrue(app.staticTexts["Settled · 1"].exists)
        app.buttons["Close"].tap()
        XCTAssertTrue(row("Course project feedback", in: app).existsOrWait(timeout: 5))
        XCTAssertFalse(row("Dinner on Saturday?", in: app).exists)
        filter.tap()
        XCTAssertTrue(summary.isHittable)
        XCTAssertEqual(filter.frame.midX, center, accuracy: 1)
        XCTAssertTrue(app.buttons["Compose"].isHittable)
        openFilterOptions(in: app)
        app.buttons["filter-read-all"].tap()
        app.buttons["filter-account-university"].tap()
        app.switches["Only drafts"].coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        app.buttons["Done"].tap()
        XCTAssertEqual(summary.value as? String, "Drafts, 3 accounts")
        XCTAssertTrue(summary.isHittable)
        XCTAssertTrue(app.staticTexts["No matching mail"].exists, "These accounts have no drafts")
    }
}

final class ComposerSelectionHandleDragKeepsEditingUITests: MailernUITestCase {
    @MainActor
    func testComposerSelectionHandleDragKeepsEditing() {
        continueAfterFailure = false
        let app = TestApplication()
        app.launch()
        app.buttons["Compose"].tap()
        let body = app.textViews["Message body"]
        body.tap()
        body.typeText("Select this text.\nExtend the selection here.\nKeep this final line.")
        body.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.075)).doubleTap()
        let handle = body.otherElements["com.apple.text.grabber.trailing"]
        XCTAssertTrue(handle.existsOrWait(timeout: 5))
        let grabber = handle.children(matching: .other).element(boundBy: 1)
        let initialY = grabber.frame.midY
        let knob = grabber.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        knob.press(forDuration: 0.05, thenDragTo: knob.withOffset(CGVector(dx: 80, dy: 72)))
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        XCTAssertTrue(handle.exists)
        XCTAssertGreaterThan(grabber.frame.midY, initialY + 10)
        body.typeText("Replacement ")
        XCTAssertTrue((body.value as? String ?? "").hasPrefix("Replacement "))
        app.buttons["Cancel"].tap()
        app.buttons["Delete Draft"].tap()
        waitForComposerDismissal(in: app)
    }
}

final class ComposerDragDismissesKeyboardAndKeepsContentUITests: MailernUITestCase {
    @MainActor
    func testComposerDragDismissesKeyboardAndKeepsContent() {
        continueAfterFailure = false
        let app = TestApplication()
        app.launch()
        app.buttons["Compose"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.existsOrWait(timeout: 5))
        let body = app.textViews["Message body"]
        func dismissKeyboardByDragging() {
            let start = body.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 70)))
            waitForAbsence(app.keyboards.firstMatch)
            XCTAssertTrue(app.buttons["Send"].exists)
        }
        dismissKeyboardByDragging()
        // Subject and body are the custom UIKit fields; the To field is a plain SwiftUI text field.
        for (label, text) in [("Subject", "Drag check"), ("Message body", "Keep this body")] {
            let field = app.descendants(matching: .any).matching(identifier: label).firstMatch
            field.tap()
            XCTAssertTrue(app.keyboards.firstMatch.existsOrWait(timeout: 5))
            field.typeText(text)
            dismissKeyboardByDragging()
            // New mail starts with the default account's signature below the cursor.
            XCTAssertEqual(field.value as? String, label == "Message body" ? text + "\n\nMorgan" : text)
        }
        // The fixture reset between cases does not close the composer. Left open, it blocks the next case's long press.
        app.buttons["Cancel"].tap(); app.buttons["Delete Draft"].tap()
        waitForComposerDismissal(in: app)
    }
}

final class InboxDraftPreviewEditAndDiscardUITests: MailernUITestCase {
    @MainActor
    func testInboxDraftPreviewEditAndDiscard() {
        continueAfterFailure = false
        let app = TestApplication()
        app.launch()
        let subject = "Inbox draft proof"
        app.buttons["Compose"].tap()
        XCTAssertTrue(app.navigationBars["New Message"].existsOrWait(timeout: 5))
        app.textFields["Subject"].tap(); app.textFields["Subject"].typeText(subject)
        app.textViews["Message body"].tap(); app.textViews["Message body"].typeText("An unfinished new message")
        // Swiping the composer away saves a new message as a draft.
        app.buttons["Sheet Grabber"].firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)), withVelocity: .slow, thenHoldForDuration: 0.1)
        waitForComposerDismissal(in: app)
        XCTAssertTrue(row(subject, in: app).existsOrWait(timeout: 5))
        XCTAssertTrue(row(subject, in: app).label.contains("Draft"))
        row(subject, in: app).tap()
        XCTAssertTrue(app.buttons["Edit draft"].existsOrWait(timeout: 5))
        XCTAssertFalse(app.textViews["Message body"].exists)
        app.buttons["Edit draft"].tap()
        XCTAssertEqual(app.textViews["Message body"].value as? String, "An unfinished new message\n\nMorgan")
        app.textViews["Message body"].tap()
        app.textViews["Message body"].typeText(" with an edit")
        app.buttons["Cancel"].tap(); app.buttons["Save Draft"].tap()
        waitForComposerDismissal(in: app)
        XCTAssertTrue(app.buttons["Discard draft"].existsOrWait(timeout: 5))
        XCTAssertTrue(app.textViews.matching(NSPredicate(format: "value CONTAINS %@", "with an edit")).firstMatch.existsOrWait(timeout: 5))
        app.buttons["Discard draft"].tap()
        XCTAssertTrue(app.buttons["Compose"].existsOrWait(timeout: 5))
        XCTAssertFalse(row(subject, in: app).exists)
    }
}

final class ComposerDraftSaveFailureKeepsEditorUITests: MailernUITestCase {
    @MainActor
    func testComposerDraftSaveFailureKeepsEditor() {
        // WorkflowChecks covers what failed writes leave on disk. This covers the editor, so unsaved text is not lost.
        continueAfterFailure = false
        let app = TestApplication()
        app.launchEnvironment["MAILERN_TEST_DRAFT_WRITE_FAILURE"] = "1"
        app.launch()
        app.buttons["Compose"].tap()
        XCTAssertTrue(app.navigationBars["New Message"].existsOrWait(timeout: 5))
        app.textFields["Subject"].tap(); app.textFields["Subject"].typeText("Unsaved failure proof")
        XCTAssertTrue(app.alerts["Composer"].existsOrWait(timeout: 5))
        app.alerts["Composer"].buttons["OK"].tap()
        app.buttons["Sheet Grabber"].firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)), withVelocity: .slow, thenHoldForDuration: 0.1)
        XCTAssertTrue(app.navigationBars["Unsaved failure proof"].exists, "A failed save keeps the editor open")
        XCTAssertEqual(app.textFields["Subject"].value as? String, "Unsaved failure proof")
        app.buttons["Cancel"].tap(); app.buttons["Delete Draft"].tap()
        waitForComposerDismissal(in: app)
    }
}

final class ComposerCleanupFailureClosesAfterAcknowledgementUITests: MailernUITestCase {
    @MainActor
    func testComposerCleanupFailureClosesAfterAcknowledgement() {
        // Mail that went out must not stay editable when only its draft cleanup failed.
        continueAfterFailure = false
        let app = TestApplication()
        app.launchEnvironment["MAILERN_TEST_DRAFT_DELETE_FAILURE"] = "1"
        app.launch()
        app.buttons["Compose"].tap()
        XCTAssertTrue(app.navigationBars["New Message"].existsOrWait(timeout: 5))
        let to = app.descendants(matching: .any).matching(identifier: "To").firstMatch
        to.tap(); to.typeText("recipient@example.com")
        app.textFields["Subject"].tap(); app.textFields["Subject"].typeText("Sent cleanup")
        app.buttons["Send"].tap()
        XCTAssertTrue(app.alerts["Composer"].existsOrWait(timeout: 5))
        XCTAssertFalse(app.buttons["Send"].isEnabled)
        XCTAssertFalse(app.textFields["Subject"].isEnabled)
        app.alerts["Composer"].buttons["OK"].tap()
        waitForAbsence(app.navigationBars["Sent cleanup"])
        select("Settled", in: app)
        XCTAssertTrue(row("Sent cleanup", in: app).existsOrWait(timeout: 5), "The message went out")
    }
}

final class UndoSendReopensTheReplyUITests: MailernUITestCase {
    @MainActor
    func testUndoSendReopensTheReply() {
        // WorkflowChecks covers delivery timing and scheduling. This covers the banner, the reopened composer,
        // and that Send Later passes its date on instead of sending at once.
        continueAfterFailure = false
        let app = TestApplication()
        app.launchEnvironment["MAILERN_TEST_UNDO_SEND"] = "20"
        app.launch()
        let course = "Course project feedback"
        row(course, in: app).tap()
        app.buttons["Reply"].tap(); app.buttons["Reply All"].tap()
        XCTAssertTrue(app.navigationBars["Re: \(course)"].existsOrWait(timeout: 5))
        enterText("Undo send proof", in: app.textViews["Message body"])
        app.buttons["Send"].tap()
        waitForComposerDismissal(in: app)
        XCTAssertTrue(app.staticTexts["Sending…"].existsOrWait(timeout: 3))
        app.buttons["Undo"].tap()
        let body = app.textViews["Message body"]
        XCTAssertTrue(body.existsOrWait(timeout: 5))
        XCTAssertTrue((body.value as? String)?.hasPrefix("Undo send proof") == true)
        app.buttons["Send"].press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["Send Later…"].existsOrWait(timeout: 5))
        app.buttons["Send Later…"].tap()
        XCTAssertTrue(app.navigationBars["Send Later"].existsOrWait(timeout: 5))
        let chosen = Date.now.addingTimeInterval(3600)
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "In 1 hour,")).firstMatch.tap()
        waitForComposerDismissal(in: app)
        let card = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'scheduled-card-'")).firstMatch
        XCTAssertTrue(card.existsOrWait(timeout: 5))
        XCTAssertTrue(app.staticTexts["Scheduled"].exists)
        // The card shows the chosen time, allowing for a minute boundary during the tap.
        let format = Date.FormatStyle.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()
        XCTAssertTrue([chosen, chosen.addingTimeInterval(60)].contains { app.staticTexts[$0.formatted(format)].exists })
        XCTAssertFalse(app.staticTexts["Sending…"].exists)
        // The Scheduled mailbox lists it, and Cancel Send there takes it back.
        app.navigationBars.buttons["Inbox"].tap()
        app.buttons["More"].tap()
        let scheduled = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Scheduled")).firstMatch
        XCTAssertTrue(scheduled.existsOrWait(timeout: 5))
        scheduled.tap()
        XCTAssertTrue(app.navigationBars["Scheduled"].existsOrWait(timeout: 5))
        row(course, in: app).tap()
        XCTAssertTrue(app.buttons["Cancel Send"].existsOrWait(timeout: 5))
        app.buttons["Cancel Send"].tap()
        XCTAssertTrue(app.staticTexts["No scheduled mail"].existsOrWait(timeout: 5))
        // It comes back as a draft instead of going out.
        app.navigationBars.buttons["Inbox"].tap()
        XCTAssertTrue(row(course, in: app).existsOrWait(timeout: 5))
        XCTAssertTrue(row(course, in: app).label.contains("Draft"))
    }
}

final class ThreadFoldsMessagesAndRepliesToEarlierMessageUITests: MailernUITestCase {
    @MainActor
    func testThreadFoldsMessagesAndRepliesToEarlierMessage() {
        continueAfterFailure = false
        let app = TestApplication()
        app.launch()
        let subject = "Dinner on Saturday?"
        XCTAssertTrue(row(subject, in: app).label.contains("Casey Rivera, Me"))
        XCTAssertTrue(row(subject, in: app).label.contains("3 messages"))
        row(subject, in: app).tap()

        // Only the latest message starts open, so only it offers reply controls.
        let caseyReplies = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Reply to Casey Rivera"))
        let ownReply = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Reply to Morgan")).firstMatch
        XCTAssertTrue(caseyReplies.firstMatch.existsOrWait(timeout: 5))
        XCTAssertEqual(caseyReplies.count, 1)
        XCTAssertFalse(ownReply.exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Around 7?")).firstMatch.exists)

        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Hey! Are you free")).firstMatch.tap()
        XCTAssertTrue(caseyReplies.element(boundBy: 1).existsOrWait(timeout: 5))
        XCTAssertFalse(ownReply.exists)

        // The first message in the thread is the first in the accessibility order.
        caseyReplies.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Re: \(subject)"].existsOrWait(timeout: 5))
        let quote = app.textViews["Message body"].value as? String ?? ""
        XCTAssertTrue(quote.contains("Are you free on Saturday?"))
        XCTAssertFalse(quote.contains("Around 7?"))
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "To").firstMatch.value as? String, "casey@example.com")
        app.buttons["Cancel"].tap()
        waitForAbsence(app.navigationBars["Re: \(subject)"])

        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Message actions")).element(boundBy: 0).tap()
        app.buttons["Forward"].tap()
        XCTAssertTrue(app.navigationBars["Fwd: \(subject)"].existsOrWait(timeout: 5))
        XCTAssertTrue((app.textViews["Message body"].value as? String ?? "").contains("Are you free on Saturday?"))
        app.buttons["Cancel"].tap()
        waitForAbsence(app.navigationBars["Fwd: \(subject)"])

        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Sounds good.")).firstMatch.tap()
        XCTAssertTrue(ownReply.existsOrWait(timeout: 5))
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Morgan")).firstMatch.tap()
        waitForAbsence(ownReply)

        // The toolbar still targets the latest message after a per-message reply.
        app.buttons["Reply"].tap(); app.buttons["Reply All"].tap()
        XCTAssertTrue(app.navigationBars["Re: \(subject)"].existsOrWait(timeout: 5))
        XCTAssertTrue((app.textViews["Message body"].value as? String ?? "").contains("Around 7?"))
        app.textViews["Message body"].typeText("One reply draft\n")
        app.buttons["Cancel"].tap(); app.buttons["Save Draft"].tap()
        waitForComposerDismissal(in: app)
        XCTAssertTrue(app.buttons["Edit draft"].existsOrWait(timeout: 5))
        // A reply started from a message does not resume the toolbar's draft, and keeps its own.
        caseyReplies.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Re: \(subject)"].existsOrWait(timeout: 5))
        let separate = app.textViews["Message body"].value as? String ?? ""
        XCTAssertTrue(separate.contains("Are you free on Saturday?") && !separate.contains("One reply draft"))
        app.textViews["Message body"].typeText("Earlier reply draft\n")
        app.buttons["Cancel"].tap(); app.buttons["Save Draft"].tap()
        waitForComposerDismissal(in: app)
        XCTAssertTrue(app.buttons.matching(identifier: "Edit draft").element(boundBy: 1).existsOrWait(timeout: 5))
        caseyReplies.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Re: \(subject)"].existsOrWait(timeout: 5))
        XCTAssertTrue((app.textViews["Message body"].value as? String ?? "").hasPrefix("Earlier reply draft"))
        // Sending it adds the message and removes only its own draft.
        app.buttons["Send"].tap()
        waitForAbsence(app.navigationBars["Re: \(subject)"])
        waitForAbsence(app.buttons.matching(identifier: "Edit draft").element(boundBy: 1))
        XCTAssertTrue(app.buttons["Edit draft"].exists)
        let sent = app.textViews.matching(NSPredicate(format: "value BEGINSWITH %@", "Earlier reply draft")).firstMatch
        XCTAssertTrue(sent.existsOrWait(timeout: 5))
        // The quote under the sent reply folds behind a button.
        XCTAssertFalse((sent.value as? String ?? "").contains("wrote:"))
        // The quote opens below its button.
        let revealed = app.textViews.matching(NSPredicate(format: "value BEGINSWITH %@ AND value CONTAINS %@", "On ", "Are you free on Saturday?")).firstMatch
        app.buttons["Show quoted text"].tap()
        XCTAssertTrue(revealed.existsOrWait(timeout: 5))
        XCTAssertLessThan(app.buttons["Hide quoted text"].frame.maxY, revealed.frame.minY + 1)
        app.buttons["Hide quoted text"].tap()
        waitForAbsence(revealed)
        app.buttons["Reply"].tap(); app.buttons["Reply All"].tap()
        XCTAssertTrue(app.navigationBars["Re: \(subject)"].existsOrWait(timeout: 5))
        XCTAssertTrue((app.textViews["Message body"].value as? String ?? "").hasPrefix("One reply draft"))
        app.buttons["Cancel"].tap(); app.buttons["Delete Draft"].tap()
        waitForComposerDismissal(in: app)
        waitForAbsence(app.buttons["Edit draft"])

        // A new message opens and the message it replaces folds, whether the reader left
        // that message open or folded it. Open messages are counted by their reply controls.
        // The sent reply is the latest message now, so Casey's last message has folded.
        let incoming = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Hi Morgan,"))
        XCTAssertEqual(caseyReplies.count, 1)
        app.buttons["More actions"].tap()
        app.buttons["Simulate incoming reply"].tap()
        XCTAssertTrue(incoming.firstMatch.existsOrWait(timeout: 5))
        XCTAssertEqual(caseyReplies.count, 2)
        // Five messages: the two between the first and the last two hide behind one row.
        XCTAssertTrue(app.buttons["2 earlier messages"].exists)
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Casey Rivera")).element(boundBy: 1).tap()
        waitForAbsence(caseyReplies.element(boundBy: 1))
        app.buttons["More actions"].tap()
        app.buttons["Simulate incoming reply"].tap()
        XCTAssertTrue(caseyReplies.element(boundBy: 1).existsOrWait(timeout: 5))
        XCTAssertEqual(caseyReplies.count, 2)
    }
}

final class SenderBlockingUITests: MailernUITestCase {
    @MainActor
    func testBlockFromMessageAndUnblockFromSettings() {
        continueAfterFailure = false
        let app = TestApplication()
        app.launch()
        let subject = "Dinner on Saturday?"
        let messageActions = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Message actions, Casey Rivera")).firstMatch
        row(subject, in: app).tap()
        XCTAssertTrue(messageActions.existsOrWait(timeout: 5))
        messageActions.tap()
        XCTAssertTrue(app.buttons["Block Sender"].existsOrWait(timeout: 5))
        capture("message-menu")
        app.buttons["Block Sender"].tap()

        messageActions.tap()
        app.buttons["Sender History"].tap()
        XCTAssertTrue(app.navigationBars["Casey Rivera"].existsOrWait(timeout: 5))
        XCTAssertTrue(app.staticTexts["casey@example.com"].exists)
        XCTAssertTrue(app.buttons["Unblock Sender"].exists)
        capture("sender-history")
        app.buttons["Unblock Sender"].tap()
        XCTAssertTrue(app.buttons["Block Sender"].existsOrWait(timeout: 5))
        app.buttons["Block Sender"].tap()
        let historyRow = app.staticTexts[subject].firstMatch
        XCTAssertTrue(historyRow.existsOrWait(timeout: 5))
        historyRow.tap()
        XCTAssertTrue(messageActions.existsOrWait(timeout: 5))
        app.buttons["More actions"].tap()
        app.buttons["Move to Junk"].tap()
        XCTAssertTrue(app.navigationBars["Casey Rivera"].existsOrWait(timeout: 5))
        XCTAssertTrue(app.staticTexts["Junk"].exists)
        // XCTest can find Undo before the closing native menu stops intercepting taps.
        RunLoop.current.run(until: .now.addingTimeInterval(1))
        app.buttons["Undo"].tap()
        XCTAssertTrue(app.staticTexts["Inbox"].existsOrWait(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(messageActions.existsOrWait(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()

        app.buttons["More"].tap()
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].existsOrWait(timeout: 5))
        capture("settings")
        app.buttons["Blocked Senders"].tap()
        let unblock = app.buttons["Unblock casey@example.com"]
        XCTAssertTrue(unblock.existsOrWait(timeout: 5))
        capture("blocked-senders")
        unblock.tap()
        XCTAssertTrue(app.staticTexts["No Blocked Senders"].existsOrWait(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["Done"].tap()
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

final class LongThreadScrollsToLatestMessageUITests: MailernUITestCase {
    @MainActor
    func testLongThreadScrollsToLatestMessage() {
        continueAfterFailure = false
        let app = TestApplication()
        app.launchEnvironment["MAILERN_TEST_LONG_THREAD"] = "1"
        app.launch()
        let subject = "Dinner on Saturday?"
        row(subject, in: app).tap()
        // Thread actions replace the mailbox tabs while reading.
        XCTAssertTrue(app.buttons["More actions"].existsOrWait(timeout: 5))
        XCTAssertFalse(app.tabBars.buttons["Inbox"].isHittable)
        XCTAssertFalse(app.buttons["Compose"].isHittable)
        XCTAssertTrue(app.buttons["Settle"].isHittable)
        XCTAssertTrue(app.buttons["Snooze"].isHittable)
        let caseyReplies = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Reply to Casey Rivera"))
        XCTAssertTrue(caseyReplies.firstMatch.existsOrWait(timeout: 5))
        // The first message and the last two show. One row holds the fifteen between them.
        let headers = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Casey Rivera"))
        // The Inbox row also starts with the sender until the push transition ends.
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == 3"), object: headers)
        XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 5), .completed)
        app.buttons["15 earlier messages"].tap()
        XCTAssertTrue(headers.element(boundBy: 16).existsOrWait(timeout: 5))

        // Receive a reply while scrolled away, so visibility requires the arrival scroll.
        let previousLatest = headers.element(boundBy: 16)
        for _ in 0..<16 where !previousLatest.isHittable { app.swipeUp() }
        XCTAssertTrue(previousLatest.isHittable)
        app.swipeDown(); app.swipeDown()
        XCTAssertLessThan(headers.element(boundBy: 0).frame.minY, app.frame.height)
        XCTAssertGreaterThan(previousLatest.frame.minY, app.frame.height)
        app.buttons["More actions"].tap()
        app.buttons["Simulate incoming reply"].tap()
        XCTAssertTrue(headers.element(boundBy: 17).existsOrWait(timeout: 5))
        let newest = headers.element(boundBy: 17)
        XCTAssertGreaterThan(newest.frame.minY - headers.element(boundBy: 0).frame.minY, app.frame.height)
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: newest)
        XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 5), .completed)
        XCTAssertTrue(caseyReplies.element(boundBy: caseyReplies.count - 1).isHittable)
        app.navigationBars.buttons["Inbox"].tap()
        XCTAssertTrue(app.tabBars.buttons["Inbox"].isHittable)
        XCTAssertTrue(app.buttons["Compose"].isHittable)
        row(subject, in: app).tap()
        // A reopened thread folds its middle again and opens on the latest message.
        XCTAssertTrue(app.buttons["16 earlier messages"].existsOrWait(timeout: 5))
        let refolded = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == 3"), object: headers)
        XCTAssertEqual(XCTWaiter.wait(for: [refolded], timeout: 5), .completed)
        XCTAssertTrue(headers.element(boundBy: 2).isHittable)
        XCTAssertEqual(caseyReplies.count, 1)
        XCTAssertTrue(caseyReplies.firstMatch.isHittable)
    }
}

final class FormattingKeepsSelectionAbovePanelUITests: MailernUITestCase {
    @MainActor
    func testFormattingKeepsSelectionAbovePanel() {
        continueAfterFailure = false
        let app = TestApplication()
        app.launch()
        app.buttons["Compose"].tap()
        XCTAssertTrue(app.navigationBars["New Message"].existsOrWait(timeout: 5))
        let body = app.textViews["Message body"]
        body.tap()
        body.typeText("Select this text to format")
        app.buttons["Format"].tap()
        let close = app.buttons["close"]
        XCTAssertTrue(close.existsOrWait(timeout: 5))
        body.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.12)).tap()
        XCTAssertFalse(app.keyboards.firstMatch.exists, "The keyboard must not cover Format when the body is tapped")
        XCTAssertTrue(close.isHittable)
        body.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.08)).doubleTap()
        app.descendants(matching: .any).matching(identifier: "Title").firstMatch.tap()
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "Title").firstMatch.value as? String, "1")
        XCTAssertTrue(close.isHittable)
        close.tap()
        XCTAssertTrue(app.keyboards.firstMatch.existsOrWait(timeout: 5))
        app.buttons["Format"].tap()
        XCTAssertTrue(close.existsOrWait(timeout: 5))
        app.textFields["Subject"].tap()
        waitForAbsence(close)
        XCTAssertTrue(app.keyboards.firstMatch.existsOrWait(timeout: 5))
        body.tap()
        app.buttons["Format"].tap()
        XCTAssertTrue(close.existsOrWait(timeout: 5))
        app.descendants(matching: .any).matching(identifier: "To").firstMatch.tap()
        waitForAbsence(close)
        app.buttons["Cancel"].tap()
        app.buttons["Delete Draft"].tap()
        waitForComposerDismissal(in: app)
    }
}

final class ComposerPhotoAttachmentUITests: MailernUITestCase {
    @MainActor
    func testComposerPhotoAttachment() {
        continueAfterFailure = false
        let app = TestApplication()
        app.launch()
        app.buttons["Compose"].tap()
        XCTAssertTrue(app.navigationBars["New Message"].existsOrWait(timeout: 5))
        app.textViews["Message body"].tap()
        app.buttons["Attach"].tap(); app.buttons["Photo Library"].tap()
        XCTAssertTrue(app.buttons["Cancel"].existsOrWait(timeout: 10))
        let photo = app.images.matching(NSPredicate(format: "label BEGINSWITH %@", "Photo,")).firstMatch
        XCTAssertTrue(photo.existsOrWait(timeout: 30))
        photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["Add"].wait(for: \.isEnabled, toEqual: true, timeout: 5))
        app.buttons["Add"].tap()
        let preview = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Preview Photo-")).firstMatch
        XCTAssertTrue(preview.existsOrWait(timeout: 10))
        preview.tap()
        XCTAssertTrue(app.buttons["QLOverlayDoneButtonAccessibilityIdentifier"].existsOrWait(timeout: 5))
        let rendered = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
            containsSamplePhoto(XCUIScreen.main.screenshot().image)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [rendered], timeout: 30), .completed)
        closeQuickLook(in: app)
        // WorkflowChecks covers how sent attachments are stored.
        app.buttons["Cancel"].tap(); app.buttons["Delete Draft"].tap()
        waitForComposerDismissal(in: app)
    }
}

final class ComposerFileAttachmentUITests: MailernUITestCase {
    @MainActor
    func testComposerFileAttachment() {
        continueAfterFailure = false
        let app = TestApplication()
        app.launch()
        app.buttons["Compose"].tap()
        XCTAssertTrue(app.navigationBars["New Message"].existsOrWait(timeout: 5))
        let body = app.textViews["Message body"]
        body.tap()
        // Dismissing the attachment menu by tapping the body keeps the editor usable, each time.
        for _ in 0..<2 {
            app.buttons["Attach"].tap()
            XCTAssertTrue(app.buttons["Attach File"].existsOrWait(timeout: 5))
            XCTAssertTrue(app.buttons["Photo Library"].exists)
            body.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.2)).tap()
            waitForAbsence(app.buttons["Attach File"])
        }
        XCTAssertTrue(app.buttons["Format"].isHittable)
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        enterText("After menus", in: body)
        app.buttons["Attach"].tap()
        app.buttons["Attach File"].tap()
        let browse = app.tabBars["DOC.browsingModeTabBar"].buttons["Browse"]
        XCTAssertTrue(browse.existsOrWait(timeout: 10))
        browse.tap()
        let local = app.descendants(matching: .any).matching(identifier: "On My iPhone").firstMatch
        // A cold Files picker can show Recents first; a second Browse tap opens its root.
        if !local.existsOrWait(timeout: 1) { browse.tap() }
        XCTAssertTrue(local.existsOrWait(timeout: 10))
        local.tap()
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@ AND elementType != 2", "Mailern")).firstMatch.tap()
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Sample attachment")).firstMatch.tap()
        XCTAssertTrue(app.buttons["Open"].wait(for: \.isEnabled, toEqual: true, timeout: 5))
        app.buttons["Open"].tap()
        XCTAssertTrue(app.buttons["Preview Sample attachment.txt"].existsOrWait(timeout: 10))
        // The photo case covers Quick Look.
        app.buttons["Cancel"].tap(); app.buttons["Delete Draft"].tap()
        waitForComposerDismissal(in: app)
    }
}

final class SwipeActionSettingsUITests: MailernUITestCase {
    @MainActor
    func testSwipeActionSettings() {
        continueAfterFailure = false
        let app = TestApplication()
        app.launch()
        func settings() {
            app.buttons["More"].tap()
            XCTAssertTrue(app.buttons["Settings"].wait(for: \.isHittable, toEqual: true, timeout: 5))
            // The default activation point can leave the native menu open after a swipe.
            app.buttons["Settings"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            XCTAssertTrue(app.buttons["Swipe actions"].wait(for: \.isHittable, toEqual: true, timeout: 5))
            app.buttons["Swipe actions"].tap()
            XCTAssertTrue(app.navigationBars["Swipe actions"].existsOrWait(timeout: 5))
        }
        func choose(_ slot: String, _ action: String) {
            app.buttons["Swipe \(slot)"].tap()
            app.buttons[action].tap()
        }
        func close() {
            app.navigationBars.buttons["Settings"].tap()
            app.buttons["Done"].tap()
        }
        settings()
        choose("left-primary", "Read / Unread")
        choose("right-primary", "Settle / Restore")
        choose("left-tertiary", "Move to Trash")
        close()
        let subject = "Course project feedback"
        fullSwipe(row(subject, in: app), right: false)
        XCTAssertEqual(row(subject, in: app).value as? String, "Read")
        fullSwipe(row(subject, in: app), right: true)
        waitForAbsence(row(subject, in: app))
        app.buttons["Undo"].tap()
        XCTAssertTrue(row(subject, in: app).existsOrWait(timeout: 5))
        row(subject, in: app).swipeLeft()
        XCTAssertTrue(app.buttons["Snooze"].exists)
        XCTAssertTrue(app.buttons["Trash"].exists)
        app.buttons["Trash"].tap()
        waitForAbsence(row(subject, in: app))
        app.buttons["Undo"].tap()

        settings()
        // Choosing an action for one slot removes it from the others.
        choose("left-secondary", "Move to Trash")
        XCTAssertTrue(app.buttons["Swipe left-tertiary"].label.contains("None"))
        choose("left-primary", "None")
        choose("right-primary", "Read / Unread")
        choose("right-secondary", "None")
        close()
        // Settled mail is always read, so this right edge has no action. The drag must not open the thread.
        select("Settled", in: app)
        let settled = "The photos from our trip"
        fullSwipe(row(settled, in: app), right: true)
        XCTAssertTrue(app.navigationBars["Settled"].exists)
        XCTAssertFalse(app.buttons["Unread"].exists)
        select("Inbox", in: app)
        // Without a primary action, a full swipe only reveals the buttons.
        fullSwipe(row(subject, in: app), right: false)
        XCTAssertTrue(row(subject, in: app).exists)
        XCTAssertTrue(app.navigationBars["Inbox"].exists)
        XCTAssertTrue(app.buttons["Trash"].exists)
    }
}

final class PullProgressAndReturnUITests: MailernUITestCase {
    @MainActor
    func testPullProgressAndReturn() {
        // WorkflowChecks covers the pull threshold. This covers the offsets the list reports while scrolling.
        continueAfterFailure = false
        let app = TestApplication()
        app.launchEnvironment["MAILERN_TEST_LARGE_INBOX"] = "1"
        app.launch()
        app.buttons["More"].tap()
        app.buttons["Settings"].tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Inbox pull-down")).firstMatch.tap()
        app.buttons["New email"].tap()
        app.buttons["Done"].tap()
        waitForAbsence(app.navigationBars["Settings"])
        // The list fills the screen. App points avoid a slow list lookup for every gesture.
        let anchor = row("Course project feedback", in: app)
        let initialTop = anchor.frame.minY
        let middle = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
        middle.press(forDuration: 0.01, thenDragTo: middle.withOffset(CGVector(dx: 0, dy: -180)), withVelocity: .slow, thenHoldForDuration: 0.5)
        XCTAssertLessThan(anchor.frame.minY, initialTop - 50)
        // A fast return to the top is not a deliberate pull.
        app.swipeDown(velocity: .fast)
        XCTAssertFalse(app.navigationBars["New Message"].waitForExistence(timeout: 1), "Returning to the top must not compose")
        let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
        top.press(forDuration: 0.01, thenDragTo: top.withOffset(CGVector(dx: 0, dy: 360)), withVelocity: .slow, thenHoldForDuration: 1)
        XCTAssertTrue(app.navigationBars["New Message"].existsOrWait(timeout: 5))
        app.buttons["Cancel"].tap()
        waitForComposerDismissal(in: app)
        XCTAssertTrue(app.tabBars.buttons["Inbox"].isSelected)
    }
}

final class PeekReadAndThreadUITests: MailernUITestCase {
    @MainActor
    func testPeekReadAndThread() {
        continueAfterFailure = false
        let app = TestApplication()
        app.launch()
        let subject = "Course project feedback"

        peek(subject, in: app)
        // A touch that slides off a menu action cancels it and keeps the peek open.
        let read = app.buttons["Mark read"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let outside = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: app.frame.maxX - 5, dy: app.buttons["Mark read"].frame.midY))
        read.press(forDuration: 0.8, thenDragTo: outside, withVelocity: .fast, thenHoldForDuration: 0.2)
        XCTAssertTrue(preview(in: app).exists)
        expectReadStatus(subject, in: app)
        app.buttons["Mark read"].tap()
        waitForAbsence(preview(in: app))
        XCTAssertEqual(row(subject, in: app).value as? String, "Read")
        // Snooze presents over the peek, and cancelling it returns to the peek.
        peek(subject, in: app)
        app.buttons["Snooze"].tap()
        XCTAssertTrue(app.navigationBars["Snooze"].existsOrWait(timeout: 5))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(preview(in: app).existsOrWait(timeout: 5))
        // Choosing a time snoozes this conversation and closes the peek.
        app.buttons["Snooze"].tap()
        let option = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "In ")).firstMatch
        XCTAssertTrue(option.existsOrWait(timeout: 5))
        option.tap()
        waitForAbsence(preview(in: app))
        waitForAbsence(row(subject, in: app))
        select("Snoozed", in: app)
        XCTAssertTrue(row(subject, in: app).existsOrWait(timeout: 5))
        select("Inbox", in: app)

        let thread = "Dinner on Saturday?"
        for _ in 0..<3 where !row(thread, in: app).isHittable { app.swipeUp() }
        peek(thread, in: app)
        XCTAssertEqual(preview(in: app).value as? String, "Read")
        XCTAssertTrue(app.staticTexts["· 3 messages"].exists)
        // The peek opens on the newest message; scrolling down reads back to the oldest.
        let latest = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Around 7?")).firstMatch
        XCTAssertTrue(latest.exists)
        XCTAssertTrue(preview(in: app).frame.contains(latest.frame))
        XCTAssertTrue(app.staticTexts["Earlier messages"].exists)
        let middle = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Sounds good.")).firstMatch
        // The full body keeps its line breaks; a folded one-line snippet would not.
        let oldest = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@ AND label ENDSWITH %@", "Hey! Are you free", "\nCasey")).firstMatch
        XCTAssertTrue(oldest.exists)
        for _ in 0..<4 where !preview(in: app).frame.contains(oldest.frame) { preview(in: app).swipeUp() }
        XCTAssertTrue(preview(in: app).frame.contains(oldest.frame))
        XCTAssertLessThan(latest.frame.minY, middle.frame.minY)
        XCTAssertLessThan(middle.frame.minY, oldest.frame.minY)
        XCTAssertEqual(preview(in: app).value as? String, "Read")
    }
}

final class PeekMenuResizeAndTapsUITests: MailernUITestCase {
    @MainActor
    func testPeekMenuResizeAndTaps() {
        continueAfterFailure = false
        let app = TestApplication()
        app.launch()
        let subject = "Course project feedback"
        peek(subject, in: app)
        let card = preview(in: app)
        let compactHeight = card.frame.height
        // Without animations the card can settle a few points off compact; the tall card is 100+ points taller.
        XCTAssertLessThan(compactHeight, app.frame.height * 0.7)
        for title in ["Mark read", "Settle", "Snooze", "Unpin"] {
            XCTAssertTrue(app.frame.contains(app.buttons[title].frame))
        }
        dragMenu(280, in: app)
        let largeHeight = card.frame.height
        XCTAssertGreaterThan(largeHeight, app.frame.height * 0.7)
        XCTAssertGreaterThan(largeHeight, compactHeight + 100)
        for title in ["Reply", "Reply All", "Forward"] {
            XCTAssertLessThanOrEqual(app.buttons[title].frame.maxY, app.frame.maxY)
        }

        // isHittable is false for this partial panel even though its shortcuts accept
        // touches. Exercise the actual visible controls rather than that proxy.
        app.buttons["Reply"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.navigationBars["Re: \(subject)"].existsOrWait(timeout: 5))
        app.buttons["Cancel"].tap()
        waitForAbsence(app.navigationBars["Re: \(subject)"])
        expectReadStatus(subject, in: app)
        peek(subject, in: app)
        XCTAssertEqual(card.frame.height, compactHeight, accuracy: 20)
        XCTAssertFalse(app.navigationBars["Re: \(subject)"].exists)
        expectReadStatus(subject, in: app)
        card.swipeUp()
        XCTAssertEqual(card.frame.height, compactHeight, accuracy: 20)
        expectReadStatus(subject, in: app)

        dragMenu(280, in: app)
        XCTAssertGreaterThan(card.frame.height, compactHeight + 100)
        expectReadStatus(subject, in: app)
        dragMenu(-280, in: app)
        XCTAssertEqual(card.frame.height, compactHeight, accuracy: 20)
        app.buttons["Mark read"].tap()
        waitForAbsence(preview(in: app))
        XCTAssertEqual(row(subject, in: app).value as? String, "Read")
    }
}

class MailernUITestCase: XCTestCase {
    override func record(_ issue: XCTIssue) {
        // Attach the main-thread failure screen to the issue so failure-only exports include it.
        let recordedIssue: XCTIssue
        if Thread.isMainThread {
            recordedIssue = MainActor.assumeIsolated {
                TestApplication.discardProcessAfterFailure()
                let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                attachment.name = "Failure state"
                attachment.lifetime = .deleteOnSuccess
                return XCTIssue(type: issue.type,
                                compactDescription: issue.compactDescription,
                                detailedDescription: issue.detailedDescription,
                                sourceCodeContext: issue.sourceCodeContext,
                                associatedError: issue.associatedError,
                                attachments: issue.attachments + [attachment],
                                severity: issue.severity)
            }
        } else {
            recordedIssue = issue
            Task { @MainActor in TestApplication.discardProcessAfterFailure() }
        }
        super.record(recordedIssue)
    }

    @MainActor
    func enterText(_ text: String, in editor: XCUIElement) {
        editor.tap()
        editor.typeText(text)
        let inserted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", text), object: editor)
        XCTAssertEqual(XCTWaiter.wait(for: [inserted], timeout: 5), .completed)
    }

    func containsSamplePhoto(_ image: UIImage) -> Bool {
        guard let cg = image.cgImage, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8,
                                      bytesPerRow: cg.width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
              let data = context.data else { return false }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        var matching = 0
        for offset in stride(from: 0, to: cg.width * cg.height * 4, by: 4) {
            if (20...50).contains(Int(pixels[offset])) && (120...160).contains(Int(pixels[offset + 1]))
                && (200...240).contains(Int(pixels[offset + 2])) { matching += 1 }
        }
        return matching > 1_000
    }

    @MainActor
    func dragMenu(_ distance: CGFloat, in app: XCUIApplication) {
        // Resolve the moving menu once so the gesture endpoint does not follow it.
        let frame = app.buttons["Reply"].frame
        let bounds = app.frame
        let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.midX - bounds.minX, dy: frame.midY - bounds.minY))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: distance)), withVelocity: .fast, thenHoldForDuration: 0.1)
    }

    @MainActor
    func closeQuickLook(in app: XCUIApplication) {
        let close = app.buttons["QLOverlayDoneButtonAccessibilityIdentifier"]
        if !close.exists {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        XCTAssertTrue(close.existsOrWait(timeout: 5))
        close.tap()
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: app.buttons["Send"])
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
    }

    @MainActor
    func fullSwipe(_ element: XCUIElement, right: Bool) {
        let start = element.coordinate(withNormalizedOffset: CGVector(dx: right ? 0.02 : 0.98, dy: 0.5))
        let end = element.coordinate(withNormalizedOffset: CGVector(dx: right ? 0.98 : 0.02, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0.1)
    }

    @MainActor
    func preview(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "peek-preview").firstMatch
    }

    @MainActor
    func openFilterOptions(in app: XCUIApplication) {
        if !app.buttons["Filter options"].exists { app.buttons["Filter"].tap() }
        app.buttons["Filter options"].tap()
    }

    @MainActor
    func row(_ subject: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", subject)).firstMatch
    }

    @MainActor
    func peek(_ subject: String, in app: XCUIApplication) {
        let conversation = row(subject, in: app)
        XCTAssertTrue(conversation.existsOrWait(timeout: 5))
        conversation.press(forDuration: 0.8)
        XCTAssertTrue(preview(in: app).existsOrWait(timeout: 5))
    }

    @MainActor
    func expectReadStatus(_ subject: String, unread: Bool = true, in app: XCUIApplication) {
        let conversation = preview(in: app).exists ? preview(in: app) : row(subject, in: app)
        XCTAssertTrue(conversation.existsOrWait(timeout: 5))
        XCTAssertEqual(conversation.value as? String, unread ? "Unread" : "Read")
    }

    @MainActor
    func select(_ section: String, in app: XCUIApplication) {
        app.tabBars.buttons[section].tap()
    }

    @MainActor
    func waitForComposerDismissal(in app: XCUIApplication) {
        // Resolve dismissal before the next native action, which otherwise can stall
        // on XCTest's animation-complete notification after a zoom transition.
        waitForAbsence(app.buttons["Send"])
    }

    @MainActor
    func waitForAbsence(_ element: XCUIElement, timeout: TimeInterval = 5) {
        XCTAssertTrue(!element.exists || element.waitForNonExistence(timeout: timeout))
    }
}

private extension XCUIElement {
    @MainActor
    func existsOrWait(timeout: TimeInterval) -> Bool {
        // Most elements already exist after XCTest's idle wait.
        exists || waitForExistence(timeout: timeout)
    }
}
