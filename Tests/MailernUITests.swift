import XCTest
import UIKit

@MainActor
final class TestApplication: XCUIApplication {
    private let session = UUID().uuidString

    override func launch() {
        // Reapply this after tests replace launchEnvironment to clear fault injection.
        launchEnvironment["MAILERN_TEST_SESSION"] = session
        super.launch()
    }
}

// XCTest schedules classes as units. Keep one test per class to balance workers.
final class ComposeDefaultsToBottomRightUITests: MailernUITestCase {
    @MainActor
    func testComposeDefaultsToBottomRight() {
        continueAfterFailure = false
        let app = TestApplication()
        for arguments in [[], ["-bottomCompose", "NO"]] {
            app.launchArguments = arguments
            app.launch()
            for mailbox in ["Inbox", "Snoozed", "Settled"] {
                select(mailbox, in: app)
                let compose = app.buttons["Compose"]
                XCTAssertTrue(compose.isHittable)
                XCTAssertGreaterThan(compose.frame.midY, app.frame.height * 0.7)
                XCTAssertGreaterThan(compose.frame.midX, app.frame.width * 0.5)
                compose.tap()
                XCTAssertTrue(app.navigationBars["New Message"].existsOrWait(timeout: 5))
                app.buttons["Cancel"].tap()
                XCTAssertTrue(app.tabBars.buttons[mailbox].isSelected)
            }
            app.terminate()
        }
    }
}

final class FilterToggleStaysAnchoredOnRepeatedChangesUITests: MailernUITestCase {
    @MainActor
    func testFilterToggleStaysAnchoredOnRepeatedChanges() {
        continueAfterFailure = false
        let app = TestApplication()
        app.launch()
        let filter = app.buttons["Filter"]
        XCTAssertTrue(filter.existsOrWait(timeout: 5))
        if filter.value as? String != "Off" { filter.tap() }
        let center = filter.frame.midX
        for _ in 0..<3 {
            filter.tap()
            let summary = app.buttons["Filter options"]
            XCTAssertTrue(summary.existsOrWait(timeout: 3))
            XCTAssertEqual(filter.frame.midX, center, accuracy: 1,
                           "The top-right toggle must stay under the user's finger")
            XCTAssertLessThanOrEqual(summary.frame.maxX, filter.frame.minX,
                                     "Criteria must expand to the left of the toggle")
            filter.tap()
            XCTAssertFalse(summary.exists)
            XCTAssertEqual(filter.frame.midX, center, accuracy: 1)
        }
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
        filter.tap()
        capture("Filter enabled - connected toolbar capsule", in: app)
        let summary = app.buttons["Filter options"]
        XCTAssertGreaterThan(summary.frame.width, 70,
                             "The active filter must show its criteria beside the toggle")
        XCTAssertEqual(summary.value as? String, "Unread")
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
        capture("Filter off - compact toggle", in: app)
        let search = app.searchFields.firstMatch
        if !search.isHittable { app.swipeDown() }
        search.tap()
        search.typeText("Dinner")
        XCTAssertTrue(row("Dinner on Saturday?", in: app).exists)
        XCTAssertFalse(row("Course project feedback", in: app).exists)
        app.buttons["Close"].tap()
        app.buttons["Compose"].tap()
        XCTAssertTrue(app.navigationBars["New Message"].existsOrWait(timeout: 5))
        app.buttons["Cancel"].tap()
        filter.tap()
        XCTAssertTrue(summary.isHittable)
        XCTAssertTrue(app.buttons["Compose"].isHittable)
        capture("Connected filter with bottom Compose", in: app)
        openFilterOptions(in: app)
        app.buttons["filter-read-all"].tap()
        app.buttons["filter-account-university"].tap()
        app.switches["Only drafts"].coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        app.buttons["Done"].tap()
        XCTAssertEqual(summary.value as? String, "Drafts, 3 accounts")
        XCTAssertTrue(summary.isHittable)
        capture("Long filter criteria", in: app)
        openFilterOptions(in: app)
        app.buttons["Reset filters"].tap()
        app.buttons["Done"].tap()
    }
}

final class SnoozeExpiryKeepsComposerSwipeDismissalUITests: MailernUITestCase {
    @MainActor
    func testSnoozeExpiryKeepsComposerSwipeDismissal() {
        continueAfterFailure = false
        let app = TestApplication()
        let subject = "Expiry \(UUID().uuidString.prefix(6))"
        app.launchEnvironment["MAILERN_TEST_EXPIRING_DRAFT"] = subject
        app.launch()
        select("Snoozed", in: app)
        XCTAssertTrue(row(subject, in: app).existsOrWait(timeout: 5))
        row(subject, in: app).tap()
        app.buttons["Edit draft"].tap()
        XCTAssertTrue(app.textViews["Message body"].existsOrWait(timeout: 5))
        let deadline = Date.now.addingTimeInterval(22)
        let expired = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in Date.now >= deadline }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expired], timeout: 25), .completed)
        app.textViews["Message body"].tap()
        app.textViews["Message body"].typeText(" after expiry")
        let grabber = app.buttons["Sheet Grabber"].firstMatch
        XCTAssertTrue(grabber.existsOrWait(timeout: 5))
        grabber.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1,
            thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)),
            withVelocity: .slow, thenHoldForDuration: 0.1)
        waitForAbsence(app.textViews["Message body"])
        app.navigationBars.buttons["Snoozed"].tap()
        XCTAssertFalse(row(subject, in: app).exists)
        select("Inbox", in: app)
        XCTAssertTrue(row(subject, in: app).existsOrWait(timeout: 5))
        row(subject, in: app).tap()
        app.buttons["Edit draft"].tap()
        XCTAssertTrue((app.textViews["Message body"].value as? String ?? "").contains("after expiry"))
        app.buttons["Cancel"].tap(); app.buttons["Delete Draft"].tap()
    }
}

final class MailboxFilterOptionsAndPersistenceUITests: MailernUITestCase {
    @MainActor
    func testMailboxFilterOptionsAndPersistence() {
        continueAfterFailure = false
        let app = TestApplication()
        app.launch()
        capture("After - mailbox filter controls", in: app)
        app.buttons["Filter"].tap()
        XCTAssertFalse(row("Dinner on Saturday?", in: app).exists)
        XCTAssertTrue(row("Course project feedback", in: app).exists)
        row("A little less, but better", in: app).tap()
        XCTAssertTrue(app.navigationBars.buttons["Inbox"].existsOrWait(timeout: 5))
        app.navigationBars.buttons["Inbox"].tap()
        XCTAssertFalse(row("A little less, but better", in: app).exists)
        openFilterOptions(in: app)
        capture("After - native filter sheet", in: app)
        app.buttons["filter-read-read"].tap()
        app.buttons["Done"].tap()
        XCTAssertTrue(row("Dinner on Saturday?", in: app).exists)
        XCTAssertFalse(row("Course project feedback", in: app).exists)
        openFilterOptions(in: app)
        app.buttons["filter-read-all"].tap()
        for id in ["icloud", "gmail", "proton"] { app.buttons["filter-account-\(id)"].tap() }
        app.buttons["Done"].tap()
        XCTAssertTrue(row("Course project feedback", in: app).exists)
        XCTAssertFalse(row("Dinner on Saturday?", in: app).exists)
        capture("After - University account filter", in: app)
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["Filter options"].existsOrWait(timeout: 5))
        XCTAssertEqual(app.buttons["Filter options"].value as? String, "University")
        XCTAssertFalse(row("Dinner on Saturday?", in: app).exists)
        app.buttons["Select"].tap(); app.buttons["Select All"].tap()
        XCTAssertTrue(app.staticTexts["2 selected"].exists)
        app.buttons["Cancel"].tap()
        select("Snoozed", in: app)
        XCTAssertTrue(row("Tickets go on sale next week", in: app).exists)
        openFilterOptions(in: app)
        XCTAssertTrue(app.switches["Only drafts"].exists)
        app.buttons["Done"].tap()
        select("Inbox", in: app)
        app.buttons["Filter"].tap()
        row("Dinner on Saturday?", in: app).tap()
        app.buttons["Settle"].tap()
        select("Settled", in: app)
        openFilterOptions(in: app)
        XCTAssertTrue(app.switches["Only sent"].exists)
        XCTAssertFalse(app.buttons["filter-read-unread"].exists)
        app.switches["Only sent"].coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        app.switches["Only sent"].coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        app.buttons["Done"].tap()
        XCTAssertTrue(row("Dinner on Saturday?", in: app).exists)
        XCTAssertFalse(row("The photos from our trip", in: app).exists)
        openFilterOptions(in: app)
        app.buttons["filter-account-icloud"].tap()
        app.buttons["Done"].tap()
        XCTAssertTrue(app.staticTexts["No matching mail"].exists)
        app.buttons["Filter"].tap()
        XCTAssertTrue(row("The photos from our trip", in: app).exists)
    }
}

