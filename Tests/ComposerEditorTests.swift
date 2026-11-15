import XCTest
import UIKit
@testable import Mailern

@MainActor final class ComposerEditorTests: XCTestCase {
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
