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
        waitForAbsence(app.buttons["Open conversation"])
        XCTAssertFalse(row(subject, in: app).exists)

        select("Settled", in: app)
        expectUnread(subject, in: app)
        peek(subject, in: app)
        XCTAssertFalse(app.buttons["Settle"].exists)
        app.buttons["Restore"].tap()
        waitForAbsence(app.buttons["Open conversation"])

        select("Inbox", in: app)
        expectUnread(subject, in: app)
        XCTAssertFalse(app.buttons["Open conversation"].exists)
        peek(subject, in: app)
        app.buttons["Snooze"].tap()
        XCTAssertTrue(app.navigationBars["Snooze"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["Open conversation"].waitForExistence(timeout: 5))
        expectUnread(subject, in: app)

        confirmSnooze(in: app)
        XCTAssertFalse(row(subject, in: app).exists)
        select("Snoozed", in: app)
        expectUnread(subject, in: app)
        XCTAssertFalse(app.buttons["Open conversation"].exists)

        peek(subject, in: app)
        XCTAssertTrue(app.buttons["Restore to Inbox"].exists)
        confirmSnooze(in: app)
        expectUnread(subject, in: app)
        XCTAssertFalse(app.buttons["Open conversation"].exists)

        peek(subject, in: app)
        app.buttons["Settle"].tap()
        waitForAbsence(app.buttons["Open conversation"])
        select("Settled", in: app)
        expectUnread(subject, in: app)
        peek(subject, in: app)
        confirmSnooze(in: app)
        select("Snoozed", in: app)
        expectUnread(subject, in: app)
        XCTAssertFalse(app.buttons["Open conversation"].exists)
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
    private func peek(_ subject: String, in app: XCUIApplication) {
        let conversation = row(subject, in: app)
        XCTAssertTrue(conversation.waitForExistence(timeout: 5))
        conversation.press(forDuration: 0.8)
        XCTAssertTrue(app.buttons["Open conversation"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func expectUnread(_ subject: String, in app: XCUIApplication) {
        let conversation = row(subject, in: app)
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
        waitForAbsence(app.buttons["Open conversation"])
    }

    @MainActor
    private func waitForAbsence(_ element: XCUIElement) {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 5), .completed)
    }
}