final class StandaloneDraftSwipeActionsUITests: MailernUITestCase {
    @MainActor
    func testStandaloneDraftSwipeActions() {
        continueAfterFailure = false
        let app = TestApplication()
        app.launch()
        let subject = "Standalone swipe \(UUID().uuidString.prefix(6))"
        saveNewDraft(subject, in: app)
        app.buttons["More"].tap(); app.buttons["Settings"].tap(); app.buttons["Swipe actions"].tap()
        app.buttons["Swipe left-primary"].tap(); app.buttons["None"].tap()
        app.navigationBars.buttons["Settings"].tap(); app.buttons["Done"].tap()
        fullSwipe(row(subject, in: app), right: false)
        XCTAssertTrue(row(subject, in: app).exists)
        XCTAssertFalse(app.navigationBars["Snooze"].exists)
        XCTAssertFalse(app.buttons["Edit draft"].exists)
        app.buttons["More"].tap(); app.buttons["Settings"].tap(); app.buttons["Swipe actions"].tap()
        app.buttons["Reset Swipe Actions"].tap()
        app.navigationBars.buttons["Settings"].tap(); app.buttons["Done"].tap()
        fullSwipe(row(subject, in: app), right: true)
        XCTAssertTrue(row(subject, in: app).label.contains("Pinned"))
        row(subject, in: app).swipeLeft()
        XCTAssertTrue(app.buttons["Settle"].exists)
        XCTAssertTrue(app.buttons["Snooze"].exists)
        app.buttons["Snooze"].tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "In ")).firstMatch.tap()
        XCTAssertFalse(row(subject, in: app).exists)
        select("Snoozed", in: app)
        XCTAssertTrue(row(subject, in: app).label.contains("Pinned"))
        openFilterOptions(in: app)
        app.buttons["filter-read-all"].tap()
        app.switches["Only drafts"].coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertEqual(app.switches["Only drafts"].value as? String, "1")
        app.buttons["Done"].tap()
        XCTAssertTrue(row(subject, in: app).exists)
        XCTAssertFalse(row("Tickets go on sale next week", in: app).exists)
        capture("After - snoozed standalone draft", in: app)
        app.terminate(); app.launch()
        select("Snoozed", in: app)
        XCTAssertTrue(row(subject, in: app).label.contains("Pinned"))
        row(subject, in: app).tap()
        app.buttons["More actions"].tap(); app.buttons["Unpin"].tap()
        app.buttons["More actions"].tap(); app.buttons["Restore to Inbox"].tap()
        select("Inbox", in: app)
        XCTAssertFalse(row(subject, in: app).label.contains("Pinned"))
        row(subject, in: app).tap()
        confirmSnooze(in: app)
        select("Snoozed", in: app)
        row(subject, in: app).tap()
        app.buttons["Settle"].tap()
        app.alerts.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["Edit draft"].exists)
        app.navigationBars.buttons["Snoozed"].tap()
        fullSwipe(row(subject, in: app), right: false)
        XCTAssertTrue(app.buttons["Discard draft"].existsOrWait(timeout: 5))
        capture("After - standalone settle confirmation", in: app)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(row(subject, in: app).exists)
        fullSwipe(row(subject, in: app), right: false)
        app.buttons["Discard draft"].tap()
        waitForAbsence(row(subject, in: app))
        XCTAssertTrue(app.staticTexts["No matching mail"].exists)
    }
}

final class AttachedDraftReadSnoozeAndSettleUITests: MailernUITestCase {
    @MainActor
    func testAttachedDraftReadSnoozeAndSettle() {
        continueAfterFailure = false
        let app = TestApplication()
        app.launch()
        let subject = "Course project feedback"
        saveReplyDraft(subject, in: app)
        fullSwipe(row(subject, in: app), right: true)
        XCTAssertEqual(row(subject, in: app).value as? String, "Unread")
        fullSwipe(row(subject, in: app), right: true)
        XCTAssertEqual(row(subject, in: app).value as? String, "Read")
        row(subject, in: app).tap()
        app.buttons["Settle"].tap()
        XCTAssertTrue(app.buttons["Discard drafts and settle"].existsOrWait(timeout: 5))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["Edit draft"].exists)
        confirmSnooze(in: app)
        select("Snoozed", in: app)
        XCTAssertTrue(row(subject, in: app).label.contains("Draft"))
        peek(subject, in: app)
        XCTAssertTrue(preview(in: app).staticTexts["Snoozed"].exists)
        app.buttons["Settle"].tap()
        XCTAssertTrue(app.buttons["Discard drafts and settle"].existsOrWait(timeout: 5))
        capture("After - attached draft settle confirmation", in: app)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(preview(in: app).exists)
        app.buttons["Dismiss peek"].coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5)).tap()
        waitForAbsence(preview(in: app))
        app.buttons["Select"].tap(); row(subject, in: app).tap()
        app.buttons["Settle"].tap()
        app.alerts.buttons["Cancel"].tap()
        XCTAssertTrue(app.staticTexts["1 selected"].exists)
        app.buttons["Settle"].tap()
        app.buttons["Discard drafts and settle"].tap()
        waitForAbsence(row(subject, in: app))
        select("Settled", in: app)
        XCTAssertTrue(row(subject, in: app).exists)
        XCTAssertFalse(row(subject, in: app).label.contains("Draft"))
    }
}

final class SettleDraftWriteFailurePreservesDraftUITests: MailernUITestCase {
    @MainActor
    func testSettleDraftWriteFailurePreservesDraft() {
        continueAfterFailure = false
        let app = TestApplication()
        app.launchEnvironment["MAILERN_TEST_DRAFT_DELETE_FAILURE"] = "1"
        app.launch()
        let subject = "Course project feedback"
        saveReplyDraft(subject, in: app)
        fullSwipe(row(subject, in: app), right: false)
        app.buttons["Discard drafts and settle"].tap()
        XCTAssertTrue(app.alerts["Draft storage"].existsOrWait(timeout: 5))
        app.alerts["Draft storage"].buttons["OK"].tap()
        XCTAssertTrue(row(subject, in: app).label.contains("Draft"))
        select("Settled", in: app)
        XCTAssertFalse(row(subject, in: app).exists)
        app.terminate(); app.launchEnvironment = [:]; app.launch()
        row(subject, in: app).tap()
        app.buttons["Settle"].tap(); app.buttons["Discard drafts and settle"].tap()
        select("Settled", in: app)
        XCTAssertTrue(row(subject, in: app).exists)
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
        capture("Native selection handles before dragging", in: app)
        let handle = body.otherElements["com.apple.text.grabber.trailing"]
        XCTAssertTrue(handle.existsOrWait(timeout: 5))
        let grabber = handle.children(matching: .other).element(boundBy: 1)
        let initialY = grabber.frame.midY
        let knob = grabber.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        knob.press(forDuration: 0.05, thenDragTo: knob.withOffset(CGVector(dx: 80, dy: 72)))
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        XCTAssertTrue(handle.exists)
        capture("Native selection extended to the next line", in: app)
        XCTAssertGreaterThan(grabber.frame.midY, initialY + 10)
        body.typeText("Replacement ")
        XCTAssertTrue((body.value as? String ?? "").hasPrefix("Replacement "))
        app.buttons["Cancel"].tap()
        app.buttons["Delete Draft"].tap()
    }
}

final class AttachmentMenuDismissalKeepsEditorUsableUITests: MailernUITestCase {
    @MainActor
    func testAttachmentMenuDismissalKeepsEditorUsable() {
        continueAfterFailure = false
        let app = TestApplication()
        app.launch()
        app.buttons["Compose"].tap()
        let body = app.textViews["Message body"]
        body.tap()
        for _ in 0..<3 {
            app.buttons["Attach"].tap()
            XCTAssertTrue(app.buttons["Attach File"].existsOrWait(timeout: 5))
            XCTAssertTrue(app.buttons["Photo Library"].exists)
            body.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.2)).tap()
            waitForAbsence(app.buttons["Attach File"])
            XCTAssertTrue(app.buttons["Format"].isHittable)
            XCTAssertTrue(app.buttons["Attach"].isHittable)
            XCTAssertTrue(app.keyboards.firstMatch.exists)
        }
        capture("Attachment controls after menu dismissal", in: app)
        enterText("Editing after menu dismissal", in: body)
        app.buttons["Cancel"].tap()
        app.buttons["Delete Draft"].tap()
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
        for (label, text) in [("To", "recipient@example.com"), ("Subject", "Drag check"), ("Message body", "Keep this body")] {
            let field = app.descendants(matching: .any).matching(identifier: label).firstMatch
            field.tap()
            XCTAssertTrue(app.keyboards.firstMatch.existsOrWait(timeout: 5))
            field.typeText(text)
            dismissKeyboardByDragging()
            XCTAssertEqual(field.value as? String, text)
            field.tap()
            XCTAssertTrue(app.keyboards.firstMatch.existsOrWait(timeout: 5))
            dismissKeyboardByDragging()
        }
        capture("Keyboard hidden with content intact", in: app)
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
        app.buttons["Cancel"].tap(); app.buttons["Save Draft"].tap()
        XCTAssertTrue(row(subject, in: app).existsOrWait(timeout: 5))
        XCTAssertTrue(row(subject, in: app).label.contains("Draft"))
        capture("After - new draft in Inbox", in: app)
        app.terminate(); app.launch()
        row(subject, in: app).tap()
        XCTAssertTrue(app.buttons["Edit draft"].existsOrWait(timeout: 5))
        XCTAssertFalse(app.textViews["Message body"].exists)
        capture("After - standalone draft reader", in: app)
        app.buttons["Edit draft"].tap()
        XCTAssertEqual(app.textViews["Message body"].value as? String, "An unfinished new message")
        app.textViews["Message body"].tap()
        app.textViews["Message body"].typeText(" with an edit")
        app.buttons["Cancel"].tap(); app.buttons["Save Draft"].tap()
        XCTAssertTrue(app.buttons["Discard draft"].existsOrWait(timeout: 5))
        XCTAssertTrue(app.textViews.matching(NSPredicate(format: "value CONTAINS %@", "with an edit")).firstMatch.existsOrWait(timeout: 5))
        app.buttons["Discard draft"].tap()
        XCTAssertTrue(app.buttons["Compose"].existsOrWait(timeout: 5))
        XCTAssertFalse(row(subject, in: app).exists)

        let source = "Course project feedback"
        row(source, in: app).tap()
        app.buttons["Reply"].tap(); app.buttons["Reply All"].tap()
        XCTAssertTrue(app.navigationBars["Re: \(source)"].existsOrWait(timeout: 5))
        app.textViews["Message body"].typeText("An unfinished reply\n")
        app.buttons["Cancel"].tap(); app.buttons["Save Draft"].tap()
        let editDraft = app.buttons["Edit draft"]
        XCTAssertTrue(editDraft.wait(for: \.isHittable, toEqual: true, timeout: 5))
        capture("After - reply draft at bottom of thread", in: app)
        app.navigationBars.buttons["Inbox"].tap()
        XCTAssertTrue(row(source, in: app).label.contains("Draft"))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", source)).count, 1)
        capture("After - reply draft attached to Inbox row", in: app)
        row(source, in: app).tap()
        XCTAssertTrue(app.buttons["Edit draft"].existsOrWait(timeout: 5))
        app.buttons["Discard draft"].tap()
        waitForAbsence(app.buttons["Edit draft"])
        app.navigationBars.buttons["Inbox"].tap()
        XCTAssertFalse(row(source, in: app).label.contains("Draft"))
    }
}

