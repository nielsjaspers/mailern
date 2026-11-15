import XCTest
import UIKit
import SwiftUI
@testable import Mailern

@MainActor final class ComposerEditorTests: XCTestCase {
    func testComposerDisablesSubjectWritingTools() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let directory = URL.temporaryDirectory.appending(path: "composer-field-check-\(UUID())")
        let store = MailStore(persistence: JSONPersistence(url: directory.appending(path: "mail.json")))
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
