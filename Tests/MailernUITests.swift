import XCTest

final class MailernUITests: XCTestCase {
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
        XCTAssertTrue(app.navigationBars["New message"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        let list = app.collectionViews.firstMatch
        let initialTop = row("Course project feedback", in: app).frame.minY
        let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
        start.press(forDuration: 0.01, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -180)), withVelocity: .slow, thenHoldForDuration: 0.5)
        XCTAssertLessThan(row("Course project feedback", in: app).frame.minY, initialTop - 50)
        list.swipeDown(velocity: .fast)
        XCTAssertFalse(app.navigationBars["New message"].exists, "Returning to the top must not compose")
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
            XCTAssertFalse(app.navigationBars["New message"].exists)
            capture("\(mode) after short pull", in: app)
            start.press(forDuration: 0.01, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 360)), withVelocity: .slow, thenHoldForDuration: 1)
            if mode == "Search" {
                XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 5))
                app.buttons["Close"].tap()
            } else {
                XCTAssertTrue(app.navigationBars["New message"].waitForExistence(timeout: 5))
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
        XCTAssertTrue(app.navigationBars["New message"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["Inbox"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["Inbox"].isSelected)
        app.buttons["Settled"].tap()
        XCTAssertTrue(app.navigationBars["Settled"].waitForExistence(timeout: 5))
        app.buttons["Inbox"].tap()
        pull()
        XCTAssertTrue(app.navigationBars["New message"].waitForExistence(timeout: 5))
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