final class SettledReplyDraftStaysInSettledAndSendsUITests: MailernUITestCase {
    @MainActor
    func testSettledReplyDraftStaysInSettledAndSends() {
        continueAfterFailure = false
        let app = TestApplication()
        app.launch()
        let subject = "Course project feedback"
        row(subject, in: app).tap(); app.buttons["Settle"].tap()
        select("Settled", in: app)
        row(subject, in: app).tap()
        app.buttons["Reply"].tap(); app.buttons["Reply All"].tap()
        XCTAssertTrue(app.navigationBars["Re: \(subject)"].existsOrWait(timeout: 5))
        app.textViews["Message body"].typeText("Reply draft send proof\n")
        app.buttons["Cancel"].tap(); app.buttons["Save Draft"].tap()
        app.navigationBars.buttons["Settled"].tap()
        XCTAssertFalse(app.buttons["Undo"].exists)
        XCTAssertTrue(row(subject, in: app).label.contains("Draft"))
        peek(subject, in: app)
        XCTAssertTrue(preview(in: app).staticTexts["Settled"].existsOrWait(timeout: 5))
        capture("Reply draft Peek keeps Settled status", in: app)
        app.buttons["Dismiss peek"].coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.98)).tap()
        row(subject, in: app).tap()
        app.buttons["Edit draft"].tap()
        XCTAssertTrue((app.textViews["Message body"].value as? String ?? "").hasPrefix("Reply draft send proof"))
        app.buttons["Send"].tap()
        waitForAbsence(app.navigationBars["Re: \(subject)"])
        XCTAssertFalse(app.buttons["Edit draft"].exists)
        app.navigationBars.buttons["Settled"].tap()
        XCTAssertTrue(row(subject, in: app).exists)
        XCTAssertFalse(row(subject, in: app).label.contains("Draft"))
        capture("After - sent reply in Settled", in: app)
    }
}

final class ThreadActionsReplaceMailboxTabsUITests: MailernUITestCase {
    @MainActor
    func testThreadActionsReplaceMailboxTabs() {
        continueAfterFailure = false
        let app = TestApplication()
        app.launch()
        row("Course project feedback", in: app).tap()
        XCTAssertTrue(app.buttons["More actions"].existsOrWait(timeout: 5))
        capture("Thread actions without mailbox tabs", in: app)
        XCTAssertFalse(app.tabBars.buttons["Inbox"].isHittable)
        XCTAssertFalse(app.buttons["Compose"].isHittable)
        XCTAssertTrue(app.buttons["Settle"].isHittable)
        XCTAssertTrue(app.buttons["Snooze"].isHittable)
        app.buttons["Reply"].tap()
        XCTAssertTrue(app.buttons["Reply All"].existsOrWait(timeout: 5))
        app.buttons["Reply All"].tap()
        XCTAssertTrue(app.navigationBars["Re: Course project feedback"].existsOrWait(timeout: 5))
        enterText("Thread action check\n", in: app.textViews["Message body"])
        app.buttons["Cancel"].tap()
        app.buttons["Delete Draft"].tap()
        app.navigationBars.buttons["Inbox"].tap()
        XCTAssertTrue(app.tabBars.buttons["Inbox"].isHittable)
        XCTAssertTrue(app.buttons["Compose"].isHittable)
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
        capture("Thread with folded earlier messages", in: app)

        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Hey! Are you free")).firstMatch.tap()
        XCTAssertTrue(caseyReplies.element(boundBy: 1).existsOrWait(timeout: 5))
        XCTAssertFalse(ownReply.exists)
        capture("Thread with an earlier message open", in: app)

        // The first message in the thread is the first in the accessibility order.
        caseyReplies.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Re: \(subject)"].existsOrWait(timeout: 5))
        let quote = app.textViews["Message body"].value as? String ?? ""
        XCTAssertTrue(quote.contains("Are you free on Saturday?"))
        XCTAssertFalse(quote.contains("Around 7?"))
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "To").firstMatch.value as? String, "casey@example.com")
        capture("Reply quotes the earlier message", in: app)
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
        XCTAssertTrue(app.buttons["Edit draft"].existsOrWait(timeout: 5))
        // A reply started from a message does not resume the toolbar's draft, and keeps its own.
        caseyReplies.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Re: \(subject)"].existsOrWait(timeout: 5))
        let separate = app.textViews["Message body"].value as? String ?? ""
        XCTAssertTrue(separate.contains("Are you free on Saturday?") && !separate.contains("One reply draft"))
        app.textViews["Message body"].typeText("Earlier reply draft\n")
        app.buttons["Cancel"].tap(); app.buttons["Save Draft"].tap()
        XCTAssertTrue(app.buttons.matching(identifier: "Edit draft").element(boundBy: 1).existsOrWait(timeout: 5))
        caseyReplies.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Re: \(subject)"].existsOrWait(timeout: 5))
        XCTAssertTrue((app.textViews["Message body"].value as? String ?? "").hasPrefix("Earlier reply draft"))
        // Sending it adds the message and removes only its own draft.
        app.buttons["Send"].tap()
        waitForAbsence(app.navigationBars["Re: \(subject)"])
        waitForAbsence(app.buttons.matching(identifier: "Edit draft").element(boundBy: 1))
        XCTAssertTrue(app.buttons["Edit draft"].exists)
        XCTAssertTrue(app.textViews.matching(NSPredicate(format: "value BEGINSWITH %@", "Earlier reply draft")).firstMatch.existsOrWait(timeout: 5))
        app.buttons["Reply"].tap(); app.buttons["Reply All"].tap()
        XCTAssertTrue(app.navigationBars["Re: \(subject)"].existsOrWait(timeout: 5))
        XCTAssertTrue((app.textViews["Message body"].value as? String ?? "").hasPrefix("One reply draft"))
        app.buttons["Cancel"].tap(); app.buttons["Delete Draft"].tap()
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
        capture("Thread after an incoming reply", in: app)
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Casey Rivera")).element(boundBy: 2).tap()
        waitForAbsence(caseyReplies.element(boundBy: 1))
        app.buttons["More actions"].tap()
        app.buttons["Simulate incoming reply"].tap()
        XCTAssertTrue(caseyReplies.element(boundBy: 1).existsOrWait(timeout: 5))
        XCTAssertEqual(caseyReplies.count, 2)
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
        let caseyReplies = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Reply to Casey Rivera"))
        XCTAssertTrue(caseyReplies.firstMatch.existsOrWait(timeout: 5))

        // Receive a reply while scrolled away, so visibility requires the arrival scroll.
        let headers = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Casey Rivera"))
        let previousLatest = headers.element(boundBy: 12)
        XCTAssertTrue(previousLatest.isHittable)
        app.swipeDown(); app.swipeDown()
        XCTAssertLessThan(headers.element(boundBy: 0).frame.minY, app.frame.height)
        XCTAssertGreaterThan(previousLatest.frame.minY, app.frame.height)
        app.buttons["More actions"].tap()
        app.buttons["Simulate incoming reply"].tap()
        XCTAssertTrue(headers.element(boundBy: 13).existsOrWait(timeout: 5))
        let newest = headers.element(boundBy: 13)
        XCTAssertGreaterThan(newest.frame.minY - headers.element(boundBy: 0).frame.minY, app.frame.height)
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: newest)
        XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 5), .completed)
        XCTAssertTrue(caseyReplies.element(boundBy: caseyReplies.count - 1).isHittable)
        capture("Long thread after an incoming reply", in: app)
        app.navigationBars.buttons["Inbox"].tap()
        row(subject, in: app).tap()
        XCTAssertTrue(newest.existsOrWait(timeout: 5))
        XCTAssertGreaterThan(newest.frame.minY - headers.element(boundBy: 0).frame.minY, app.frame.height)
        XCTAssertTrue(newest.isHittable)
        XCTAssertEqual(caseyReplies.count, 1)
        XCTAssertTrue(caseyReplies.firstMatch.isHittable)
        capture("Long thread opens on the latest message", in: app)
    }
}

