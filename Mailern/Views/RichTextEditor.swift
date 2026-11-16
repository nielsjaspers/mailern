import SwiftUI
import UIKit

/// RTFD retains fonts, links and pasted content. Semantic label colors must remain adaptive.
enum RichText {
    private struct Span: Codable { var location: Int; var length: Int }
    private struct Document: Codable { var data: Data; var labelColors: [Span]; var quotes: [Span]? }
    static let quote = NSAttributedString.Key("mailern.quote")
    static func plain(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: UIFont.preferredFont(forTextStyle: .body), .foregroundColor: UIColor.label])
    }
    static func decode(_ data: Data?, fallback: String) -> NSAttributedString {
        guard let data, let document = try? JSONDecoder().decode(Document.self, from: data),
              let result = try? NSMutableAttributedString(data: document.data, options: [.documentType: NSAttributedString.DocumentType.rtfd], documentAttributes: nil)
        else { return plain(fallback) }
        for span in document.labelColors where span.location >= 0 && span.length >= 0 && span.location <= result.length && span.length <= result.length - span.location {
            result.addAttribute(.foregroundColor, value: UIColor.label, range: NSRange(location: span.location, length: span.length))
        }
        for span in document.quotes ?? [] where span.location >= 0 && span.length >= 0 && span.location <= result.length && span.length <= result.length - span.location {
            result.addAttribute(quote, value: true, range: NSRange(location: span.location, length: span.length))
        }
        return result
    }
    static func encode(_ text: NSAttributedString) throws -> Data {
        var spans: [Span] = []
        text.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: text.length)) { color, range, _ in
            if let color = color as? UIColor, color == .label { spans.append(Span(location: range.location, length: range.length)) }
        }
        var quotes: [Span] = []
        text.enumerateAttribute(quote, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if value as? Bool == true { quotes.append(Span(location: range.location, length: range.length)) }
        }
        let data = try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
        return try JSONEncoder().encode(Document(data: data, labelColors: spans, quotes: quotes.isEmpty ? nil : quotes))
    }
}

@MainActor @Observable
final class RichTextState {
    var text = RichText.plain("")
    var selection = NSRange(location: 0, length: 0)
    var typing: [NSAttributedString.Key: Any] = [:]
    var edited = false
    @ObservationIgnored weak var view: UITextView?
    @ObservationIgnored var presentFormatting: () -> Void = {}
    @ObservationIgnored var didSync: () -> Void = {}

