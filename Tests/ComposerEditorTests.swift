import XCTest
import UIKit
import SwiftUI
@testable import Mailern

@MainActor final class ComposerEditorTests: XCTestCase {
    func testFormattedSignatureCountsAsEdited() throws {
        let text = NSMutableAttributedString(attributedString: RichText.plain("Hi\n\nMorgan"))
        let signature = NSRange(location: 2, length: 8)
        XCTAssertTrue(RichText.isPlain(text, in: signature))
        // A saved draft comes back through RTFD with rewritten font and paragraph attributes.
        XCTAssertTrue(RichText.isPlain(RichText.decode(try RichText.encode(text), fallback: ""), in: signature))
        let bold = UIFont.preferredFont(forTextStyle: .body).fontDescriptor.withSymbolicTraits(.traitBold)!
        text.addAttribute(.font, value: UIFont(descriptor: bold, size: 0), range: NSRange(location: 4, length: 6))
        XCTAssertFalse(RichText.isPlain(text, in: signature))
        XCTAssertFalse(RichText.isPlain(RichText.decode(try RichText.encode(text), fallback: ""), in: signature))
        text.setAttributes(RichText.plain("x").attributes(at: 0, effectiveRange: nil), range: signature)
        text.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: NSRange(location: 4, length: 6))
        XCTAssertFalse(RichText.isPlain(text, in: signature))
    }

    func testQuoteWithWriterFormattingDoesNotFold() throws {
        // Writes a reply the way the composer does and returns it as it comes back from storage.
        func reply(_ text: String, quoting original: NSAttributedString, edit: (NSMutableAttributedString, Int) -> Void = { _, _ in }) throws -> NSAttributedString {
            let reply = NSMutableAttributedString(attributedString: RichText.plain(text + "\n\nOn Monday, Casey wrote:\n"))
            let start = (text as NSString).length + 2
            reply.append(original)
            RichText.markQuote(in: reply, from: start, body: start + 24)
            edit(reply, start)
            return RichText.decode(try RichText.encode(reply), fallback: "")
        }
        func folds(_ reply: NSAttributedString, quoting original: NSAttributedString) -> Bool {
            RichText.isUnchangedQuote(reply, from: reply.length - original.length - 24, attributionLength: 23, quoting: original)
        }
        let casey = RichText.plain("Around 7?")
        XCTAssertTrue(folds(try reply("Sure.", quoting: casey), quoting: casey))
        // Bold, centering, a taller line, or a bold attribution point at quoted words, so the quote stays visible.
        let bold = UIFont(descriptor: UIFont.preferredFont(forTextStyle: .body).fontDescriptor.withSymbolicTraits(.traitBold)!, size: 0)
        XCTAssertFalse(folds(try reply("Sure.", quoting: casey) { $0.addAttribute(.font, value: bold, range: NSRange(location: $1 + 24, length: 6)) }, quoting: casey))
        XCTAssertFalse(folds(try reply("Sure.", quoting: casey) { $0.addAttribute(.font, value: bold, range: NSRange(location: $1, length: 9)) }, quoting: casey))
        for change in [{ (style: NSMutableParagraphStyle) in style.alignment = .center }, { $0.minimumLineHeight = 40 }] {
            XCTAssertFalse(folds(try reply("Sure.", quoting: casey) { text, start in
                let style = NSMutableParagraphStyle()
                style.headIndent = 10; style.firstLineHeadIndent = 10
                change(style)
                text.addAttribute(.paragraphStyle, value: style, range: NSRange(location: start + 24, length: 9))
            }, quoting: casey))
        }
        XCTAssertFalse(folds(try reply("Sure.", quoting: casey) { $0.removeAttribute(RichText.quote, range: NSRange(location: $1 + 24, length: 9)) }, quoting: casey))
        // Fixed black matches the adaptive label color only in light mode, and a resized attribution word is the writer's.
        XCTAssertFalse(folds(try reply("Sure.", quoting: casey) { $0.addAttribute(.foregroundColor, value: UIColor(white: 0, alpha: 1), range: NSRange(location: $1 + 24, length: 6)) }, quoting: casey))
        XCTAssertFalse(folds(try reply("Sure.", quoting: casey) { $0.addAttribute(.font, value: UIFont.systemFont(ofSize: 30), range: NSRange(location: $1 + 3, length: 6)) }, quoting: casey))
        // The other appearance's purple on one attribution word is the writer's color, not the composer's.
        let otherPurple = UIColor.systemPurple.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
        for word in [NSRange(location: 0, length: 2), NSRange(location: 3, length: 6)] {
            XCTAssertFalse(folds(try reply("Sure.", quoting: casey) { $0.addAttribute(.foregroundColor, value: otherPurple, range: NSRange(location: $1 + word.location, length: word.length)) }, quoting: casey))
        }
        XCTAssertFalse(folds(try reply("Sure.", quoting: casey) { $0.addAttribute(.kern, value: 4, range: NSRange(location: $1 + 24, length: 6)) }, quoting: casey))
        // Turning a quoted bulleted list into a numbered one changes it, even with the same text.
        let list = NSMutableAttributedString(attributedString: RichText.plain("Bread\nMilk"))
        let bullets = NSMutableParagraphStyle()
        bullets.textLists = [NSTextList(markerFormat: .disc, options: 0)]
        list.addAttribute(.paragraphStyle, value: bullets, range: NSRange(location: 0, length: list.length))
        let groceries = RichText.decode(try RichText.encode(list), fallback: "")
        XCTAssertTrue(folds(try reply("Sure.", quoting: groceries), quoting: groceries))
        XCTAssertFalse(folds(try reply("Sure.", quoting: groceries) { text, start in
            let body = NSRange(location: start + 24, length: groceries.length)
            text.enumerateAttribute(.paragraphStyle, in: body) { value, range, _ in
                let style = (value as! NSParagraphStyle).mutableCopy() as! NSMutableParagraphStyle
                style.textLists = [NSTextList(markerFormat: .decimal, options: 0)]
                text.addAttribute(.paragraphStyle, value: style, range: range)
            }
        }, quoting: groceries))
        // A reply to your own reply quotes its quote too, and still folds when untouched.
        let own = try reply("Sure.", quoting: casey)
        XCTAssertTrue(folds(try reply("See you then.", quoting: own), quoting: own))
        XCTAssertFalse(folds(try reply("See you then.", quoting: own) { $0.addAttribute(.font, value: bold, range: NSRange(location: $1 + 24, length: 5)) }, quoting: own))
    }

    func testReplyActionsResumePlainSavedDraftAfterIncomingMail() async throws {
        let directory = URL.temporaryDirectory.appending(path: "reply-draft-resume-\(UUID())")
        let store = MailStore(persistence: SQLitePersistence(url: directory.appending(path: "mail.sqlite")))
        let drafts = DraftStore(url: directory.appending(path: "drafts.json"))
        let source = try XCTUnwrap(store.list(.inbox).first)
        var draft = ComposerDraft.make(mode: .replyAll(source.id), conversation: source, accounts: store.accounts)
        draft.text = "My saved text"
        draft.richText = nil
        store.receiveReply(source.id)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        func editor(in view: UIView) -> UITextView? {
            if let text = view as? UITextView, text.accessibilityLabel == "Message body" { return text }
            return view.subviews.lazy.compactMap { editor(in: $0) }.first
        }
        for mode in [ComposeMode.reply(source.id), .replyAll(source.id), .draft(draft.id)] {
            let saved = await drafts.save(draft)
            XCTAssertTrue(saved)
            let window = UIWindow(windowScene: scene)
            let host = UIHostingController(rootView: ComposerView(mode: mode).environment(store).environment(drafts))
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer { host.view.endEditing(true); window.isHidden = true }
            try await Task.sleep(for: .milliseconds(500))
            let text = try XCTUnwrap(editor(in: host.view))
            XCTAssertEqual(text.text, "My saved text")
            text.insertText("Saved edit ")
            let expected = text.text
            for _ in 0..<100 {
                if drafts.drafts.first?.text == expected { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(drafts.drafts.count, 1)
            XCTAssertEqual(drafts.drafts.first?.id, draft.id)
            XCTAssertEqual(drafts.drafts.first?.text, expected)
        }
    }

    func testDraftRecoverySurvivesErrorDismissal() async throws {
        let directory = URL.temporaryDirectory.appending(path: "draft-recovery-\(UUID())")
        let url = directory.appending(path: "drafts.json")
        let original = ComposerDraft(subject: "Recovered draft", text: "Preserved text")
        let written = await DraftStore(url: url).save(original)
        XCTAssertTrue(written)
        let bytes = try Data(contentsOf: url)
        try Data("Unreadable fixture".utf8).write(to: url, options: .atomic)
        let drafts = DraftStore(url: url)
        drafts.error = nil
        XCTAssertTrue(drafts.needsReload)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: MailboxView().environment(drafts)
            .environment(MailStore(persistence: SQLitePersistence(url: directory.appending(path: "mail.sqlite"))))
            .environment(SnoozePreferences()))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(300))
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let unavailable = XCTAttachment(image: renderer.image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) })
        unavailable.name = "Persistent Retry after error dismissal"
        unavailable.lifetime = .keepAlways
        add(unavailable)
        try bytes.write(to: url, options: .atomic)
        await drafts.reload()
        XCTAssertFalse(drafts.needsReload)
        XCTAssertEqual(drafts.drafts, [original])
        try await Task.sleep(for: .milliseconds(300))
        let recovered = XCTAttachment(image: renderer.image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) })
        recovered.name = "Recovered Inbox draft"
        recovered.lifetime = .keepAlways
        add(recovered)
    }

    func testBottomComposeDoesNotSelectBlankTab() async throws {
        guard #available(iOS 27, *) else { return }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let directory = URL.temporaryDirectory.appending(path: "bottom-compose-\(UUID())")
        let host = UIHostingController(rootView: MailboxView()
            .environment(MailStore(persistence: SQLitePersistence(url: directory.appending(path: "mail.sqlite"))))
            .environment(DraftStore(url: directory.appending(path: "drafts.json"))))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { host.dismiss(animated: false); window.isHidden = true }
        try await Task.sleep(for: .milliseconds(500))
        func findTabs(_ controller: UIViewController) -> UITabBarController? {
            (controller as? UITabBarController) ?? controller.children.lazy.compactMap { findTabs($0) }.first
        }
        let tabs = try XCTUnwrap(findTabs(host))
        let compose = try XCTUnwrap(tabs.tabs.last)
        let selected = tabs.selectedTab
        XCTAssertEqual(tabs.tabs.count, 4)
        XCTAssertFalse(tabs.delegate?.tabBarController?(tabs, shouldSelectTab: compose) ?? true,
                       "Compose must open a sheet before UIKit selects its empty tab")
        XCTAssertTrue(tabs.selectedTab === selected)
    }

    func testCoordinatedAttachmentReadWaitsForWriterAndChecksLimit() async throws {
        let directory = URL.temporaryDirectory.appending(path: "coordinated-import-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: "Sample.txt")
        try Data("Original".utf8).write(to: file)
        let entered = expectation(description: "Coordinated writer holds file")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let writer = Task.detached {
            var error: NSError?
            NSFileCoordinator().coordinate(writingItemAt: file, options: .forReplacing, error: &error) { writable in
                entered.fulfill()
                _ = release.wait(timeout: .now() + 5)
                try? Data("Updated".utf8).write(to: writable, options: .atomic)
            }
            if let error { throw error }
        }
        await fulfillment(of: [entered], timeout: 3)
        let reader = Task.detached { try AttachmentImport.read(file, limit: 25) }
        try await Task.sleep(for: .milliseconds(100))
        release.signal()
        try await writer.value
        let imported = try await reader.value
        XCTAssertEqual(imported.name, "Sample.txt")
        XCTAssertEqual(String(data: imported.data, encoding: .utf8), "Updated")
        XCTAssertThrowsError(try AttachmentImport.read(file, limit: 2))
    }

    func testAttachmentAutosaveKeepsComposerResponsive() async throws {
        final class Gate: @unchecked Sendable {
            let release = DispatchSemaphore(value: 0)
            private let lock = NSLock()
            private var armed = false
            private var started = false
            var hasStarted: Bool { lock.lock(); defer { lock.unlock() }; return started }
            func arm() { lock.lock(); armed = true; lock.unlock() }
            func write(_ data: Data, to url: URL) throws {
                guard !Thread.isMainThread else { throw CocoaError(.fileWriteUnknown) }
                lock.lock()
                let block = armed
                armed = false
                if block { started = true }
                lock.unlock()
                if block {
                    guard release.wait(timeout: .now() + 5) == .success else { throw CocoaError(.fileWriteUnknown) }
                }
                try data.write(to: url, options: .atomic)
            }
        }
        let gate = Gate()
        defer { gate.release.signal() }
        let directory = URL.temporaryDirectory.appending(path: "composer-attachment-check-\(UUID())")
        let drafts = DraftStore(url: directory.appending(path: "drafts.json"), write: { try gate.write($0, to: $1) })
        let payload = Data(repeating: 42, count: 25 * 1024 * 1024)
        var draft = ComposerDraft(subject: "Attachment responsiveness", text: "Original",
                                  attachments: [MailAttachment(name: "Sample.bin", data: payload, contentType: "public.data")])
        let editingID = draft.id
        for _ in 0..<3 {
            let saved = await drafts.save(draft)
            XCTAssertTrue(saved)
            draft.id = UUID()
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: ComposerView(mode: .draft(editingID))
            .environment(MailStore(persistence: SQLitePersistence(url: directory.appending(path: "mail.sqlite"))))
            .environment(drafts))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { host.view.endEditing(true); window.isHidden = true }
        try await Task.sleep(for: .milliseconds(500))
        func editor(in view: UIView) -> UITextView? {
            if let text = view as? UITextView, text.accessibilityLabel == "Message body" { return text }
            return view.subviews.lazy.compactMap { editor(in: $0) }.first
        }
        let text = try XCTUnwrap(editor(in: host.view))
        let heartbeat = Task { @MainActor in
            var previous = Date()
            var longestGap: TimeInterval = 0
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(10)) } catch { break }
                let now = Date()
                longestGap = max(longestGap, now.timeIntervalSince(previous))
                previous = now
            }
            return longestGap
        }
        defer { heartbeat.cancel() }
        gate.arm()
        text.insertText("First ")
        var entered = false
        for _ in 0..<200 {
            if gate.hasStarted { entered = true; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(entered)
        let start = Date()
        text.insertText("Second ")
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.1)
        XCTAssertTrue(text.text.contains("Second"))
        let expected = text.text
        gate.release.signal()
        for _ in 0..<200 {
            if drafts.drafts.first(where: { $0.id == editingID })?.text == expected { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(drafts.drafts.count, 3)
        XCTAssertEqual(drafts.drafts.first(where: { $0.id == editingID })?.text, expected)
        heartbeat.cancel()
        let longestGap = await heartbeat.value
        // The scene heartbeat includes native setup and machine load; typing during the blocked write is the assertion.
        print("Main-actor longest heartbeat gap with three 25 MiB drafts: \(longestGap * 1000) ms")
        XCTAssertEqual(DraftStore(url: directory.appending(path: "drafts.json")).drafts.first(where: { $0.id == editingID })?.text, expected)
    }

    func testComposerDisablesSubjectWritingTools() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let directory = URL.temporaryDirectory.appending(path: "composer-field-check-\(UUID())")
        let store = MailStore(persistence: SQLitePersistence(url: directory.appending(path: "mail.sqlite")))
        let host = UIHostingController(rootView: ComposerView(mode: .new).environment(store).environment(DraftStore(url: directory.appending(path: "drafts.json"))))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { host.view.endEditing(true); window.isHidden = true }
        try await Task.sleep(for: .milliseconds(300))
        func fields(in view: UIView) -> [UITextField] {
            (view as? UITextField).map { [$0] } ?? view.subviews.flatMap { fields(in: $0) }
        }
        let inputs = fields(in: host.view)
        XCTAssertFalse(inputs.isEmpty)
        for field in inputs { XCTAssertEqual(field.writingToolsBehavior, .none) }
    }

    func testRelativeSizeAndNumberingKeepMixedParagraphs() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let host = UIViewController()
        window.rootViewController = host
        let view = UITextView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        host.view.addSubview(view)
        window.makeKeyAndVisible()
        defer { host.dismiss(animated: false); view.resignFirstResponder(); window.isHidden = true }
        let text = NSMutableAttributedString(attributedString: RichText.plain("First\nSecond"))
        text.addAttribute(.font, value: UIFont.systemFont(ofSize: 22), range: NSRange(location: 6, length: 6))
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.headIndent = 10
        text.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 6, length: 6))
        view.attributedText = text
        view.selectedRange = NSRange(location: 0, length: text.length)
        let state = RichTextState()
        state.view = view
        state.sync()
        let coordinator = RichTextEditor.Coordinator(state: state, attach: {}, photos: {})
        view.delegate = coordinator
        coordinator.installKeyboard(on: view)
        state.showFormat()
        try await Task.sleep(for: .milliseconds(500))
        let panel = try XCTUnwrap(host.presentedViewController as? UITextFormattingViewController)
        let format = try XCTUnwrap(panel.delegate as? NativeFormatting)
        format.textFormattingViewController(panel, didChangeValue: .increaseFontSize)
        XCTAssertEqual((view.attributedText.attribute(.font, at: 0, effectiveRange: nil) as! UIFont).pointSize, 18)
        XCTAssertEqual((view.attributedText.attribute(.font, at: 6, effectiveRange: nil) as! UIFont).pointSize, 23)
        format.textFormattingViewController(panel, didChangeValue: .decreaseFontSize)
        XCTAssertEqual((view.attributedText.attribute(.font, at: 6, effectiveRange: nil) as! UIFont).pointSize, 22)
        format.textFormattingViewController(panel, didChangeValue: .textList(.decimal))
        let first = try XCTUnwrap((view.attributedText.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.textLists.first)
        let second = try XCTUnwrap((view.attributedText.attribute(.paragraphStyle, at: 6, effectiveRange: nil) as? NSParagraphStyle)?.textLists.first)
        XCTAssertTrue(first === second)
        let htmlData = try view.attributedText.data(from: NSRange(location: 0, length: view.attributedText.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.html])
        let html = try XCTUnwrap(String(data: htmlData, encoding: .utf8))
        XCTAssertEqual(html.components(separatedBy: "<ol").count - 1, 1)
        XCTAssertEqual(html.components(separatedBy: "<li").count - 1, 2)
    }

    func testOpenFormattingPanelTracksSelection() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let host = UIViewController()
        window.rootViewController = host
        let view = UITextView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        host.view.addSubview(view)
        window.makeKeyAndVisible()
        defer { host.dismiss(animated: false); view.resignFirstResponder(); window.isHidden = true }
        let text = NSMutableAttributedString(attributedString: RichText.plain("Plain Bold"))
        text.addAttribute(.font, value: UIFont.boldSystemFont(ofSize: 17), range: NSRange(location: 6, length: 4))
        view.attributedText = text
        view.selectedRange = NSRange(location: 0, length: 5)
        let state = RichTextState()
        state.view = view
        state.sync()
        let coordinator = RichTextEditor.Coordinator(state: state, attach: {}, photos: {})
        view.delegate = coordinator
        coordinator.installKeyboard(on: view)
        state.showFormat()
        try await Task.sleep(for: .milliseconds(500))
        let panel = try XCTUnwrap(host.presentedViewController as? UITextFormattingViewController)
        XCTAssertFalse((try XCTUnwrap(panel.formattingDescriptor)).fonts.contains { $0.fontDescriptor.symbolicTraits.contains(.traitBold) })
        view.selectedRange = NSRange(location: 6, length: 4)
        coordinator.textViewDidChangeSelection(view)
        XCTAssertTrue((try XCTUnwrap(panel.formattingDescriptor)).fonts.allSatisfy { $0.fontDescriptor.symbolicTraits.contains(.traitBold) })
        XCTAssertFalse((try XCTUnwrap(panel.formattingDescriptor)).fonts.isEmpty)
        view.selectedRange = NSRange(location: 0, length: 5)
        coordinator.textViewDidChangeSelection(view)
        XCTAssertFalse((try XCTUnwrap(panel.formattingDescriptor)).fonts.contains { $0.fontDescriptor.symbolicTraits.contains(.traitBold) })
        XCTAssertTrue(host.presentedViewController === panel)
        for (font, expected) in [(UIFont.systemFont(ofSize: 28), Optional<String>.none),
                                 (UIFont.boldSystemFont(ofSize: 28), nil),
                                 (UIFont.systemFont(ofSize: 28, weight: .bold), "title"),
                                 (UIFont.monospacedSystemFont(ofSize: 13, weight: .regular), nil)] {
            view.textStorage.addAttribute(.font, value: font, range: NSRange(location: 0, length: 5))
            state.sync()
            XCTAssertEqual(panel.formattingDescriptor?.formattingStyleKey, expected)
        }
    }

    func testFormattingUndoRedoKeepsNativeTypingHistory() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        window.rootViewController = controller
        let view = UITextView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        controller.view.addSubview(view)
        window.makeKeyAndVisible()
        defer { view.resignFirstResponder(); window.isHidden = true }
        view.becomeFirstResponder()
        view.typingAttributes = [.font: UIFont.preferredFont(forTextStyle: .body), .foregroundColor: UIColor.label]
        view.insertText("Hello")
        view.resignFirstResponder()
        try await Task.sleep(for: .milliseconds(50))
        view.selectedRange = NSRange(location: 0, length: 5)
        let state = RichTextState()
        state.view = view
        state.sync()
        state.setTrait(.traitBold, enabled: true)
        try await Task.sleep(for: .milliseconds(50))
        let undo = try XCTUnwrap(view.undoManager)
        undo.undo()
        XCTAssertEqual(view.text, "Hello")
        let plain = try XCTUnwrap(view.attributedText.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        XCTAssertFalse(plain.fontDescriptor.symbolicTraits.contains(.traitBold))
        XCTAssertEqual(view.selectedRange, NSRange(location: 0, length: 5))
        undo.undo()
        XCTAssertEqual(view.text, "")
        undo.redo()
        XCTAssertEqual(view.text, "Hello")
        undo.redo()
        let bold = try XCTUnwrap(view.attributedText.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        XCTAssertTrue(bold.fontDescriptor.symbolicTraits.contains(.traitBold))
        XCTAssertEqual(state.text.string, "Hello")
    }

    func testMixedParagraphsKeepTheirOwnStyles() {
        let list = NSMutableParagraphStyle()
        list.textLists = [NSTextList(markerFormat: .disc, options: 0)]
        list.headIndent = 20
        let quote = NSMutableParagraphStyle()
        quote.headIndent = 10
        let text = NSMutableAttributedString(attributedString: RichText.plain("List\nPlain\nQuote"))
        text.addAttribute(.paragraphStyle, value: list, range: NSRange(location: 0, length: 5))
        text.addAttribute(.paragraphStyle, value: quote, range: NSRange(location: 11, length: 5))
        let view = UITextView()
        view.attributedText = text
        view.selectedRange = NSRange(location: 0, length: text.length)
        let state = RichTextState()
        state.view = view
        state.sync()
        state.paragraph { $0.alignment = .center }
        for (offset, listCount, indent) in [(0, 1, CGFloat(20)), (5, 0, CGFloat(0)), (11, 0, CGFloat(10))] {
            let style = view.attributedText.attribute(.paragraphStyle, at: offset, effectiveRange: nil) as! NSParagraphStyle
            XCTAssertEqual(style.alignment, .center)
            XCTAssertEqual(style.textLists.count, listCount)
            XCTAssertEqual(style.headIndent, indent)
        }
        state.paragraph { $0.headIndent += 20 }
        XCTAssertEqual((view.attributedText.attribute(.paragraphStyle, at: 5, effectiveRange: nil) as! NSParagraphStyle).headIndent, 20)
        XCTAssertEqual((view.attributedText.attribute(.paragraphStyle, at: 11, effectiveRange: nil) as! NSParagraphStyle).headIndent, 30)
    }

    func testBoldPreservesMixedFontSizesAndFamilies() throws {
        let text = NSMutableAttributedString(string: "Body Code")
        text.addAttribute(.font, value: UIFont.systemFont(ofSize: 17), range: NSRange(location: 0, length: 5))
        text.addAttribute(.font, value: UIFont.monospacedSystemFont(ofSize: 22, weight: .regular), range: NSRange(location: 5, length: 4))
        let view = UITextView()
        view.attributedText = text
        view.selectedRange = NSRange(location: 0, length: text.length)
        let state = RichTextState()
        state.view = view
        state.sync()
        state.setTrait(.traitBold, enabled: true)
        let body = try XCTUnwrap(view.attributedText.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        let code = try XCTUnwrap(view.attributedText.attribute(.font, at: 5, effectiveRange: nil) as? UIFont)
        XCTAssertEqual(body.pointSize, 17)
        XCTAssertEqual(code.pointSize, 22)
        XCTAssertTrue(body.fontDescriptor.symbolicTraits.contains(.traitBold))
        XCTAssertTrue(code.fontDescriptor.symbolicTraits.contains([.traitBold, .traitMonoSpace]))
    }

    func testRichTextRoundTripPreservesStylesAndQuotes() throws {
        let text = NSMutableAttributedString(attributedString: RichText.plain("Hello styled quote"))
        let bold = UIFont.systemFont(ofSize: 22, weight: .bold)
        text.addAttributes([.font: bold, .foregroundColor: UIColor.systemPurple, RichText.quote: true], range: NSRange(location: 6, length: 12))
        let decoded = RichText.decode(try RichText.encode(text), fallback: "")
        XCTAssertEqual(decoded.string, text.string)
        XCTAssertEqual(decoded.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor, .label)
        XCTAssertEqual(decoded.attribute(RichText.quote, at: 6, effectiveRange: nil) as? Bool, true)
        let font = try XCTUnwrap(decoded.attribute(.font, at: 6, effectiveRange: nil) as? UIFont)
        XCTAssertEqual(font.pointSize, 22)
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.traitBold))
    }
}