final class AllReadStatusKeepsRowsInPlaceUITests: MailernUITestCase {
    @MainActor
    func testAllReadStatusKeepsRowsInPlace() {
        continueAfterFailure = false
        let app = TestApplication()
        app.launch()
        app.buttons["Select"].tap()
        app.buttons["Select All"].tap()
        app.buttons["Mark"].tap()
        app.buttons["Mark read"].tap()
        XCTAssertTrue(app.staticTexts["All read"].existsOrWait(timeout: 5))
        let subject = "Course project feedback"
        let before = row(subject, in: app).frame.minY
        capture("All read keeps the status row", in: app)
        peek(subject, in: app)
        app.buttons["Mark unread"].tap()
        XCTAssertTrue(app.staticTexts["1 unread"].existsOrWait(timeout: 5))
        XCTAssertEqual(row(subject, in: app).frame.minY, before, accuracy: 2)
        peek(subject, in: app)
        app.buttons["Mark read"].tap()
        XCTAssertTrue(app.staticTexts["All read"].existsOrWait(timeout: 5))
        XCTAssertEqual(row(subject, in: app).frame.minY, before, accuracy: 2)
        capture("Last unread toggle preserves row position", in: app)
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
        capture("Body remains selectable with Format open", in: app)
        XCTAssertFalse(app.keyboards.firstMatch.exists, "The keyboard must not cover Format when the body is tapped")
        XCTAssertTrue(close.isHittable)
        body.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.08)).doubleTap()
        capture("Selected text with Format open", in: app)
        app.descendants(matching: .any).matching(identifier: "Title").firstMatch.tap()
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "Title").firstMatch.value as? String, "1")
        capture("Title applied to selected body text", in: app)
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
        capture("Recipient focus closes Format", in: app)
        waitForAbsence(close)
        app.buttons["Cancel"].tap()
        app.buttons["Delete Draft"].tap()
    }
}

final class ComposePreservesRevealedSearchPositionUITests: MailernUITestCase {
    @MainActor
    func testComposePreservesRevealedSearchPosition() {
        continueAfterFailure = false
        let app = TestApplication()
        app.launch()
        app.buttons["Compose"].tap()
        XCTAssertTrue(app.navigationBars["New Message"].existsOrWait(timeout: 5))
        app.buttons["Cancel"].tap()
        select("Snoozed", in: app)
        XCTAssertTrue(app.navigationBars["Snoozed"].existsOrWait(timeout: 5))
        app.buttons["Compose"].tap()
        XCTAssertTrue(app.navigationBars["New Message"].existsOrWait(timeout: 5))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.tabBars.buttons["Snoozed"].isSelected)
        select("Inbox", in: app)
        let list = app.collectionViews.firstMatch
        list.swipeDown(velocity: .slow)
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.existsOrWait(timeout: 5))
        let before = search.frame
        capture("Revealed search before Compose", in: app)
        app.buttons["Compose"].tap()
        XCTAssertTrue(app.navigationBars["New Message"].existsOrWait(timeout: 5))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(search.existsOrWait(timeout: 5))
        capture("Revealed search after Compose", in: app)
        XCTAssertEqual(search.frame.minY, before.minY, accuracy: 2)
    }
}

final class ComposerRevertedHeadersPersistAndStayProtectedUITests: MailernUITestCase {
    @MainActor
    func testComposerRevertedHeadersPersistAndStayProtected() {
        continueAfterFailure = false
        let app = TestApplication()
        for failure in [false, true] {
            let original = "Header \(UUID().uuidString.prefix(6))"
            app.launchEnvironment = failure ? ["MAILERN_TEST_DRAFT_REVERT_SUBJECT": original] : [:]
            app.launch()
            app.buttons["Compose"].tap()
            XCTAssertTrue(app.navigationBars["New Message"].existsOrWait(timeout: 5))
            app.textFields["Subject"].tap(); app.textFields["Subject"].typeText(original)
            capture("Native subject field", in: app)
            app.buttons["Cancel"].tap(); app.buttons["Save Draft"].tap()
            openDraft(original, in: app)
            XCTAssertTrue(app.navigationBars[original].existsOrWait(timeout: 5))
            let subject = app.textFields["Subject"]
            subject.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
            subject.typeText(" changed")
            XCTAssertEqual(subject.value as? String, original + " changed")
            Thread.sleep(forTimeInterval: 0.6) // Cross the autosave debounce before reverting.
            subject.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
            subject.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 8))
            XCTAssertEqual(subject.value as? String, original)
            if failure {
                XCTAssertTrue(app.alerts["Composer"].existsOrWait(timeout: 5))
                app.alerts["Composer"].buttons["OK"].tap()
            }
            app.buttons["Sheet Grabber"].firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)), withVelocity: .slow, thenHoldForDuration: 0.1)
            if failure {
                XCTAssertTrue(app.navigationBars[original].exists)
                XCTAssertEqual(subject.value as? String, original)
                app.terminate()
                app.launchEnvironment = [:]
                app.launch()
                openDraft(original + " changed", in: app)
                XCTAssertTrue(app.navigationBars[original + " changed"].existsOrWait(timeout: 5))
            } else {
                waitForAbsence(app.navigationBars[original])
                app.buttons["Edit draft"].tap()
                XCTAssertTrue(app.navigationBars[original].existsOrWait(timeout: 5))
                XCTAssertEqual(app.textFields["Subject"].value as? String, original)
            }
            app.buttons["Cancel"].tap(); app.buttons["Delete Draft"].tap()
            app.terminate()
        }
    }
}

final class ComposerCleanupFailureClosesAfterAcknowledgementUITests: MailernUITestCase {
    @MainActor
    func testComposerCleanupFailureClosesAfterAcknowledgement() {
        continueAfterFailure = false
        let app = TestApplication()
        app.launchEnvironment["MAILERN_TEST_DRAFT_DELETE_FAILURE"] = "1"
        app.launch()
        let subject = "Sent cleanup \(UUID().uuidString.prefix(6))"
        app.buttons["Compose"].tap()
        XCTAssertTrue(app.navigationBars["New Message"].existsOrWait(timeout: 5))
        let to = app.descendants(matching: .any).matching(identifier: "To").firstMatch
        to.tap(); to.typeText("recipient@example.com")
        app.textFields["Subject"].tap(); app.textFields["Subject"].typeText(subject)
        app.textViews["Message body"].tap(); app.textViews["Message body"].typeText("Sent once")
        app.buttons["Send"].tap()
        XCTAssertTrue(app.alerts["Composer"].existsOrWait(timeout: 5))
        XCTAssertFalse(app.buttons["Send"].isEnabled)
        XCTAssertFalse(app.textFields["Subject"].isEnabled)
        capture("Sent message with draft cleanup error", in: app)
        app.alerts["Composer"].buttons["OK"].tap()
        waitForAbsence(app.navigationBars[subject])
        select("Settled", in: app)
        XCTAssertTrue(row(subject, in: app).exists)
        app.terminate()
        app.launchEnvironment = [:]
        app.launch()
        openDraft(subject, in: app)
        XCTAssertTrue(app.navigationBars[subject].existsOrWait(timeout: 5))
        app.buttons["Cancel"].tap(); app.buttons["Delete Draft"].tap()
    }
}

final class ComposerDraftSaveFailureKeepsEditorUITests: MailernUITestCase {
    @MainActor
    func testComposerDraftSaveFailureKeepsEditor() {
        continueAfterFailure = false
        let app = TestApplication()
        app.launch()
        let subject = "Draft recovery \(UUID().uuidString.prefix(6))"
        app.buttons["Compose"].tap()
        XCTAssertTrue(app.navigationBars["New Message"].existsOrWait(timeout: 5))
        app.textFields["Subject"].tap(); app.textFields["Subject"].typeText(subject)
        app.textViews["Message body"].tap(); app.textViews["Message body"].typeText("Original text")
        app.buttons["Cancel"].tap(); app.buttons["Save Draft"].tap()
        app.terminate()
        app.launchEnvironment["MAILERN_TEST_DRAFT_WRITE_FAILURE"] = "1"
        app.launch()
        func acknowledgeFailedSave() {
            XCTAssertTrue(app.alerts["Composer"].existsOrWait(timeout: 5))
            app.alerts["Composer"].buttons["OK"].tap()
        }
        func blockedSwipe(title: String) {
            acknowledgeFailedSave()
            let before = app.textViews["Message body"].value as? String
            app.buttons["Sheet Grabber"].firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)), withVelocity: .slow, thenHoldForDuration: 0.1)
            XCTAssertTrue(app.navigationBars[title].exists)
            XCTAssertEqual(app.textViews["Message body"].value as? String, before)
            capture("Failed save keeps the editor and its contents", in: app)
        }
        app.buttons["Compose"].tap()
        XCTAssertTrue(app.navigationBars["New Message"].existsOrWait(timeout: 5))
        app.textFields["Subject"].tap(); app.textFields["Subject"].typeText("Unsaved failure proof")
        acknowledgeFailedSave()
        app.textViews["Message body"].tap(); app.textViews["Message body"].typeText("Keep these new edits")
        blockedSwipe(title: "Unsaved failure proof")
        app.buttons["Cancel"].tap(); app.buttons["Delete Draft"].tap()
        openDraft(subject, in: app)
        XCTAssertTrue(app.navigationBars[subject].existsOrWait(timeout: 5))
        app.textViews["Message body"].tap()
        app.textViews["Message body"].typeText("Changed ")
        blockedSwipe(title: subject)
        app.terminate()
        app.launchEnvironment = [:]
        app.launch()
        openDraft(subject, in: app)
        XCTAssertTrue(app.navigationBars[subject].existsOrWait(timeout: 5))
        XCTAssertEqual(app.textViews["Message body"].value as? String, "Original text")
        app.buttons["Cancel"].tap(); app.buttons["Delete Draft"].tap()
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
        let to = app.descendants(matching: .any).matching(identifier: "To").firstMatch
        to.tap(); to.typeText("recipient@example.com")
        app.textFields["Subject"].tap(); app.textFields["Subject"].typeText("Photo proof")
        app.textViews["Message body"].tap(); app.textViews["Message body"].typeText("See the photo.")
        app.buttons["Attach"].tap(); app.buttons["Photo Library"].tap()
        XCTAssertTrue(app.buttons["Cancel"].existsOrWait(timeout: 10))
        let photo = app.images.matching(NSPredicate(format: "label BEGINSWITH %@", "Photo,")).firstMatch
        XCTAssertTrue(photo.existsOrWait(timeout: 30))
        capture("Native photo picker", in: app)
        photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["Add"].wait(for: \.isEnabled, toEqual: true, timeout: 5))
        app.buttons["Add"].tap()
        let preview = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Preview Photo-")).firstMatch
        XCTAssertTrue(preview.existsOrWait(timeout: 10))
        capture("Photo attached to draft", in: app)
        preview.tap()
        XCTAssertTrue(app.buttons["QLOverlayDoneButtonAccessibilityIdentifier"].existsOrWait(timeout: 5))
        let rendered = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
            containsSamplePhoto(XCUIScreen.main.screenshot().image)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [rendered], timeout: 30), .completed)
        capture("Native photo preview", in: app)
        closeQuickLook(in: app)
        app.buttons["Send"].tap()
        waitForAbsence(app.navigationBars["Photo proof"])
        select("Settled", in: app)
        row("Photo proof", in: app).tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Preview Photo-")).firstMatch.existsOrWait(timeout: 5))
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
        let to = app.descendants(matching: .any).matching(identifier: "To").firstMatch
        to.tap(); to.typeText("recipient@example.com")
        app.textFields["Subject"].tap(); app.textFields["Subject"].typeText("Attachment proof")
        app.textViews["Message body"].tap()
        app.textViews["Message body"].typeText("See attached.")
        app.buttons["Attach"].tap()
        capture("Native attachment menu", in: app)
        app.buttons["Attach File"].tap()
        XCTAssertTrue(app.buttons.matching(identifier: "Browse").firstMatch.existsOrWait(timeout: 10))
        app.buttons.matching(identifier: "Browse").firstMatch.tap()
        let local = app.descendants(matching: .any).matching(identifier: "On My iPhone").firstMatch
        if !local.exists { app.buttons.matching(identifier: "Browse").firstMatch.tap() }
        XCTAssertTrue(local.existsOrWait(timeout: 5))
        local.tap()
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@ AND elementType != 2", "Mailern")).firstMatch.tap()
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Sample attachment")).firstMatch.tap()
        XCTAssertTrue(app.buttons["Open"].wait(for: \.isEnabled, toEqual: true, timeout: 5))
        app.buttons["Open"].tap()
        let preview = app.buttons["Preview Sample attachment.txt"]
        capture("File picker after Open", in: app)
        XCTAssertTrue(preview.existsOrWait(timeout: 10))
        capture("Imported real file attachment", in: app)
        preview.tap()
        XCTAssertTrue(app.buttons["QLOverlayDoneButtonAccessibilityIdentifier"].existsOrWait(timeout: 5))
        Thread.sleep(forTimeInterval: 15) // Allow the native remote preview to finish loading on Simulator.
        capture("Native attachment preview", in: app)
        closeQuickLook(in: app)
        app.buttons["Send"].tap()
        waitForAbsence(app.navigationBars["Attachment proof"])
        select("Settled", in: app)
        row("Attachment proof", in: app).tap()
        XCTAssertTrue(app.buttons["Preview Sample attachment.txt"].existsOrWait(timeout: 5))
    }
}

