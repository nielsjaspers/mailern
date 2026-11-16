import UIKit

@MainActor final class NativeFormatting: NSObject, UITextFormattingViewController.Delegate, UIAdaptivePresentationControllerDelegate {
    private let state: RichTextState
    private let finish: () -> Void
    private let controller: UITextFormattingViewController
    private weak var textView: UITextView?
    private weak var composerView: UIView?
    private var previousInput: UIView?
    private var previousAccessory: UIView?
    private var finished = false
    private static let styles: [(String, String, UIFont)] = [
        ("title", "Title", .systemFont(ofSize: 28, weight: .bold)),
        ("subtitle", "Subtitle", .systemFont(ofSize: 22, weight: .semibold)),
        ("body", "Body", .systemFont(ofSize: 17)),
        ("caption", "Caption", .systemFont(ofSize: 13))
    ]
    init(state: RichTextState, finish: @escaping () -> Void) {
        self.state = state
        self.finish = finish
        func group(_ keys: [UITextFormattingViewController.ComponentKey]) -> UITextFormattingViewController.ComponentGroup {
            .init(components: keys.map { .init(componentKey: $0, preferredSize: .automatic) })
        }
        let config = UITextFormattingViewController.Configuration(groups: [
            group([.formattingStyles]), group([.fontAttributes, .textColor]),
            group([.fontPicker, .fontPointSize]), group([.listStyles, .textAlignment, .textIndentation])
        ])
        config.formattingStyles = Self.styles.map { key, name, font in
            .init(styleKey: key, title: LocalizedStringResource(stringLiteral: name), attributes: [.font: font])
        }
        controller = UITextFormattingViewController(configuration: config)
        super.init()
        controller.delegate = self
        controller.title = "Format"
    }
    func present(from textView: UITextView) {
        var responder: UIResponder? = textView
        while let current = responder, !(current is UIViewController) { responder = current.next }
        guard let presenter = responder as? UIViewController else { resume(); return }
        composerView = presenter.view
        state.sync()
        refreshDescriptor()
        self.textView = textView
        previousInput = textView.inputView
        previousAccessory = textView.inputAccessoryView
        // Keep native text selection active while Format replaces the software keyboard.
        textView.inputView = UIView(frame: .zero)
        textView.inputAccessoryView = nil
        textView.reloadInputViews()
        NotificationCenter.default.addObserver(self, selector: #selector(headerBeganEditing),
                                               name: UITextField.textDidBeginEditingNotification, object: nil)
        controller.modalPresentationStyle = .pageSheet
        if let sheet = controller.sheetPresentationController {
            let height = UISheetPresentationController.Detent.Identifier("format")
            sheet.detents = [.custom(identifier: height) { _ in 350 }]
            sheet.largestUndimmedDetentIdentifier = height
            sheet.prefersScrollingExpandsWhenScrolledToEdge = false
        }
        controller.presentationController?.delegate = self
        presenter.present(controller, animated: true)
    }
    func textFormattingViewController(_ viewController: UITextFormattingViewController, didChangeValue value: UITextFormattingViewController.ChangeValue) {
        switch value {
        case .bold(let enabled): state.setTrait(.traitBold, enabled: enabled)
        case .italic(let enabled): state.setTrait(.traitItalic, enabled: enabled)
        case .underline(let enabled): state.attribute(.underlineStyle, enabled ? NSUnderlineStyle.single.rawValue : 0)
        case .strikethrough(let enabled): state.attribute(.strikethroughStyle, enabled ? NSUnderlineStyle.single.rawValue : 0)
        case .font(let font): state.attribute(.font, font)
        case .fontSize(let size): state.resizeFont(to: size)
        case .increaseFontSize: state.changeFontSize(by: 1)
        case .decreaseFontSize: state.changeFontSize(by: -1)
        case .textColor(let color): state.attribute(.foregroundColor, color)
        case .textAlignment(let alignment): state.paragraph { $0.alignment = alignment.nsTextAlignment }
        case .textList(let list):
            let textList = list.map { value in
                let marker: NSTextList.MarkerFormat = value == .decimal ? .decimal : value == .hyphen ? .init(rawValue: "{hyphen}") : .disc
                return NSTextList(markerFormat: marker, options: 0)
            }
            state.paragraph { $0.textLists = textList.map { [$0] } ?? [] }
        case .increaseIndentation: state.paragraph { $0.headIndent = min(160, $0.headIndent + 20); $0.firstLineHeadIndent = $0.headIndent }
        case .decreaseIndentation: state.paragraph { $0.headIndent = max(0, $0.headIndent - 20); $0.firstLineHeadIndent = $0.headIndent }
        case .lineHeightPointSize(let height): state.paragraph { $0.minimumLineHeight = height; $0.maximumLineHeight = height }
        case .formattingStyle(let key):
            if let style = Self.styles.first(where: { $0.0 == key }) { state.attribute(.font, style.2) }
        case .undefined, .highlight: break // The configured panel does not offer highlights.
        @unknown default: break
        }
        refreshDescriptor()
    }
    func refreshDescriptor() {
        var descriptor = state.selection.length > 0
            ? UITextFormattingViewController.FormattingDescriptor(string: state.text, range: state.selection)
            : UITextFormattingViewController.FormattingDescriptor(attributes: state.attributes)
        descriptor.formattingStyleKey = descriptor.fonts.isEmpty ? nil : Self.styles.first { style in
            descriptor.fonts.allSatisfy {
                $0.pointSize == style.2.pointSize && $0.fontName == style.2.fontName
                    && $0.familyName == style.2.familyName
                    && $0.fontDescriptor.symbolicTraits == style.2.fontDescriptor.symbolicTraits
            }
        }?.0
        controller.formattingDescriptor = descriptor
    }
    func textFormattingDidFinish(_ viewController: UITextFormattingViewController) {
        viewController.dismiss(animated: true) { [weak self] in self?.resume() }
    }
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) { resume() }
    @objc private func headerBeganEditing(_ notification: Notification) {
        guard let field = notification.object as? UITextField, let composerView,
              field.isDescendant(of: composerView) else { return }
        controller.dismiss(animated: true) { [weak self] in self?.resume(focusBody: false) }
    }
    private func resume(focusBody: Bool = true) {
        guard !finished else { return }
        finished = true
        NotificationCenter.default.removeObserver(self)
        textView?.inputView = previousInput
        textView?.inputAccessoryView = previousAccessory
        textView?.reloadInputViews()
        if focusBody { textView?.becomeFirstResponder() }
        finish()
    }
}
