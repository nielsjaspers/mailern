import XCTest

final class MailernUITests: XCTestCase {
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

        for (action, title, prefix) in [("Reply", "Reply", "Re:"), ("Reply All", "Reply All", "Re:"), ("Forward", "Forward", "Fwd:")] {
            peek(subject, in: app)
            app.buttons[action].tap()
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5))
            XCTAssertTrue(app.textFields.matching(NSPredicate(format: "value == %@", "\(prefix) \(subject)")).firstMatch.exists)
            if action == "Reply All" {
                XCTAssertTrue(app.textFields.matching(NSPredicate(format: "value == %@", "coordinator@college.example.com")).firstMatch.exists)
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
    func testPeekMenuResizeAndHoldSelection() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        resetDemo(in: app)
        let subject = "Course project feedback"
        peek(subject, in: app, expandTools: false)
        let card = preview(in: app)
        let largeHeight = card.frame.height
        XCTAssertGreaterThan(largeHeight, app.frame.height * 0.7)
        capture("Tall peek", in: app)

        let handle = app.buttons["peek-menu-handle"]
        XCTAssertGreaterThanOrEqual(handle.frame.height, 44)
        let start = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -280)), withVelocity: .fast, thenHoldForDuration: 0.1)
        XCTAssertLessThan(card.frame.height, largeHeight - 100)
        expectUnread(subject, in: app)
        capture("Revealed glass menu", in: app)
        let compactHeight = card.frame.height
        card.swipeUp()
        XCTAssertEqual(card.frame.height, compactHeight, accuracy: 2)
        expectUnread(subject, in: app)

        let down = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        down.press(forDuration: 0.05, thenDragTo: down.withOffset(CGVector(dx: 0, dy: 280)), withVelocity: .fast, thenHoldForDuration: 0.1)
        XCTAssertGreaterThan(card.frame.height, compactHeight + 100)
        handle.tap()
        XCTAssertEqual(card.frame.height, compactHeight, accuracy: 2)

        let read = app.buttons["Mark read"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let unpin = app.buttons["Unpin"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        read.press(forDuration: 0.6, thenDragTo: unpin, withVelocity: .slow, thenHoldForDuration: 0.5)
        waitForAbsence(card)
        expectUnread(subject, in: app)
        peek(subject, in: app)
        XCTAssertTrue(app.buttons["Pin"].exists)

        let cancel = app.buttons["Mark read"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        cancel.press(forDuration: 0.6, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.5)), withVelocity: .slow, thenHoldForDuration: 0.2)
        XCTAssertTrue(card.exists)
        expectUnread(subject, in: app)
        let reply = app.buttons["Reply"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let forward = app.buttons["Forward"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        reply.press(forDuration: 0.6, thenDragTo: forward, withVelocity: .slow, thenHoldForDuration: 0.2)
        XCTAssertTrue(app.navigationBars["Forward"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        waitForAbsence(app.navigationBars["Forward"])
        expectUnread(subject, in: app)
    }

    @MainActor
    private func capture(_ name: String, in app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
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
    private func row(_ subject: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", subject)).firstMatch
    }

    @MainActor
    private func peek(_ subject: String, in app: XCUIApplication, expandTools: Bool = true) {
        let conversation = row(subject, in: app)
        XCTAssertTrue(conversation.waitForExistence(timeout: 5))
        conversation.press(forDuration: 0.8)
        XCTAssertTrue(preview(in: app).waitForExistence(timeout: 5))
        if expandTools { app.buttons["peek-menu-handle"].tap() }
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