final class ComposerFormattingDraftAndSendUITests: MailernUITestCase {
    @MainActor
    func testComposerFormattingDraftAndSend() {
        continueAfterFailure = false
        let app = TestApplication()
        app.launch()
        app.buttons["Compose"].tap()
        XCTAssertTrue(app.navigationBars["New Message"].existsOrWait(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.existsOrWait(timeout: 5))
        capture("Mail-style composer with recipient keyboard", in: app)
        let to = app.descendants(matching: .any).matching(identifier: "To").firstMatch
        to.tap()
        to.typeText("recipient@example.com")
        app.textFields["Subject"].tap()
        app.textFields["Subject"].typeText("Composer proof")
        let body = app.textViews["Message body"]
        body.tap()
        body.typeText("Hello ")
        app.buttons["Format"].tap()
        capture("Native editor formatting panel", in: app)
        let bold = app.descendants(matching: .any).matching(identifier: "bold").firstMatch
        XCTAssertTrue(bold.existsOrWait(timeout: 5))
        bold.tap()
        app.buttons["close"].tap()
        body.typeText("formatted world")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["Save Draft"].existsOrWait(timeout: 5))
        capture("Native Save and Delete Draft menu", in: app)
        app.buttons["Save Draft"].tap()
        app.terminate()
        app.launch()
        openDraft("Composer proof", in: app)
        XCTAssertTrue(app.navigationBars["Composer proof"].existsOrWait(timeout: 5))
        XCTAssertEqual(app.textViews["Message body"].value as? String, "Hello formatted world")
        app.buttons["Send"].tap()
        waitForAbsence(app.navigationBars["Composer proof"])
        select("Settled", in: app)
        XCTAssertTrue(row("Composer proof", in: app).exists)
        row("Composer proof", in: app).tap()
        capture("Sent formatted message", in: app)
    }
}

final class ComposerReplyAndForwardSendUITests: MailernUITestCase {
    @MainActor
    func testComposerReplyAndForwardSend() {
        continueAfterFailure = false
        let app = TestApplication()
        app.launch()
        let subject = "Course project feedback"
        peek(subject, in: app)
        app.buttons["Reply All"].tap()
        XCTAssertTrue(app.navigationBars["Re: \(subject)"].existsOrWait(timeout: 5))
        XCTAssertTrue((app.textViews["Message body"].value as? String ?? "").contains("Jordan"))
        let body = app.textViews["Message body"]
        body.typeText("Thanks. Here is my update.\n")
        let inserted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value BEGINSWITH %@", "Thanks. Here is my update."), object: body)
        XCTAssertEqual(XCTWaiter.wait(for: [inserted], timeout: 5), .completed)
        capture("Reply with editable quoted original", in: app)
        app.buttons["Send"].tap()
        waitForAbsence(app.navigationBars["Re: \(subject)"])
        XCTAssertFalse(row(subject, in: app).exists)
        select("Settled", in: app)
        XCTAssertTrue(row(subject, in: app).exists)
        row(subject, in: app).tap()
        XCTAssertTrue(app.textViews.matching(NSPredicate(format: "value CONTAINS %@", "Thanks. Here is my update.")).firstMatch.existsOrWait(timeout: 5))
        app.navigationBars.buttons["Settled"].tap()
        select("Inbox", in: app)
        resetDemo(in: app)
        peek(subject, in: app)
        app.buttons["Forward"].tap()
        XCTAssertTrue(app.navigationBars["Fwd: \(subject)"].existsOrWait(timeout: 5))
        let to = app.descendants(matching: .any).matching(identifier: "To").firstMatch
        to.tap(); to.typeText("recipient@example.com")
        app.buttons["Send"].tap()
        waitForAbsence(app.navigationBars["Fwd: \(subject)"])
        XCTAssertTrue(row(subject, in: app).exists)
        select("Settled", in: app)
        XCTAssertTrue(row("Fwd: \(subject)", in: app).exists)
    }
}

final class ComposerSwipeSavesDraftUITests: MailernUITestCase {
    @MainActor
    func testComposerSwipeSavesDraft() {
        continueAfterFailure = false
        let app = TestApplication()
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Compose"].exists)
        app.buttons["Compose"].tap()
        XCTAssertTrue(app.navigationBars["New Message"].existsOrWait(timeout: 5))
        app.textFields["Subject"].tap()
        app.textFields["Subject"].typeText("Swipe draft proof")
        let grabber = app.buttons["Sheet Grabber"].firstMatch
        XCTAssertTrue(grabber.exists)
        grabber.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)), withVelocity: .slow, thenHoldForDuration: 0.1)
        waitForAbsence(app.navigationBars["Swipe draft proof"])
        openDraft("Swipe draft proof", in: app)
        XCTAssertTrue(app.navigationBars["Swipe draft proof"].existsOrWait(timeout: 5))
        app.buttons["Cancel"].tap()
        app.buttons["Delete Draft"].tap()
        waitForAbsence(app.navigationBars["Swipe draft proof"])
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Swipe draft proof")).firstMatch.exists)
    }
}

final class SettledReadActionsUITests: MailernUITestCase {
    @MainActor
    func testSettledReadActions() {
        continueAfterFailure = false
        let app = TestApplication()
        app.launch()
        select("Settled", in: app)
        let subject = "The photos from our trip"
        peek(subject, in: app)
        capture("Settled quick peek actions", in: app)
        let peekHasUnread = app.buttons["Mark unread"].exists
        app.buttons["Pin"].tap()
        waitForAbsence(preview(in: app))
        app.buttons["Select"].tap()
        row(subject, in: app).tap()
        app.buttons["Mark"].tap()
        capture("Settled bulk actions", in: app)
        let bulkHasUnread = app.buttons["Mark unread"].exists
        app.buttons["Unpin"].tap()
        row(subject, in: app).tap()
        app.buttons["More actions"].tap()
        capture("Settled thread actions", in: app)
        let threadHasUnread = app.buttons["Mark unread"].exists
        XCTAssertFalse(peekHasUnread)
        XCTAssertFalse(bulkHasUnread)
        XCTAssertFalse(threadHasUnread)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65)).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        select("Inbox", in: app)
        let unreadSubject = "Course project feedback"
        expectReadStatus(unreadSubject, in: app)
        peek(unreadSubject, in: app)
        app.buttons["Settle"].tap()
        waitForAbsence(preview(in: app))
        select("Settled", in: app)
        XCTAssertEqual(row(unreadSubject, in: app).value as? String, "Read")
        row(unreadSubject, in: app).swipeRight()
        XCTAssertFalse(app.buttons["Unread"].exists)
        XCTAssertTrue(app.buttons["Unpin"].exists)
        app.buttons["Unpin"].tap()
        app.terminate()
        app.launch()
        select("Settled", in: app)
        XCTAssertEqual(row(unreadSubject, in: app).value as? String, "Read")
    }
}