    var attributes: [NSAttributedString.Key: Any] {
        guard selection.length > 0, text.length > 0 else { return typing }
        return text.attributes(at: min(selection.location, text.length - 1), effectiveRange: nil)
    }
    func sync() {
        guard let view else { return }
        text = NSAttributedString(attributedString: view.attributedText)
        selection = view.selectedRange
        typing = view.typingAttributes
        didSync()
    }
    func showFormat() {
        view?.becomeFirstResponder()
        presentFormatting()
    }
    @MainActor private struct EditSnapshot {
        let text: NSAttributedString
        let selection: NSRange
        let typing: [NSAttributedString.Key: Any]
        init(_ view: UITextView) {
            text = NSAttributedString(attributedString: view.attributedText)
            selection = view.selectedRange
            typing = view.typingAttributes
        }
    }
    // Direct text storage edits bypass UITextView's native undo tracking.
    private func recordEdit(_ mutation: (UITextView) -> Void) {
        guard let view else { return }
        let before = EditSnapshot(view)
        let undo = view.undoManager
        undo?.beginUndoGrouping()
        undo?.registerUndo(withTarget: self) { $0.restore(before) }
        mutation(view)
        undo?.setActionName("Format")
        undo?.endUndoGrouping()
        edited = true
        sync()
    }
    private func restore(_ snapshot: EditSnapshot) {
        guard let view else { return }
        let inverse = EditSnapshot(view)
        view.undoManager?.registerUndo(withTarget: self) { $0.restore(inverse) }
        view.undoManager?.setActionName("Format")
        view.textStorage.beginEditing()
        if view.text == snapshot.text.string {
            snapshot.text.enumerateAttributes(in: NSRange(location: 0, length: snapshot.text.length)) { attributes, range, _ in
                view.textStorage.setAttributes(attributes, range: range)
            }
        } else { view.textStorage.setAttributedString(snapshot.text) }
        view.textStorage.endEditing()
        view.selectedRange = snapshot.selection
        view.typingAttributes = snapshot.typing
        edited = true
        sync()
    }
    func attribute(_ key: NSAttributedString.Key, _ value: Any) {
        recordEdit { view in
            let range = view.selectedRange
            if range.length > 0 { view.textStorage.addAttribute(key, value: value, range: range) }
            var typing = view.typingAttributes
            typing[key] = value
            view.typingAttributes = typing
        }
    }
    private func transformFonts(_ transform: (UIFont) -> UIFont) {
        recordEdit { view in
            let range = view.selectedRange
            let before = NSAttributedString(attributedString: view.attributedText)
            var typing = view.typingAttributes
            view.textStorage.beginEditing()
            before.enumerateAttribute(.font, in: range) { value, span, _ in
                view.textStorage.addAttribute(.font, value: transform(value as? UIFont ?? .preferredFont(forTextStyle: .body)), range: span)
            }
            view.textStorage.endEditing()
            typing[.font] = transform(typing[.font] as? UIFont ?? .preferredFont(forTextStyle: .body))
            view.typingAttributes = typing
        }
    }
    func setTrait(_ trait: UIFontDescriptor.SymbolicTraits, enabled: Bool) {
        transformFonts { font in
            var traits = font.fontDescriptor.symbolicTraits
            if enabled { traits.insert(trait) } else { traits.remove(trait) }
            return font.fontDescriptor.withSymbolicTraits(traits).map { UIFont(descriptor: $0, size: font.pointSize) } ?? font
        }
    }
    func resizeFont(to size: CGFloat) { transformFonts { $0.withSize(max(1, size)) } }
    func changeFontSize(by delta: CGFloat) { transformFonts { $0.withSize(max(1, $0.pointSize + delta)) } }
    func paragraph(_ change: (NSMutableParagraphStyle) -> Void) {
        recordEdit { view in
            let range = (view.text as NSString).paragraphRange(for: view.selectedRange)
            let before = NSAttributedString(attributedString: view.attributedText)
            var typing = view.typingAttributes
            before.enumerateAttribute(.paragraphStyle, in: range) { value, span, _ in
                let style = ((value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
                change(style)
                view.textStorage.addAttribute(.paragraphStyle, value: style, range: span)
            }
            let style = ((typing[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
            change(style)
            typing[.paragraphStyle] = style
            view.typingAttributes = typing
        }
    }
}

struct RichTextEditor: UIViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled
    let state: RichTextState
    let attach: () -> Void
    let photos: () -> Void
    var canAttach = true

    func makeCoordinator() -> Coordinator { Coordinator(state: state, attach: attach, photos: photos) }
    func makeUIView(context: Context) -> QuotedTextView {
        let view = QuotedTextView(usingTextLayoutManager: true)
        view.backgroundColor = .clear
        view.font = .preferredFont(forTextStyle: .body)
        view.textColor = .label
        view.adjustsFontForContentSizeCategory = true
        view.isScrollEnabled = false
        view.textContainerInset = UIEdgeInsets(top: 12, left: 0, bottom: 20, right: 0)
        view.textContainer.lineFragmentPadding = 0
        view.allowsEditingTextAttributes = true
        view.writingToolsBehavior = .none
        view.accessibilityLabel = "Message body"
        view.delegate = context.coordinator
        state.view = view
        context.coordinator.installKeyboard(on: view)
        return view
    }
    func updateUIView(_ view: QuotedTextView, context: Context) {
        view.isEditable = isEnabled
        context.coordinator.attachmentButton?.isEnabled = isEnabled && canAttach
        if !view.attributedText.isEqual(to: state.text) {
            // UITextView changes selection while assigning content. Do not feed that temporary range back into the draft.
            let range = state.selection
            let typing = state.typing
            context.coordinator.updating = true
            view.attributedText = state.text
            let location = min(range.location, view.attributedText.length)
            view.selectedRange = NSRange(location: location, length: min(range.length, view.attributedText.length - location))
            view.typingAttributes = typing
            context.coordinator.updating = false
        }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: QuotedTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 300
        return CGSize(width: width, height: max(280, uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height))
    }
    static func dismantleUIView(_ view: QuotedTextView, coordinator: Coordinator) {
        coordinator.state.view = nil
        coordinator.state.presentFormatting = {}
        coordinator.state.didSync = {}
        view.delegate = nil
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        let state: RichTextState
        let attach: () -> Void
        let photos: () -> Void
        private var accessory: UIView?
        private var nativeFormat: NativeFormatting?
        fileprivate weak var attachmentButton: UIButton?
        var updating = false
        init(state: RichTextState, attach: @escaping () -> Void, photos: @escaping () -> Void) {
            self.state = state; self.attach = attach; self.photos = photos
        }
        func installKeyboard(on view: UITextView) {
            state.didSync = { [weak self] in
                self?.nativeFormat?.refreshDescriptor()
            }
            let accessory = UIView(frame: CGRect(x: 0, y: 0, width: 0, height: 62))
            accessory.autoresizingMask = [.flexibleWidth]
            let effect: UIVisualEffect
            if #available(iOS 26, *) {
                let glass = UIGlassEffect(style: .regular)
                glass.isInteractive = true
                effect = glass
            } else { effect = UIBlurEffect(style: .systemMaterial) }
            let panel = UIVisualEffectView(effect: effect)
            panel.translatesAutoresizingMaskIntoConstraints = false
            panel.layer.cornerRadius = 23
            panel.clipsToBounds = true
            accessory.addSubview(panel)
            let formatButton = UIButton(type: .system)
            formatButton.setTitle("Aa", for: .normal)
            formatButton.titleLabel?.font = .systemFont(ofSize: 22)
            formatButton.accessibilityLabel = "Format"
            formatButton.addAction(UIAction { [weak state] _ in state?.showFormat() }, for: .touchUpInside)
            let attachment = UIButton(type: .system)
            attachmentButton = attachment
            attachment.setImage(UIImage(systemName: "paperclip"), for: .normal)
            attachment.setPreferredSymbolConfiguration(.init(pointSize: 22), forImageIn: .normal)
            attachment.accessibilityLabel = "Attach"
            attachment.showsMenuAsPrimaryAction = true
            attachment.menu = UIMenu(children: [
                UIAction(title: "Attach File", image: UIImage(systemName: "doc")) { [attach] _ in attach() },
                UIAction(title: "Photo Library", image: UIImage(systemName: "photo.on.rectangle")) { [photos] _ in photos() }
            ])
            let stack = UIStackView(arrangedSubviews: [formatButton, attachment])
            stack.distribution = .fillEqually
            stack.translatesAutoresizingMaskIntoConstraints = false
            panel.contentView.addSubview(stack)
            NSLayoutConstraint.activate([
                panel.trailingAnchor.constraint(equalTo: accessory.trailingAnchor, constant: -16),
                panel.topAnchor.constraint(equalTo: accessory.topAnchor, constant: 4),
                panel.widthAnchor.constraint(equalToConstant: 128), panel.heightAnchor.constraint(equalToConstant: 46),
                stack.leadingAnchor.constraint(equalTo: panel.contentView.leadingAnchor, constant: 8),
                stack.trailingAnchor.constraint(equalTo: panel.contentView.trailingAnchor, constant: -8),
                stack.topAnchor.constraint(equalTo: panel.contentView.topAnchor),
                stack.bottomAnchor.constraint(equalTo: panel.contentView.bottomAnchor)
            ])
            formatButton.tintColor = .label; attachment.tintColor = .label
            view.inputAccessoryView = accessory
            self.accessory = accessory
            state.presentFormatting = { [weak self, weak view] in
                guard let self, let view, self.nativeFormat == nil else { return }
                let native = NativeFormatting(state: self.state) { [weak self] in self?.nativeFormat = nil }
                self.nativeFormat = native
                native.present(from: view)
            }
        }
        func textViewDidBeginEditing(_ textView: UITextView) { state.sync() }
        func textViewDidEndEditing(_ textView: UITextView) { state.sync() }
        func textViewDidChangeSelection(_ textView: UITextView) { if !updating { state.sync() } }
        func textViewDidChange(_ textView: UITextView) {
            state.edited = true
            state.sync()
            // The body grows inside the composer's scroll view; keep the caret above the keyboard.
            DispatchQueue.main.async { [weak textView] in
                guard let textView, let range = textView.selectedTextRange else { return }
                var ancestor = textView.superview
                while let parent = ancestor {
                    if let scroll = parent as? UIScrollView {
                        let caret = textView.convert(textView.caretRect(for: range.end), to: scroll).insetBy(dx: 0, dy: -20)
                        scroll.scrollRectToVisible(caret, animated: false)
                        break
                    }
                    ancestor = parent.superview
                }
            }
        }
    }
}


final class QuotedTextView: UITextView {
    private let quoteLines = CAShapeLayer()
    override func layoutSubviews() {
        super.layoutSubviews()
        if quoteLines.superlayer == nil { layer.addSublayer(quoteLines) }
        let path = UIBezierPath()
        attributedText.enumerateAttribute(RichText.quote, in: NSRange(location: 0, length: attributedText.length)) { value, range, _ in
            guard value as? Bool == true,
                  let start = position(from: beginningOfDocument, offset: range.location),
                  let end = position(from: start, offset: range.length),
                  let textRange = textRange(from: start, to: end) else { return }
            let rects = selectionRects(for: textRange).map(\.rect).filter { !$0.isEmpty }
            guard let top = rects.map(\.minY).min(), let bottom = rects.map(\.maxY).max() else { return }
            path.move(to: CGPoint(x: 1, y: top)); path.addLine(to: CGPoint(x: 1, y: bottom))
        }
        quoteLines.path = path.cgPath
        quoteLines.strokeColor = UIColor.systemPurple.cgColor
        quoteLines.lineWidth = 1
    }
}

struct RichMessageText: UIViewRepresentable {
    let text: NSAttributedString
    func makeUIView(context: Context) -> QuotedTextView {
        let view = QuotedTextView(usingTextLayoutManager: true)
        view.backgroundColor = .clear
        view.isEditable = false
        view.isScrollEnabled = false
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        return view
    }
    func updateUIView(_ view: QuotedTextView, context: Context) { view.attributedText = text }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: QuotedTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 300
        return uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
    }
}
