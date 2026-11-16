import XCTest
import UIKit

final class MailernUITests: XCTestCase {
    @MainActor
    func testInboxDraftPreviewEditAndDiscard() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        resetDemo(in: app)
        let subject = "Inbox draft proof"
        app.buttons["Compose"].tap()
        XCTAssertTrue(app.navigationBars["New Message"].waitForExistence(timeout: 5))
        app.textFields["Subject"].tap(); app.textFields["Subject"].typeText(subject)
        app.textViews["Message body"].tap(); app.textViews["Message body"].typeText("An unfinished new message")
        app.buttons["Cancel"].tap(); app.buttons["Save Draft"].tap()
        XCTAssertTrue(row(subject, in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(row(subject, in: app).label.contains("Draft"))
        capture("After - new draft in Inbox", in: app)
        app.terminate(); app.launch()
        row(subject, in: app).tap()
        XCTAssertTrue(app.buttons["Edit draft"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.textViews["Message body"].exists)
        capture("After - standalone draft reader", in: app)
        app.buttons["Edit draft"].tap()
        XCTAssertEqual(app.textViews["Message body"].value as? String, "An unfinished new message")
        app.textViews["Message body"].typeText(" with an edit")
        app.buttons["Cancel"].tap(); app.buttons["Save Draft"].tap()
        XCTAssertTrue(app.buttons["Discard draft"].waitForExistence(timeout: 5))
        app.buttons["Discard draft"].tap()
        XCTAssertTrue(app.buttons["Compose"].waitForExistence(timeout: 5))
        XCTAssertFalse(row(subject, in: app).exists)

        let source = "Course project feedback"
        row(source, in: app).tap()
        app.buttons["Reply"].tap(); app.buttons["Reply All"].tap()
        XCTAssertTrue(app.navigationBars["Re: \(source)"].waitForExistence(timeout: 5))
        app.textViews["Message body"].typeText("An unfinished reply\n")
        app.buttons["Cancel"].tap(); app.buttons["Save Draft"].tap()
        XCTAssertTrue(app.buttons["Edit draft"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Edit draft"].isHittable)
        capture("After - reply draft at bottom of thread", in: app)
        app.navigationBars.buttons["Inbox"].tap()
        XCTAssertTrue(row(source, in: app).label.contains("Draft"))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", source)).count, 1)
        capture("After - reply draft attached to Inbox row", in: app)
        row(source, in: app).tap()
        XCTAssertTrue(app.buttons["Edit draft"].waitForExistence(timeout: 5))
        app.buttons["Discard draft"].tap()
        waitForAbsence(app.buttons["Edit draft"])
        app.navigationBars.buttons["Inbox"].tap()
        XCTAssertFalse(row(source, in: app).label.contains("Draft"))
    }

    @MainActor
    func testSettledReplyDraftReturnsToInboxAndSends() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        resetDemo(in: app)
        let subject = "Course project feedback"
        row(subject, in: app).tap(); app.buttons["Settle"].tap()
        select("Settled", in: app)
        row(subject, in: app).tap()
        app.buttons["Reply"].tap(); app.buttons["Reply All"].tap()
        XCTAssertTrue(app.navigationBars["Re: \(subject)"].waitForExistence(timeout: 5))
        app.textViews["Message body"].typeText("Reply draft send proof\n")
        app.buttons["Cancel"].tap(); app.buttons["Save Draft"].tap()
        app.navigationBars.buttons["Settled"].tap()
        XCTAssertFalse(app.buttons["Undo"].exists)
        XCTAssertFalse(row(subject, in: app).exists)
        select("Inbox", in: app)
        XCTAssertTrue(row(subject, in: app).label.contains("Draft"))
        row(subject, in: app).tap()
        app.buttons["Edit draft"].tap()
        XCTAssertTrue((app.textViews["Message body"].value as? String ?? "").hasPrefix("Reply draft send proof"))
        app.buttons["Send"].tap()
        waitForAbsence(app.navigationBars["Re: \(subject)"])
        XCTAssertFalse(app.buttons["Edit draft"].exists)
        app.navigationBars.buttons["Inbox"].tap()
        XCTAssertFalse(row(subject, in: app).exists)
        select("Settled", in: app)
        XCTAssertTrue(row(subject, in: app).exists)
        XCTAssertFalse(row(subject, in: app).label.contains("Draft"))
        capture("After - sent reply in Settled", in: app)
    }

    @MainActor
    func testThreadActionsReplaceMailboxTabs() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        resetDemo(in: app)
        for bottomEnabled in [true, false] {
            app.buttons["More"].tap()
            app.buttons["Settings"].tap()
            let bottom = app.switches["Compose at bottom right"]
            if (bottom.value as? String == "1") != bottomEnabled {
                bottom.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
            }
            app.buttons["Done"].tap()
            row("Course project feedback", in: app).tap()
            XCTAssertTrue(app.buttons["More actions"].waitForExistence(timeout: 5))
            capture("Thread actions without mailbox tabs, bottom Compose \(bottomEnabled)", in: app)
            XCTAssertFalse(app.tabBars.buttons["Inbox"].isHittable)
            XCTAssertFalse(app.buttons["Compose"].isHittable)
            XCTAssertTrue(app.buttons["Settle"].isHittable)
            XCTAssertTrue(app.buttons["Snooze"].isHittable)
            app.buttons["Reply"].tap()
            XCTAssertTrue(app.buttons["Reply All"].waitForExistence(timeout: 5))
            app.buttons["Reply All"].tap()
            XCTAssertTrue(app.navigationBars["Re: Course project feedback"].waitForExistence(timeout: 5))
            app.textViews["Message body"].typeText("Thread action check\n")
            app.buttons["Cancel"].tap()
            app.buttons["Delete Draft"].tap()
            app.navigationBars.buttons["Inbox"].tap()
            XCTAssertTrue(app.tabBars.buttons["Inbox"].isHittable)
            XCTAssertTrue(app.buttons["Compose"].isHittable)
        }
    }

    @MainActor
    func testAllReadStatusKeepsRowsInPlace() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        resetDemo(in: app)
        app.buttons["Select"].tap()
        app.buttons["Select All"].tap()
        app.buttons["Mark"].tap()
        app.buttons["Mark read"].tap()
        XCTAssertTrue(app.staticTexts["All read"].waitForExistence(timeout: 5))
        let subject = "Course project feedback"
        let before = row(subject, in: app).frame.minY
        capture("All read keeps the status row", in: app)
        peek(subject, in: app)
        app.buttons["Mark unread"].tap()
        XCTAssertTrue(app.staticTexts["1 unread"].waitForExistence(timeout: 5))
        XCTAssertEqual(row(subject, in: app).frame.minY, before, accuracy: 2)
        peek(subject, in: app)
        app.buttons["Mark read"].tap()
        XCTAssertTrue(app.staticTexts["All read"].waitForExistence(timeout: 5))
        XCTAssertEqual(row(subject, in: app).frame.minY, before, accuracy: 2)
        capture("Last unread toggle preserves row position", in: app)
    }

    @MainActor
    func testFormattingKeepsSelectionAbovePanel() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        app.buttons["Compose"].tap()
        XCTAssertTrue(app.navigationBars["New Message"].waitForExistence(timeout: 5))
        let body = app.textViews["Message body"]
        body.tap()
        body.typeText("Select this text to format")
        app.buttons["Format"].tap()
        let close = app.buttons["close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
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
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.buttons["Format"].tap()
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        app.textFields["Subject"].tap()
        waitForAbsence(close)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        body.tap()
        app.buttons["Format"].tap()
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        app.descendants(matching: .any).matching(identifier: "To").firstMatch.tap()
        capture("Recipient focus closes Format", in: app)
        waitForAbsence(close)
        app.buttons["Cancel"].tap()
        app.buttons["Delete Draft"].tap()
    }

    @MainActor
    func testComposePreservesRevealedSearchPosition() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        resetDemo(in: app)
        app.buttons["More"].tap()
        app.buttons["Settings"].tap()
        let bottom = app.switches["Compose at bottom right"]
        if bottom.value as? String != "1" { bottom.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap() }
        app.buttons["Done"].tap()
        app.buttons["Compose"].tap()
        XCTAssertTrue(app.navigationBars["New Message"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        select("Snoozed", in: app)
        XCTAssertTrue(app.navigationBars["Snoozed"].waitForExistence(timeout: 5))
        app.buttons["Compose"].tap()
        XCTAssertTrue(app.navigationBars["New Message"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.tabBars.buttons["Snoozed"].isSelected)
        select("Inbox", in: app)
        let list = app.collectionViews.firstMatch
        list.swipeDown(velocity: .slow)
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        let before = search.frame
        capture("Revealed search before Compose", in: app)
        app.buttons["Compose"].tap()
        XCTAssertTrue(app.navigationBars["New Message"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        capture("Revealed search after Compose", in: app)
        XCTAssertEqual(search.frame.minY, before.minY, accuracy: 2)
    }

    private func containsSamplePhoto(_ image: UIImage) -> Bool {
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
    func testComposerRevertedHeadersPersistAndStayProtected() {
        continueAfterFailure = false
        let app = XCUIApplication()
        for failure in [false, true] {
            let original = "Header \(UUID().uuidString.prefix(6))"
            app.launchEnvironment = failure ? ["MAILERN_TEST_DRAFT_REVERT_SUBJECT": original] : [:]
            app.launch()
            app.buttons["Compose"].tap()
            XCTAssertTrue(app.navigationBars["New Message"].waitForExistence(timeout: 5))
            app.textFields["Subject"].tap(); app.textFields["Subject"].typeText(original)
            capture("Native subject field", in: app)
            app.buttons["Cancel"].tap(); app.buttons["Save Draft"].tap()
            openDraft(original, in: app)
            XCTAssertTrue(app.navigationBars[original].waitForExistence(timeout: 5))
            let subject = app.textFields["Subject"]
            subject.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
            subject.typeText(" changed")
            XCTAssertEqual(subject.value as? String, original + " changed")
            Thread.sleep(forTimeInterval: 0.6) // Cross the autosave debounce before reverting.
            subject.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
            subject.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 8))
            XCTAssertEqual(subject.value as? String, original)
            if failure {
                XCTAssertTrue(app.alerts["Composer"].waitForExistence(timeout: 5))
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
                XCTAssertTrue(app.navigationBars[original + " changed"].waitForExistence(timeout: 5))
            } else {
                waitForAbsence(app.navigationBars[original])
                app.buttons["Edit draft"].tap()
                XCTAssertTrue(app.navigationBars[original].waitForExistence(timeout: 5))
                XCTAssertEqual(app.textFields["Subject"].value as? String, original)
            }
            app.buttons["Cancel"].tap(); app.buttons["Delete Draft"].tap()
            app.terminate()
        }
    }

    @MainActor
    func testComposerCleanupFailureClosesAfterAcknowledgement() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["MAILERN_TEST_DRAFT_DELETE_FAILURE"] = "1"
        app.launch()
        let subject = "Sent cleanup \(UUID().uuidString.prefix(6))"
        app.buttons["Compose"].tap()
        XCTAssertTrue(app.navigationBars["New Message"].waitForExistence(timeout: 5))
        let to = app.descendants(matching: .any).matching(identifier: "To").firstMatch
        to.tap(); to.typeText("recipient@example.com")
        app.textFields["Subject"].tap(); app.textFields["Subject"].typeText(subject)
        app.textViews["Message body"].tap(); app.textViews["Message body"].typeText("Sent once")
        app.buttons["Send"].tap()
        XCTAssertTrue(app.alerts["Composer"].waitForExistence(timeout: 5))
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
        XCTAssertTrue(app.navigationBars[subject].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap(); app.buttons["Delete Draft"].tap()
    }

    @MainActor
    func testComposerDraftSaveFailureKeepsEditor() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let subject = "Draft recovery \(UUID().uuidString.prefix(6))"
        app.buttons["Compose"].tap()
        XCTAssertTrue(app.navigationBars["New Message"].waitForExistence(timeout: 5))
        app.textFields["Subject"].tap(); app.textFields["Subject"].typeText(subject)
        app.textViews["Message body"].tap(); app.textViews["Message body"].typeText("Original text")
        app.buttons["Cancel"].tap(); app.buttons["Save Draft"].tap()
        app.terminate()
        app.launchEnvironment["MAILERN_TEST_DRAFT_WRITE_FAILURE"] = "1"
        app.launch()
        func acknowledgeFailedSave() {
            XCTAssertTrue(app.alerts["Composer"].waitForExistence(timeout: 5))
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
        XCTAssertTrue(app.navigationBars["New Message"].waitForExistence(timeout: 5))
        app.textFields["Subject"].tap(); app.textFields["Subject"].typeText("Unsaved failure proof")
        acknowledgeFailedSave()
        app.textViews["Message body"].tap(); app.textViews["Message body"].typeText("Keep these new edits")
        blockedSwipe(title: "Unsaved failure proof")
        app.buttons["Cancel"].tap(); app.buttons["Delete Draft"].tap()
        openDraft(subject, in: app)
        XCTAssertTrue(app.navigationBars[subject].waitForExistence(timeout: 5))
        app.textViews["Message body"].tap()
        app.textViews["Message body"].typeText("Changed ")
        blockedSwipe(title: subject)
        app.terminate()
        app.launchEnvironment = [:]
        app.launch()
        openDraft(subject, in: app)
        XCTAssertTrue(app.navigationBars[subject].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textViews["Message body"].value as? String, "Original text")
        app.buttons["Cancel"].tap(); app.buttons["Delete Draft"].tap()
    }

    @MainActor
    func testComposerPhotoAttachment() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        app.buttons["Compose"].tap()
        XCTAssertTrue(app.navigationBars["New Message"].waitForExistence(timeout: 5))
        let to = app.descendants(matching: .any).matching(identifier: "To").firstMatch
        to.tap(); to.typeText("recipient@example.com")
        app.textFields["Subject"].tap(); app.textFields["Subject"].typeText("Photo proof")
        app.textViews["Message body"].tap(); app.textViews["Message body"].typeText("See the photo.")
        app.buttons["Attach"].tap(); app.buttons["Photo Library"].tap()
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 10))
        let photo = app.images.matching(NSPredicate(format: "label BEGINSWITH %@", "Photo,")).firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 30))
        capture("Native photo picker", in: app)
        photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        app.buttons["Add"].tap()
        let preview = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Preview Photo-")).firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        capture("Photo attached to draft", in: app)
        preview.tap()
        XCTAssertTrue(app.buttons["QLOverlayDoneButtonAccessibilityIdentifier"].waitForExistence(timeout: 5))
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
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Preview Photo-")).firstMatch.waitForExistence(timeout: 5))
    }

    @MainActor
    func testComposerFileAttachment() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        app.buttons["Compose"].tap()
        XCTAssertTrue(app.navigationBars["New Message"].waitForExistence(timeout: 5))
        let to = app.descendants(matching: .any).matching(identifier: "To").firstMatch
        to.tap(); to.typeText("recipient@example.com")
        app.textFields["Subject"].tap(); app.textFields["Subject"].typeText("Attachment proof")
        app.textViews["Message body"].tap()
        app.textViews["Message body"].typeText("See attached.")
        app.buttons["Attach"].tap()
        capture("Native attachment menu", in: app)
        app.buttons["Attach File"].tap()
        XCTAssertTrue(app.buttons.matching(identifier: "Browse").firstMatch.waitForExistence(timeout: 10))
        app.buttons.matching(identifier: "Browse").firstMatch.tap()
        let local = app.descendants(matching: .any).matching(identifier: "On My iPhone").firstMatch
        if !local.exists { app.buttons.matching(identifier: "Browse").firstMatch.tap() }
        XCTAssertTrue(local.waitForExistence(timeout: 5))
        local.tap()
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@ AND elementType != 2", "Mailern")).firstMatch.tap()
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Sample attachment")).firstMatch.tap()
        app.buttons["Open"].tap()
        let preview = app.buttons["Preview Sample attachment.txt"]
        capture("File picker after Open", in: app)
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        capture("Imported real file attachment", in: app)
        preview.tap()
        XCTAssertTrue(app.buttons["QLOverlayDoneButtonAccessibilityIdentifier"].waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 15) // Allow the native remote preview to finish loading on Simulator.
        capture("Native attachment preview", in: app)
        closeQuickLook(in: app)
        app.buttons["Send"].tap()
        waitForAbsence(app.navigationBars["Attachment proof"])
        select("Settled", in: app)
        row("Attachment proof", in: app).tap()
        XCTAssertTrue(app.buttons["Preview Sample attachment.txt"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testComposerFormattingDraftAndSend() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        resetDemo(in: app)
        app.buttons["Compose"].tap()
        XCTAssertTrue(app.navigationBars["New Message"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
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
        XCTAssertTrue(bold.waitForExistence(timeout: 5))
        bold.tap()
        app.buttons["close"].tap()
        body.typeText("formatted world")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["Save Draft"].waitForExistence(timeout: 5))
        capture("Native Save and Delete Draft menu", in: app)
        app.buttons["Save Draft"].tap()
        app.terminate()
        app.launch()
        openDraft("Composer proof", in: app)
        XCTAssertTrue(app.navigationBars["Composer proof"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textViews["Message body"].value as? String, "Hello formatted world")
        app.buttons["Send"].tap()
        waitForAbsence(app.navigationBars["Composer proof"])
        select("Settled", in: app)
        XCTAssertTrue(row("Composer proof", in: app).exists)
        row("Composer proof", in: app).tap()
        capture("Sent formatted message", in: app)
    }

    @MainActor
    func testComposerReplyAndForwardSend() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        resetDemo(in: app)
        let subject = "Course project feedback"
        peek(subject, in: app)
        app.buttons["Reply All"].tap()
        XCTAssertTrue(app.navigationBars["Re: \(subject)"].waitForExistence(timeout: 5))
        XCTAssertTrue((app.textViews["Message body"].value as? String ?? "").contains("Jordan"))
        app.textViews["Message body"].typeText("Thanks. Here is my update.\n")
        XCTAssertTrue((app.textViews["Message body"].value as? String ?? "").hasPrefix("Thanks. Here is my update."))
        capture("Reply with editable quoted original", in: app)
        app.buttons["Send"].tap()
        waitForAbsence(app.navigationBars["Re: \(subject)"])
        XCTAssertFalse(row(subject, in: app).exists)
        select("Settled", in: app)
        XCTAssertTrue(row(subject, in: app).exists)
        row(subject, in: app).tap()
        XCTAssertTrue(app.textViews.matching(NSPredicate(format: "value CONTAINS %@", "Thanks. Here is my update.")).firstMatch.waitForExistence(timeout: 5))
        app.navigationBars.buttons["Settled"].tap()
        select("Inbox", in: app)
        resetDemo(in: app)
        peek(subject, in: app)
        app.buttons["Forward"].tap()
        XCTAssertTrue(app.navigationBars["Fwd: \(subject)"].waitForExistence(timeout: 5))
        let to = app.descendants(matching: .any).matching(identifier: "To").firstMatch
        to.tap(); to.typeText("recipient@example.com")
        app.buttons["Send"].tap()
        waitForAbsence(app.navigationBars["Fwd: \(subject)"])
        XCTAssertTrue(row(subject, in: app).exists)
        select("Settled", in: app)
        XCTAssertTrue(row("Fwd: \(subject)", in: app).exists)
    }

    @MainActor
    func testComposerSwipeSavesDraft() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        app.buttons["More"].tap()
        app.buttons["Settings"].tap()
        let bottom = app.switches["Compose at bottom right"]
        if bottom.value as? String != "1" { bottom.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap() }
        app.buttons["Done"].tap()
        XCTAssertTrue(app.tabBars.buttons["Compose"].exists)
        app.buttons["Compose"].tap()
        XCTAssertTrue(app.navigationBars["New Message"].waitForExistence(timeout: 5))
        app.textFields["Subject"].tap()
        app.textFields["Subject"].typeText("Swipe draft proof")
        let grabber = app.buttons["Sheet Grabber"].firstMatch
        XCTAssertTrue(grabber.exists)
        grabber.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)), withVelocity: .slow, thenHoldForDuration: 0.1)
        waitForAbsence(app.navigationBars["Swipe draft proof"])
        openDraft("Swipe draft proof", in: app)
        XCTAssertTrue(app.navigationBars["Swipe draft proof"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        app.buttons["Delete Draft"].tap()
        waitForAbsence(app.navigationBars["Swipe draft proof"])
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Swipe draft proof")).firstMatch.exists)
        app.buttons["More"].tap()
        app.buttons["Settings"].tap()
        bottom.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        app.buttons["Done"].tap()
    }

    @MainActor
    func testBulkSelection() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        resetDemo(in: app)
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
        expectUnread(first, in: app)
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
        XCTAssertEqual(row(first, in: app).value as? String, "Read")
        app.buttons["Undo"].tap()
        expectUnread(first, in: app)
        app.buttons["Select"].tap()
        row(second, in: app).tap()
        app.buttons["Mark"].tap()
        XCTAssertTrue(app.buttons["Mark unread"].exists)
        XCTAssertFalse(app.buttons["Mark read"].exists)
        app.buttons["Mark unread"].tap()
        expectUnread(second, in: app)
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
        expectUnread(first, in: app)
        app.buttons["Select"].tap()
        app.buttons["Select All"].tap()
        app.buttons["Mark"].tap()
        app.buttons["Restore to Inbox"].tap()
        XCTAssertFalse(row(first, in: app).exists)
        select("Inbox", in: app)
        expectUnread(first, in: app)
        app.buttons["Select"].tap()
        app.buttons["Cancel"].tap()
        row(first, in: app).tap()
        XCTAssertTrue(app.navigationBars.buttons["Inbox"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testFilteredBulkSelection() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        resetDemo(in: app)
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
        expectUnread("Course project feedback", in: app)
    }

    @MainActor
    func testCustomSwipeActions() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        resetDemo(in: app)
        func settings() {
            app.buttons["More"].tap()
            app.buttons["Settings"].tap()
            app.buttons["Swipe actions"].tap()
            XCTAssertTrue(app.navigationBars["Swipe actions"].waitForExistence(timeout: 5))
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
        XCTAssertTrue(row(subject, in: app).waitForExistence(timeout: 5))
        settings()
        choose("Swipe left", "Snooze")
        // Choosing the additional action as primary removes the duplicate.
        XCTAssertTrue(app.buttons["Swipe left-secondary"].label.contains("None"))
        close()
        fullSwipe(row(subject, in: app), right: false)
        XCTAssertTrue(app.navigationBars["Snooze"].waitForExistence(timeout: 5))
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

    @MainActor
    func testFastReturnDoesNotCompose() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        resetDemo(in: app)
        app.buttons["More"].tap()
        app.buttons["Settings"].tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Inbox pull-down")).firstMatch.tap()
        app.buttons["New email"].tap()
        if app.switches["Compose at bottom right"].value as? String == "1" {
            app.switches["Compose at bottom right"].coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        }
        app.buttons["Done"].tap()
        app.buttons["Compose"].tap()
        XCTAssertTrue(app.navigationBars["New Message"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        let list = app.collectionViews.firstMatch
        let initialTop = row("Course project feedback", in: app).frame.minY
        let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
        start.press(forDuration: 0.01, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -180)), withVelocity: .slow, thenHoldForDuration: 0.5)
        XCTAssertLessThan(row("Course project feedback", in: app).frame.minY, initialTop - 50)
        list.swipeDown(velocity: .fast)
        XCTAssertFalse(app.navigationBars["New Message"].exists, "Returning to the top must not compose")
    }

    @MainActor
    func testPullProgressAndReturn() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        resetDemo(in: app)
        func setPull(_ title: String) {
            app.buttons["More"].tap()
            app.buttons["Settings"].tap()
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Inbox pull-down")).firstMatch.tap()
            app.buttons[title].tap()
            app.buttons["Done"].tap()
        }
        for mode in ["Search", "New email"] {
            setPull(mode)
            let list = app.collectionViews.firstMatch
            let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
            start.press(forDuration: 0.01, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 65)), withVelocity: .slow, thenHoldForDuration: 0.7)
            XCTAssertFalse(app.buttons["Close"].exists)
            XCTAssertFalse(app.navigationBars["New Message"].exists)
            capture("\(mode) after short pull", in: app)
            start.press(forDuration: 0.01, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 360)), withVelocity: .slow, thenHoldForDuration: 1)
            if mode == "Search" {
                XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 5))
                app.buttons["Close"].tap()
            } else {
                XCTAssertTrue(app.navigationBars["New Message"].waitForExistence(timeout: 5))
                app.buttons["Cancel"].tap()
            }
        }
        setPull("Off")
    }

    @MainActor
    func testLabsInboxActionsAndBottomCompose() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        resetDemo(in: app)
        func settings() {
            app.buttons["More"].tap()
            app.buttons["Settings"].tap()
            XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
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
        XCTAssertTrue(app.navigationBars["Snooze settings"].waitForExistence(timeout: 5))
        app.navigationBars.buttons["Settings"].tap()
        choosePull("Search")
        app.buttons["Done"].tap()
        pull()
        XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 5))
        capture("Pull to search", in: app)
        app.searchFields.firstMatch.tap()
        app.searchFields.firstMatch.typeText("Course project")
        waitForAbsence(row("Dinner on Saturday?", in: app))
        app.buttons["Close"].tap()

        settings()
        choosePull("New email")
        if app.switches["Compose at bottom right"].value as? String != "1" {
            app.switches["Compose at bottom right"].coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        }
        XCTAssertEqual(app.switches["Compose at bottom right"].value as? String, "1")
        capture("Labs settings", in: app)
        app.buttons["Done"].tap()
        XCTAssertGreaterThan(app.buttons["Compose"].frame.midY, app.frame.height * 0.7)
        XCTAssertTrue(app.tabBars.buttons["Inbox"].exists)
        XCTAssertTrue(app.tabBars.buttons["Snoozed"].exists)
        XCTAssertTrue(app.tabBars.buttons["Settled"].exists)
        XCTAssertTrue(app.tabBars.buttons["Compose"].exists)
        capture("Bottom compose", in: app)
        app.buttons["Compose"].tap()
        XCTAssertTrue(app.navigationBars["New Message"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["Inbox"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["Inbox"].isSelected)
        app.buttons["Settled"].tap()
        XCTAssertTrue(app.navigationBars["Settled"].waitForExistence(timeout: 5))
        app.buttons["Inbox"].tap()
        pull()
        XCTAssertTrue(app.navigationBars["New Message"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        app.terminate()
        app.launch()
        XCTAssertGreaterThan(app.buttons["Compose"].frame.midY, app.frame.height * 0.7)
        settings()
        XCTAssertEqual(app.switches["Compose at bottom right"].value as? String, "1")
        choosePull("Off")
        app.switches["Compose at bottom right"].coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        app.buttons["Done"].tap()
        XCTAssertTrue(app.tabBars.firstMatch.exists)
    }

    @MainActor
    func testPeekMenuTouchCancellation() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        resetDemo(in: app)
        let subject = "Course project feedback"
        peek(subject, in: app)
        let read = app.buttons["Mark read"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let outside = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: app.frame.maxX - 5, dy: app.buttons["Mark read"].frame.midY))
        read.press(forDuration: 0.8, thenDragTo: outside, withVelocity: .fast, thenHoldForDuration: 0.2)
        XCTAssertTrue(preview(in: app).exists)
        expectUnread(subject, in: app)
        capture("Menu after cancelled touch", in: app)
        app.buttons["Mark read"].tap()
        waitForAbsence(preview(in: app))
        XCTAssertEqual(row(subject, in: app).value as? String, "Read")
    }

    @MainActor
    func testPeekWorkflowPresentation() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        resetDemo(in: app)
        let subject = "Course project feedback"

        peek(subject, in: app)
        app.buttons["Settle"].tap()
        waitForAbsence(preview(in: app))
        XCTAssertFalse(row(subject, in: app).exists)

        select("Settled", in: app)
        expectUnread(subject, in: app)
        peek(subject, in: app)
        XCTAssertFalse(app.buttons["Settle"].exists)
        app.buttons["Restore to Inbox"].tap()
        waitForAbsence(preview(in: app))

        select("Inbox", in: app)
        expectUnread(subject, in: app)
        XCTAssertFalse(preview(in: app).exists)
        peek(subject, in: app)
        app.buttons["Snooze"].tap()
        XCTAssertTrue(app.navigationBars["Snooze"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(preview(in: app).waitForExistence(timeout: 5))
        expectUnread(subject, in: app)

        confirmSnooze(in: app)
        XCTAssertFalse(row(subject, in: app).exists)
        select("Snoozed", in: app)
        expectUnread(subject, in: app)
        XCTAssertFalse(preview(in: app).exists)

        peek(subject, in: app)
        XCTAssertTrue(app.buttons["Restore to Inbox"].exists)
        confirmSnooze(in: app)
        expectUnread(subject, in: app)
        XCTAssertFalse(preview(in: app).exists)

        peek(subject, in: app)
        app.buttons["Settle"].tap()
        waitForAbsence(preview(in: app))
        select("Settled", in: app)
        expectUnread(subject, in: app)
        peek(subject, in: app)
        confirmSnooze(in: app)
        select("Snoozed", in: app)
        expectUnread(subject, in: app)
        XCTAssertFalse(preview(in: app).exists)
    }

    @MainActor
    func testPeekScrollTapAndReplyTools() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        resetDemo(in: app)
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
        capture.lifetime = .keepAlways
        add(capture)

        let body = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Hi Morgan,")).firstMatch
        XCTAssertTrue(body.exists)
        let bodyTop = body.frame.minY
        card.swipeUp()
        XCTAssertTrue(card.exists)
        XCTAssertTrue(body.exists)
        XCTAssertLessThan(body.frame.minY, bodyTop - 30)
        expectUnread(subject, in: app)
        let scrolled = XCTAttachment(screenshot: app.screenshot())
        scrolled.name = "Scrolled peek"
        scrolled.lifetime = .keepAlways
        add(scrolled)
        card.tap()
        waitForAbsence(card)
        XCTAssertTrue(app.buttons["Reply"].waitForExistence(timeout: 5))
        app.navigationBars.buttons["Inbox"].tap()
        XCTAssertEqual(row(subject, in: app).value as? String, "Read")

        for (action, prefix) in [("Reply", "Re:"), ("Reply All", "Re:"), ("Forward", "Fwd:")] {
            let title = "\(prefix) \(subject)"
            peek(subject, in: app)
            app.buttons[action].tap()
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5))
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

    @MainActor
    func testPeekReadPinAndMailboxGestures() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        resetDemo(in: app)
        let subject = "Course project feedback"

        peek(subject, in: app)
        app.buttons["Mark read"].tap()
        waitForAbsence(preview(in: app))
        XCTAssertEqual(row(subject, in: app).value as? String, "Read")
        peek(subject, in: app)
        app.buttons["Mark unread"].tap()
        waitForAbsence(preview(in: app))
        expectUnread(subject, in: app)

        peek(subject, in: app)
        app.buttons["Unpin"].tap()
        waitForAbsence(preview(in: app))
        expectUnread(subject, in: app)
        peek(subject, in: app)
        app.buttons["Pin"].tap()
        waitForAbsence(preview(in: app))
        expectUnread(subject, in: app)
        peek(subject, in: app)
        XCTAssertTrue(app.buttons["Unpin"].exists)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.5)).tap()
        waitForAbsence(preview(in: app))

        row(subject, in: app).tap()
        XCTAssertTrue(app.buttons["Reply"].waitForExistence(timeout: 5))
        app.navigationBars.buttons["Inbox"].tap()
        XCTAssertEqual(row(subject, in: app).value as? String, "Read")
        fullSwipe(row(subject, in: app), right: true)
        expectUnread(subject, in: app)
        fullSwipe(row(subject, in: app), right: false)
        waitForAbsence(row(subject, in: app))
        select("Settled", in: app)
        expectUnread(subject, in: app)

        select("Inbox", in: app)
        let thread = "Dinner on Saturday?"
        for _ in 0..<3 where !row(thread, in: app).isHittable { app.swipeUp() }
        peek(thread, in: app)
        XCTAssertEqual(preview(in: app).value as? String, "Read")
        XCTAssertTrue(app.staticTexts["· 3 messages"].exists)
        let latest = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Around 7?")).firstMatch
        XCTAssertTrue(latest.exists)
        for _ in 0..<4 where !preview(in: app).frame.contains(latest.frame) { preview(in: app).swipeUp() }
        XCTAssertGreaterThan(latest.frame.width, 0)
        XCTAssertTrue(preview(in: app).frame.contains(latest.frame))
        XCTAssertEqual(preview(in: app).value as? String, "Read")
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "Multi-message peek"
        capture.lifetime = .keepAlways
        add(capture)
    }

    @MainActor
    func testPeekMenuResizeAndTaps() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        resetDemo(in: app)
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
        XCTAssertTrue(app.navigationBars["Reply"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        waitForAbsence(app.navigationBars["Reply"])
        expectUnread(subject, in: app)
        peek(subject, in: app)
        XCTAssertEqual(card.frame.height, compactHeight, accuracy: 2)
        XCTAssertFalse(app.navigationBars["Reply"].exists)
        expectUnread(subject, in: app)
        capture("Apple Mail style tools", in: app)
        card.swipeUp()
        XCTAssertEqual(card.frame.height, compactHeight, accuracy: 2)
        expectUnread(subject, in: app)

        dragMenu(280, in: app)
        XCTAssertGreaterThan(card.frame.height, compactHeight + 100)
        expectUnread(subject, in: app)
        dragMenu(-280, in: app)
        XCTAssertEqual(card.frame.height, compactHeight, accuracy: 2)
        dragMenu(280, in: app)
        // Reply shortcuts remain usable before revealing the other tools.
        app.buttons["Forward"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.navigationBars["Forward"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        waitForAbsence(app.navigationBars["Forward"])
        expectUnread(subject, in: app)

        peek(subject, in: app)
        app.buttons["Mark read"].tap()
        waitForAbsence(preview(in: app))
        XCTAssertEqual(row(subject, in: app).value as? String, "Read")
    }

    @MainActor
    private func dragMenu(_ distance: CGFloat, in app: XCUIApplication) {
        let start = app.buttons["Reply"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: distance)), withVelocity: .fast, thenHoldForDuration: 0.1)
    }

    @MainActor
    private func closeQuickLook(in app: XCUIApplication) {
        let close = app.buttons["QLOverlayDoneButtonAccessibilityIdentifier"]
        if !close.exists {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.tap()
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: app.buttons["Send"])
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
    }

    @MainActor
    private func capture(_ name: String, in app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func fullSwipe(_ element: XCUIElement, right: Bool) {
        let start = element.coordinate(withNormalizedOffset: CGVector(dx: right ? 0.02 : 0.98, dy: 0.5))
        let end = element.coordinate(withNormalizedOffset: CGVector(dx: right ? 0.98 : 0.02, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0.1)
    }

    @MainActor
    private func preview(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "peek-preview").firstMatch
    }

    @MainActor
    private func resetDemo(in app: XCUIApplication) {
        app.buttons["More"].tap()
        app.buttons["Demo"].tap()
        let reset = app.buttons["Reset Demo Data"]
        for _ in 0..<4 where !reset.isHittable { app.swipeUp() }
        XCTAssertTrue(reset.isHittable)
        reset.tap()
        let confirmations = app.buttons.matching(identifier: "Reset Demo Data")
        confirmations.element(boundBy: confirmations.count - 1).tap()
        XCTAssertTrue(row("Course project feedback", in: app).waitForExistence(timeout: 5))
    }

    @MainActor
    private func openDraft(_ subject: String, in app: XCUIApplication) {
        select("Inbox", in: app)
        row(subject, in: app).tap()
        XCTAssertTrue(app.buttons["Edit draft"].waitForExistence(timeout: 5))
        app.buttons["Edit draft"].tap()
    }

    @MainActor
    private func row(_ subject: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", subject)).firstMatch
    }

    @MainActor
    private func peek(_ subject: String, in app: XCUIApplication) {
        let conversation = row(subject, in: app)
        XCTAssertTrue(conversation.waitForExistence(timeout: 5))
        conversation.press(forDuration: 0.8)
        XCTAssertTrue(preview(in: app).waitForExistence(timeout: 5))
    }

    @MainActor
    private func expectUnread(_ subject: String, in app: XCUIApplication) {
        let conversation = preview(in: app).exists ? preview(in: app) : row(subject, in: app)
        XCTAssertTrue(conversation.waitForExistence(timeout: 5))
        XCTAssertEqual(conversation.value as? String, "Unread")
    }

    @MainActor
    private func select(_ section: String, in app: XCUIApplication) {
        app.tabBars.buttons[section].tap()
    }

    @MainActor
    private func confirmSnooze(in app: XCUIApplication) {
        app.buttons["Snooze"].tap()
        XCTAssertTrue(app.navigationBars["Snooze"].waitForExistence(timeout: 5))
        let option = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "In ")).firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 5))
        option.tap()
        waitForAbsence(app.navigationBars["Snooze"])
        waitForAbsence(preview(in: app))
    }

    @MainActor
    private func waitForAbsence(_ element: XCUIElement) {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 5), .completed)
    }
}