final class SettledReadOnlySwipeDoesNotOpenThreadUITests: MailernUITestCase {
    @MainActor
    func testSettledReadOnlySwipeDoesNotOpenThread() {
        continueAfterFailure = false
        let app = TestApplication()
        app.launch()
        app.buttons["More"].tap()
        app.buttons["Settings"].tap()
        app.buttons["Swipe actions"].tap()
        app.buttons["Reset Swipe Actions"].tap()
        app.buttons["Swipe right-secondary"].tap()
        app.buttons["None"].tap()
        app.navigationBars.buttons["Settings"].tap()
        app.buttons["Done"].tap()
        select("Settled", in: app)
        let subject = "The photos from our trip"
        fullSwipe(row(subject, in: app), right: true)
        XCTAssertTrue(app.navigationBars["Settled"].exists)
        XCTAssertEqual(row(subject, in: app).value as? String, "Read")
        XCTAssertFalse(app.buttons["Unread"].exists)
        row(subject, in: app).tap()
        XCTAssertTrue(app.buttons["More actions"].existsOrWait(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        fullSwipe(row(subject, in: app), right: false)
        waitForAbsence(row(subject, in: app))
        app.buttons["More"].tap()
        app.buttons["Settings"].tap()
        app.buttons["Swipe actions"].tap()
        app.buttons["Reset Swipe Actions"].tap()
        app.navigationBars.buttons["Settings"].tap()
        app.buttons["Done"].tap()
    }
}

final class UndoBannerExpiresUITests: MailernUITestCase {
    @MainActor
    func testUndoBannerExpires() {
        continueAfterFailure = false
        let app = TestApplication()
        app.launch()
        let subject = "Course project feedback"
        for action in ["Settle", "Restore", "Snooze"] {
            app.buttons["Select"].tap()
            row(subject, in: app).tap()
            app.buttons[action].tap()
            if action == "Snooze" {
                app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "In ")).firstMatch.tap()
            }
            let undo = app.buttons["Undo"]
            XCTAssertTrue(undo.existsOrWait(timeout: 2))
            capture("\(action) Undo banner visible", in: app)
            let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: undo)
            XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 7), .completed)
            capture("\(action) Undo banner expired", in: app)
            if action == "Settle" { select("Settled", in: app) }
            if action == "Restore" { select("Inbox", in: app) }
        }
    }
}

final class BulkSelectionUITests: MailernUITestCase {
    @MainActor
    func testBulkSelection() {
        continueAfterFailure = false
        let app = TestApplication()
        app.launch()
        let first = "Course project feedback"
        let second = "Dinner on Saturday?"
        capture("Select is separate from Filter and Compose", in: app)
        app.buttons["Select"].tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", first)).firstMatch.tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", second)).firstMatch.tap()
        XCTAssertTrue(app.staticTexts["2 selected"].exists)
        capture("Bulk selection and native action bar", in: app)
        app.buttons["Settle"].tap()
        XCTAssertFalse(row(first, in: app).exists)
        XCTAssertFalse(row(second, in: app).exists)
        app.buttons["Undo"].tap()
        expectReadStatus(first, in: app)
        XCTAssertEqual(row(second, in: app).value as? String, "Read")
        app.buttons["Select"].tap()
        app.buttons["Select All"].tap()
        XCTAssertTrue(app.staticTexts["6 selected"].exists)
        app.buttons["Deselect All"].tap()
        XCTAssertTrue(app.staticTexts["0 selected"].exists)
        XCTAssertFalse(app.buttons["Settle"].isEnabled)
        row(first, in: app).tap()
        app.buttons["Select All"].tap()
        XCTAssertTrue(app.staticTexts["6 selected"].exists)
        XCTAssertTrue(app.buttons["Deselect All"].exists)
        capture("Select All toggles to Deselect All", in: app)
        app.buttons["Mark"].tap()
        app.buttons["Mark read"].tap()
        // Undo lasts five seconds, so the banner confirms each action and the rows are
        // checked after Undo.
        XCTAssertTrue(app.staticTexts["6 conversations: Marked read"].exists)
        app.buttons["Undo"].tap()
        expectReadStatus(first, in: app)
        app.buttons["Select"].tap()
        row(second, in: app).tap()
        app.buttons["Mark"].tap()
        XCTAssertTrue(app.buttons["Mark unread"].exists)
        XCTAssertFalse(app.buttons["Mark read"].exists)
        app.buttons["Mark unread"].tap()
        XCTAssertTrue(app.staticTexts["Marked unread"].exists)
        app.buttons["Undo"].tap()
        XCTAssertEqual(row(second, in: app).value as? String, "Read")
        app.buttons["Select"].tap()
        row(first, in: app).tap()
        app.buttons["Mark"].tap()
        XCTAssertTrue(app.buttons["Unpin"].exists)
        XCTAssertFalse(app.buttons["Pin"].exists)
        app.buttons["Unpin"].tap()
        XCTAssertFalse(row(first, in: app).label.contains("Pinned"))
        app.buttons["Undo"].tap()
        XCTAssertTrue(row(first, in: app).label.contains("Pinned"))
        app.buttons["Select"].tap()
        row(first, in: app).tap()
        row(second, in: app).tap()
        app.buttons["Mark"].tap()
        XCTAssertTrue(app.buttons["Mark read"].exists)
        XCTAssertFalse(app.buttons["Mark unread"].exists)
        XCTAssertTrue(app.buttons["Pin"].exists)
        XCTAssertFalse(app.buttons["Unpin"].exists)
        capture("Contextual batch actions for mixed selection", in: app)
        app.buttons["Pin"].tap()
        XCTAssertTrue(row(second, in: app).label.contains("Pinned"))
        app.buttons["Undo"].tap()
        XCTAssertFalse(row(second, in: app).label.contains("Pinned"))
        app.buttons["Select"].tap()
        row(first, in: app).tap()
        app.buttons["Snooze"].tap()
        app.navigationBars["Snooze"].buttons["Cancel"].tap()
        XCTAssertTrue(app.staticTexts["1 selected"].exists)
        app.buttons["Snooze"].tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "In ")).firstMatch.tap()
        XCTAssertFalse(row(first, in: app).exists)
        select("Snoozed", in: app)
        expectReadStatus(first, in: app)
        app.buttons["Select"].tap()
        app.buttons["Select All"].tap()
        app.buttons["Mark"].tap()
        app.buttons["Restore to Inbox"].tap()
        XCTAssertFalse(row(first, in: app).exists)
        select("Inbox", in: app)
        expectReadStatus(first, in: app)
        app.buttons["Select"].tap()
        app.buttons["Cancel"].tap()
        row(first, in: app).tap()
        XCTAssertTrue(app.navigationBars.buttons["Inbox"].existsOrWait(timeout: 5))
    }
}

final class FilteredBulkSelectionUITests: MailernUITestCase {
    @MainActor
    func testFilteredBulkSelection() {
        continueAfterFailure = false
        let app = TestApplication()
        app.launch()
        if !app.searchFields.firstMatch.isHittable { app.swipeDown() }
        XCTAssertTrue(app.searchFields.firstMatch.wait(for: \.isHittable, toEqual: true, timeout: 5))
        app.searchFields.firstMatch.tap()
        app.searchFields.firstMatch.typeText("Course project\n")
        app.buttons["Select"].tap()
        app.buttons["Select All"].tap()
        XCTAssertTrue(app.staticTexts["1 selected"].exists)
        capture("Filtered selection", in: app)
        app.buttons["Settle"].tap()
        app.buttons["Close"].tap()
        XCTAssertFalse(row("Course project feedback", in: app).exists)
        XCTAssertTrue(row("Dinner on Saturday?", in: app).exists)
        select("Settled", in: app)
        app.buttons["Select"].tap()
        row("Course project feedback", in: app).tap()
        app.buttons["Restore"].tap()
        select("Inbox", in: app)
        expectReadStatus("Course project feedback", unread: false, in: app)
    }
}

final class CustomSwipeActionsUITests: MailernUITestCase {
    @MainActor
    func testCustomSwipeActions() {
        continueAfterFailure = false
        let app = TestApplication()
        app.launch()
        func settings() {
            app.buttons["More"].tap()
            XCTAssertTrue(app.buttons["Settings"].wait(for: \.isHittable, toEqual: true, timeout: 5))
            app.buttons["Settings"].tap()
            XCTAssertTrue(app.navigationBars["Settings"].existsOrWait(timeout: 5))
            XCTAssertTrue(app.buttons["Swipe actions"].wait(for: \.isHittable, toEqual: true, timeout: 5))
            app.buttons["Swipe actions"].tap()
            XCTAssertTrue(app.navigationBars["Swipe actions"].existsOrWait(timeout: 5))
        }
        func choose(_ direction: String, _ action: String) {
            app.buttons["\(direction)-primary"].tap()
            app.buttons[action].tap()
        }
        func close() {
            app.navigationBars.buttons["Settings"].tap()
            app.buttons["Done"].tap()
        }
        settings()
        app.buttons["Reset Swipe Actions"].tap()
        choose("Swipe left", "Read / Unread")
        choose("Swipe right", "Settle / Restore")
        capture("Custom swipe settings", in: app)
        close()
        app.terminate()
        app.launch()
        let subject = "Course project feedback"
        fullSwipe(row(subject, in: app), right: false)
        XCTAssertEqual(row(subject, in: app).value as? String, "Read")
        fullSwipe(row(subject, in: app), right: true)
        waitForAbsence(row(subject, in: app))
        select("Settled", in: app)
        fullSwipe(row(subject, in: app), right: true)
        waitForAbsence(row(subject, in: app))
        select("Inbox", in: app)
        XCTAssertTrue(row(subject, in: app).existsOrWait(timeout: 5))
        settings()
        choose("Swipe left", "Snooze")
        // Choosing the additional action as primary removes the duplicate.
        XCTAssertTrue(app.buttons["Swipe left-secondary"].label.contains("None"))
        close()
        fullSwipe(row(subject, in: app), right: false)
        XCTAssertTrue(app.navigationBars["Snooze"].existsOrWait(timeout: 5))
        app.buttons["Cancel"].tap()
        settings()
        choose("Swipe left", "None")
        close()
        fullSwipe(row(subject, in: app), right: false)
        XCTAssertTrue(row(subject, in: app).exists)
        XCTAssertFalse(app.navigationBars["Snooze"].exists)
        XCTAssertTrue(app.navigationBars["Inbox"].exists)
        fullSwipe(row(subject, in: app), right: true)
        waitForAbsence(row(subject, in: app))
        settings()
        app.buttons["Reset Swipe Actions"].tap()
        close()
    }
}

final class FastReturnDoesNotComposeUITests: MailernUITestCase {
    @MainActor
    func testFastReturnDoesNotCompose() {
        continueAfterFailure = false
        let app = TestApplication()
        app.launchEnvironment["MAILERN_TEST_LARGE_INBOX"] = "1"
        app.launch()
        app.buttons["More"].tap()
        app.buttons["Settings"].tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Inbox pull-down")).firstMatch.tap()
        app.buttons["New email"].tap()
        app.buttons["Done"].tap()
        app.buttons["Compose"].tap()
        XCTAssertTrue(app.navigationBars["New Message"].existsOrWait(timeout: 5))
        app.buttons["Cancel"].tap()
        let list = app.collectionViews.firstMatch
        let initialTop = row("Course project feedback", in: app).frame.minY
        let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
        start.press(forDuration: 0.01, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -180)), withVelocity: .slow, thenHoldForDuration: 0.5)
        XCTAssertLessThan(row("Course project feedback", in: app).frame.minY, initialTop - 50)
        list.swipeDown(velocity: .fast)
        XCTAssertFalse(app.navigationBars["New Message"].exists, "Returning to the top must not compose")
    }
}

final class PullProgressAndReturnUITests: MailernUITestCase {
    @MainActor
    func testPullProgressAndReturn() {
        continueAfterFailure = false
        let app = TestApplication()
        app.launch()
        func setPull(_ title: String) {
            app.buttons["More"].tap()
            app.buttons["Settings"].tap()
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Inbox pull-down")).firstMatch.tap()
            app.buttons[title].tap()
            app.buttons["Done"].tap()
            waitForAbsence(app.navigationBars["Settings"])
        }
        for mode in ["Search", "New email"] {
            setPull(mode)
            let list = app.collectionViews.firstMatch
            let anchor = row("Course project feedback", in: app)
            let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
            start.press(forDuration: 0.01, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 65)), withVelocity: .slow, thenHoldForDuration: 0.7)
            XCTAssertFalse(app.buttons["Close"].exists)
            XCTAssertFalse(app.navigationBars["New Message"].exists)
            capture("\(mode) after short pull", in: app)
            // The navigation bar can expand after the pull, so wait for a stable position.
            var previousY: CGFloat?
            let returned = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                let y = anchor.frame.minY
                defer { previousY = y }
                return previousY.map { abs(y - $0) < 1 } == true
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [returned], timeout: 5), .completed)
            start.press(forDuration: 0.01, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 360)), withVelocity: .slow, thenHoldForDuration: 1)
            if mode == "Search" {
                XCTAssertTrue(app.buttons["Close"].existsOrWait(timeout: 5))
                app.buttons["Close"].tap()
            } else {
                XCTAssertTrue(app.navigationBars["New Message"].existsOrWait(timeout: 5))
                app.buttons["Cancel"].tap()
            }
        }
        setPull("Off")
    }
}

final class LabsInboxActionsAndBottomComposeUITests: MailernUITestCase {
    @MainActor
    func testLabsInboxActionsAndBottomCompose() {
        continueAfterFailure = false
        let app = TestApplication()
        app.launch()
        func settings() {
            app.buttons["More"].tap()
            app.buttons["Settings"].tap()
            XCTAssertTrue(app.navigationBars["Settings"].existsOrWait(timeout: 5))
        }
        func choosePull(_ title: String) {
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Inbox pull-down")).firstMatch.tap()
            app.buttons[title].tap()
        }
        func pull() {
            let start = app.collectionViews.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            start.press(forDuration: 0.01, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 420)), withVelocity: .slow, thenHoldForDuration: 0.5)
        }
        settings()
        app.buttons["Snooze settings"].tap()
        XCTAssertTrue(app.navigationBars["Snooze settings"].existsOrWait(timeout: 5))
        app.navigationBars.buttons["Settings"].tap()
        choosePull("Search")
        app.buttons["Done"].tap()
        pull()
        XCTAssertTrue(app.buttons["Close"].existsOrWait(timeout: 5))
        capture("Pull to search", in: app)
        app.searchFields.firstMatch.tap()
        app.searchFields.firstMatch.typeText("Course project")
        waitForAbsence(row("Dinner on Saturday?", in: app))
        app.buttons["Close"].tap()

        settings()
        choosePull("New email")
        capture("Labs settings", in: app)
        app.buttons["Done"].tap()
        XCTAssertGreaterThan(app.buttons["Compose"].frame.midY, app.frame.height * 0.7)
        XCTAssertTrue(app.tabBars.buttons["Inbox"].exists)
        XCTAssertTrue(app.tabBars.buttons["Snoozed"].exists)
        XCTAssertTrue(app.tabBars.buttons["Settled"].exists)
        XCTAssertTrue(app.tabBars.buttons["Compose"].exists)
        capture("Bottom compose", in: app)
        app.buttons["Compose"].tap()
        XCTAssertTrue(app.navigationBars["New Message"].existsOrWait(timeout: 5))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["Inbox"].existsOrWait(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["Inbox"].isSelected)
        app.buttons["Settled"].tap()
        XCTAssertTrue(app.navigationBars["Settled"].existsOrWait(timeout: 5))
        app.buttons["Inbox"].tap()
        pull()
        XCTAssertTrue(app.navigationBars["New Message"].existsOrWait(timeout: 5))
        app.buttons["Cancel"].tap()
        app.terminate()
        app.launch()
        XCTAssertGreaterThan(app.buttons["Compose"].frame.midY, app.frame.height * 0.7)
        settings()
        choosePull("Off")
        app.buttons["Done"].tap()
        XCTAssertTrue(app.tabBars.firstMatch.exists)
    }
}

final class PeekMenuTouchCancellationUITests: MailernUITestCase {
    @MainActor
    func testPeekMenuTouchCancellation() {
        continueAfterFailure = false
        let app = TestApplication()
        app.launch()
        let subject = "Course project feedback"
        peek(subject, in: app)
        let read = app.buttons["Mark read"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let outside = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: app.frame.maxX - 5, dy: app.buttons["Mark read"].frame.midY))
        read.press(forDuration: 0.8, thenDragTo: outside, withVelocity: .fast, thenHoldForDuration: 0.2)
        XCTAssertTrue(preview(in: app).exists)
        expectReadStatus(subject, in: app)
        capture("Menu after cancelled touch", in: app)
        app.buttons["Mark read"].tap()
        waitForAbsence(preview(in: app))
        XCTAssertEqual(row(subject, in: app).value as? String, "Read")
    }
}

final class PeekWorkflowPresentationUITests: MailernUITestCase {
    @MainActor
    func testPeekWorkflowPresentation() {
        continueAfterFailure = false
        let app = TestApplication()
        app.launch()
        let subject = "Course project feedback"

        peek(subject, in: app)
        app.buttons["Settle"].tap()
        waitForAbsence(preview(in: app))
        XCTAssertFalse(row(subject, in: app).exists)

        select("Settled", in: app)
        expectReadStatus(subject, unread: false, in: app)
        peek(subject, in: app)
        XCTAssertFalse(app.buttons["Settle"].exists)
        app.buttons["Restore to Inbox"].tap()
        waitForAbsence(preview(in: app))

        select("Inbox", in: app)
        expectReadStatus(subject, unread: false, in: app)
        XCTAssertFalse(preview(in: app).exists)
        peek(subject, in: app)
        app.buttons["Snooze"].tap()
        XCTAssertTrue(app.navigationBars["Snooze"].existsOrWait(timeout: 5))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(preview(in: app).existsOrWait(timeout: 5))
        expectReadStatus(subject, unread: false, in: app)

        confirmSnooze(in: app)
        XCTAssertFalse(row(subject, in: app).exists)
        select("Snoozed", in: app)
        expectReadStatus(subject, unread: false, in: app)
        XCTAssertFalse(preview(in: app).exists)

        peek(subject, in: app)
        XCTAssertTrue(app.buttons["Restore to Inbox"].exists)
        confirmSnooze(in: app)
        expectReadStatus(subject, unread: false, in: app)
        XCTAssertFalse(preview(in: app).exists)

        peek(subject, in: app)
        app.buttons["Settle"].tap()
        waitForAbsence(preview(in: app))
        select("Settled", in: app)
        expectReadStatus(subject, unread: false, in: app)
        peek(subject, in: app)
        confirmSnooze(in: app)
        select("Snoozed", in: app)
        expectReadStatus(subject, unread: false, in: app)
        XCTAssertFalse(preview(in: app).exists)
    }
}

final class PeekScrollTapAndReplyToolsUITests: MailernUITestCase {
    @MainActor
    func testPeekScrollTapAndReplyTools() {
        continueAfterFailure = false
        let app = TestApplication()
        app.launch()
        let subject = "Course project feedback"
        peek(subject, in: app)

        let card = preview(in: app)
        let replies = [app.buttons["Reply"], app.buttons["Reply All"], app.buttons["Forward"]]
        XCTAssertLessThan(abs(replies[0].frame.midY - replies[1].frame.midY), 2)
        XCTAssertLessThan(abs(replies[1].frame.midY - replies[2].frame.midY), 2)
        XCTAssertLessThan(replies[0].frame.midX, replies[1].frame.midX)
        XCTAssertLessThan(replies[1].frame.midX, replies[2].frame.midX)
        XCTAssertLessThan(card.frame.height, app.frame.height * 0.7)
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "Custom peek and separate tools"
        capture.lifetime = .deleteOnSuccess
        add(capture)

        let body = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Hi Morgan,")).firstMatch
        XCTAssertTrue(body.exists)
        let bodyTop = body.frame.minY
        card.swipeUp()
        XCTAssertTrue(card.exists)
        XCTAssertTrue(body.exists)
        XCTAssertLessThan(body.frame.minY, bodyTop - 30)
        expectReadStatus(subject, in: app)
        let scrolled = XCTAttachment(screenshot: app.screenshot())
        scrolled.name = "Scrolled peek"
        scrolled.lifetime = .deleteOnSuccess
        add(scrolled)
        card.tap()
        waitForAbsence(card)
        XCTAssertTrue(app.buttons["Reply"].existsOrWait(timeout: 5))
        app.navigationBars.buttons["Inbox"].tap()
        XCTAssertEqual(row(subject, in: app).value as? String, "Read")

        for (action, prefix) in [("Reply", "Re:"), ("Reply All", "Re:"), ("Forward", "Fwd:")] {
            let title = "\(prefix) \(subject)"
            peek(subject, in: app)
            app.buttons[action].tap()
            XCTAssertTrue(app.navigationBars[title].existsOrWait(timeout: 5))
            XCTAssertTrue(app.textFields.matching(NSPredicate(format: "value == %@", "\(prefix) \(subject)")).firstMatch.exists)
            if action == "Reply All" {
                app.buttons["Cc/Bcc, From"].tap()
                XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "Cc").firstMatch.value as? String, "coordinator@college.example.com")
            }
            app.buttons["Cancel"].tap()
            waitForAbsence(app.navigationBars[title])
            XCTAssertFalse(preview(in: app).exists)
        }

        peek(subject, in: app)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.5)).tap()
        waitForAbsence(preview(in: app))
        XCTAssertEqual(row(subject, in: app).value as? String, "Read")
    }
}

final class PeekReadPinAndMailboxGesturesUITests: MailernUITestCase {
    @MainActor
    func testPeekReadPinAndMailboxGestures() {
        continueAfterFailure = false
        let app = TestApplication()
        app.launch()
        let subject = "Course project feedback"

        peek(subject, in: app)
        app.buttons["Mark read"].tap()
        waitForAbsence(preview(in: app))
        XCTAssertEqual(row(subject, in: app).value as? String, "Read")
        peek(subject, in: app)
        app.buttons["Mark unread"].tap()
        waitForAbsence(preview(in: app))
        expectReadStatus(subject, in: app)

        peek(subject, in: app)
        app.buttons["Unpin"].tap()
        waitForAbsence(preview(in: app))
        expectReadStatus(subject, in: app)
        peek(subject, in: app)
        app.buttons["Pin"].tap()
        waitForAbsence(preview(in: app))
        expectReadStatus(subject, in: app)
        peek(subject, in: app)
        XCTAssertTrue(app.buttons["Unpin"].exists)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.5)).tap()
        waitForAbsence(preview(in: app))

        row(subject, in: app).tap()
        XCTAssertTrue(app.buttons["Reply"].existsOrWait(timeout: 5))
        app.navigationBars.buttons["Inbox"].tap()
        XCTAssertEqual(row(subject, in: app).value as? String, "Read")
        fullSwipe(row(subject, in: app), right: true)
        expectReadStatus(subject, in: app)
        fullSwipe(row(subject, in: app), right: false)
        waitForAbsence(row(subject, in: app))
        select("Settled", in: app)
        // Settling marks a conversation read.
        XCTAssertEqual(row(subject, in: app).value as? String, "Read")

        select("Inbox", in: app)
        let thread = "Dinner on Saturday?"
        for _ in 0..<3 where !row(thread, in: app).isHittable { app.swipeUp() }
        peek(thread, in: app)
        XCTAssertEqual(preview(in: app).value as? String, "Read")
        XCTAssertTrue(app.staticTexts["· 3 messages"].exists)
        XCTAssertTrue(app.staticTexts["2 earlier messages"].exists)
        let latest = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Around 7?")).firstMatch
        XCTAssertTrue(latest.exists)
        for _ in 0..<4 where !preview(in: app).frame.contains(latest.frame) { preview(in: app).swipeUp() }
        XCTAssertGreaterThan(latest.frame.width, 0)
        XCTAssertTrue(preview(in: app).frame.contains(latest.frame))
        XCTAssertEqual(preview(in: app).value as? String, "Read")
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "Multi-message peek"
        capture.lifetime = .deleteOnSuccess
        add(capture)
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
        XCTAssertLessThan(compactHeight, app.frame.height * 0.7)
        for title in ["Mark read", "Settle", "Snooze", "Unpin"] {
            XCTAssertTrue(app.frame.contains(app.buttons[title].frame))
        }
        capture("Compact peek by default", in: app)
        dragMenu(280, in: app)
        let largeHeight = card.frame.height
        XCTAssertGreaterThan(largeHeight, app.frame.height * 0.7)
        XCTAssertGreaterThan(largeHeight, compactHeight + 100)
        capture("Tall peek", in: app)
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
        XCTAssertEqual(card.frame.height, compactHeight, accuracy: 2)
        XCTAssertFalse(app.navigationBars["Re: \(subject)"].exists)
        expectReadStatus(subject, in: app)
        capture("Apple Mail style tools", in: app)
        card.swipeUp()
        XCTAssertEqual(card.frame.height, compactHeight, accuracy: 2)
        expectReadStatus(subject, in: app)

        dragMenu(280, in: app)
        XCTAssertGreaterThan(card.frame.height, compactHeight + 100)
        expectReadStatus(subject, in: app)
        dragMenu(-280, in: app)
        XCTAssertEqual(card.frame.height, compactHeight, accuracy: 2)
        dragMenu(280, in: app)
        // Reply shortcuts remain usable before revealing the other tools.
        app.buttons["Forward"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.navigationBars["Fwd: \(subject)"].existsOrWait(timeout: 5))
        app.buttons["Cancel"].tap()
        waitForAbsence(app.navigationBars["Fwd: \(subject)"])
        expectReadStatus(subject, in: app)

        peek(subject, in: app)
        app.buttons["Mark read"].tap()
        waitForAbsence(preview(in: app))
        XCTAssertEqual(row(subject, in: app).value as? String, "Read")
    }
}

class MailernUITestCase: XCTestCase {
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
        let start = app.buttons["Reply"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
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
    func capture(_ name: String, in app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .deleteOnSuccess
        add(attachment)
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
    func saveNewDraft(_ subject: String, in app: XCUIApplication) {
        app.buttons["Compose"].tap()
        XCTAssertTrue(app.navigationBars["New Message"].existsOrWait(timeout: 5))
        app.textFields["Subject"].tap(); app.textFields["Subject"].typeText(subject)
        app.textViews["Message body"].tap(); app.textViews["Message body"].typeText("Draft workflow proof")
        app.buttons["Cancel"].tap(); app.buttons["Save Draft"].tap()
        XCTAssertTrue(row(subject, in: app).existsOrWait(timeout: 5))
    }

    @MainActor
    func saveReplyDraft(_ subject: String, in app: XCUIApplication) {
        row(subject, in: app).tap()
        app.buttons["Reply"].tap(); app.buttons["Reply All"].tap()
        XCTAssertTrue(app.navigationBars["Re: \(subject)"].existsOrWait(timeout: 5))
        enterText("Draft workflow proof\n", in: app.textViews["Message body"])
        app.buttons["Cancel"].tap(); app.buttons["Save Draft"].tap()
        app.navigationBars.buttons["Inbox"].tap()
        XCTAssertTrue(row(subject, in: app).label.contains("Draft"))
    }

    @MainActor
    func resetDemo(in app: XCUIApplication) {
        app.terminate()
        app.launchEnvironment["MAILERN_TEST_RESET_MAIL"] = "1"
        app.launch()
        app.launchEnvironment.removeValue(forKey: "MAILERN_TEST_RESET_MAIL")
        XCTAssertTrue(row("Course project feedback", in: app).existsOrWait(timeout: 5))
    }

    @MainActor
    func openDraft(_ subject: String, in app: XCUIApplication) {
        select("Inbox", in: app)
        row(subject, in: app).tap()
        XCTAssertTrue(app.buttons["Edit draft"].existsOrWait(timeout: 5))
        app.buttons["Edit draft"].tap()
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
    func confirmSnooze(in app: XCUIApplication) {
        app.buttons["Snooze"].tap()
        XCTAssertTrue(app.navigationBars["Snooze"].existsOrWait(timeout: 5))
        let option = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "In ")).firstMatch
        XCTAssertTrue(option.existsOrWait(timeout: 5))
        option.tap()
        waitForAbsence(app.navigationBars["Snooze"])
        waitForAbsence(preview(in: app))
    }

    @MainActor
    func waitForAbsence(_ element: XCUIElement) {
        XCTAssertTrue(!element.exists || element.waitForNonExistence(timeout: 5))
    }
}

private extension XCUIElement {
    @MainActor
    func existsOrWait(timeout: TimeInterval) -> Bool {
        // Most elements already exist after XCTest's idle wait.
        exists || waitForExistence(timeout: timeout)
    }
}
