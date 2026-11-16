import SwiftUI

enum PeekTool {
    case reply, replyAll, forward, read, settle, snooze, pin, restore
}

struct PeekToolsView: UIViewRepresentable {
    let conversation: Conversation
    var hasDraft = false
    let offset: CGFloat
    let onResize: (CGFloat) -> Void
    let onResizeEnd: (CGFloat) -> Void
    let onHeight: (CGFloat) -> Void
    let onAction: (PeekTool) -> Void

    func makeUIView(context: Context) -> PeekToolsSurface { PeekToolsSurface() }

    func updateUIView(_ view: PeekToolsSurface, context: Context) {
        view.onResize = onResize
        view.onResizeEnd = onResizeEnd
        view.onHeight = onHeight
        view.onAction = onAction
        view.update(conversation: conversation, hasDraft: hasDraft, offset: offset)
    }
}

// UIKit's context-menu preview is noninteractive. Keep the scrollable preview
// separate, while using native controls and glass for its companion actions.
final class PeekToolsSurface: UIView {
    var onResize: (CGFloat) -> Void = { _ in }
    var onResizeEnd: (CGFloat) -> Void = { _ in }
    var onHeight: (CGFloat) -> Void = { _ in }
    var onAction: (PeekTool) -> Void = { _ in }
    private let stack = UIStackView()
    private var top: NSLayoutConstraint!
    private var previous: Conversation?
    private var hasDraft = false
    private var measuredHeight: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "peek-tools"
        shouldGroupAccessibilityChildren = true
        layer.cornerRadius = 32
        layer.cornerCurve = .continuous
        clipsToBounds = true
        let effect: UIVisualEffect
        if #available(iOS 26, *) {
            let glass = UIGlassEffect(style: .regular)
            glass.isInteractive = true
            effect = glass
        } else {
            effect = UIBlurEffect(style: .systemMaterial)
        }
        let background = UIVisualEffectView(effect: effect)
        background.translatesAutoresizingMaskIntoConstraints = false
        addSubview(background)
        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        stack.axis = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.contentView.addSubview(stack)
        top = stack.topAnchor.constraint(equalTo: background.contentView.topAnchor)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.contentView.trailingAnchor), top
        ])
        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(resize(_:))))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(conversation: Conversation, hasDraft: Bool, offset: CGFloat) {
        top.constant = -offset
        if self.hasDraft != hasDraft || previous?.unread != conversation.unread || previous?.pinned != conversation.pinned || previous?.workflow != conversation.workflow {
            self.hasDraft = hasDraft
            rebuild(conversation)
        }
        previous = conversation
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let height = stack.systemLayoutSizeFitting(
            CGSize(width: bounds.width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel
        ).height
        if abs(height - measuredHeight) > 0.5 {
            measuredHeight = height
            DispatchQueue.main.async { [weak self] in self?.onHeight(height) }
        }
    }

    private func rebuild(_ conversation: Conversation) {
        for view in stack.arrangedSubviews { stack.removeArrangedSubview(view); view.removeFromSuperview() }
        let replies = UIStackView(arrangedSubviews: [
            reply(.reply, "Reply", "arrowshape.turn.up.left"),
            reply(.replyAll, "Reply All", "arrowshape.turn.up.left.2"),
            reply(.forward, "Forward", "arrowshape.turn.up.right")
        ])
        replies.distribution = .fillEqually
        let header = UIView()
        replies.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(replies)
        NSLayoutConstraint.activate([
            replies.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 8),
            replies.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -8),
            replies.topAnchor.constraint(equalTo: header.topAnchor, constant: 17),
            replies.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -16)
        ])
        stack.addArrangedSubview(header)
        let separator = UIView()
        let line = UIView()
        line.backgroundColor = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        separator.addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: separator.leadingAnchor, constant: 24),
            line.trailingAnchor.constraint(equalTo: separator.trailingAnchor, constant: -24),
            line.topAnchor.constraint(equalTo: separator.topAnchor),
            line.heightAnchor.constraint(equalToConstant: 0.5),
            line.bottomAnchor.constraint(equalTo: separator.bottomAnchor, constant: -10)
        ])
        stack.addArrangedSubview(separator)
        stack.addArrangedSubview(row(.read, conversation.unread ? "Mark read" : "Mark unread", conversation.unread ? "envelope.open" : "envelope.badge"))
        stack.addArrangedSubview(row(.settle, conversation.workflow == .settled ? "Restore to Inbox" : "Settle", conversation.workflow == .settled ? "tray" : "checkmark"))
        stack.addArrangedSubview(row(.snooze, "Snooze", "clock"))
        stack.addArrangedSubview(row(.pin, conversation.pinned ? "Unpin" : "Pin", conversation.pinned ? "pin.slash" : "pin"))
        if conversation.workflow == .snoozed { stack.addArrangedSubview(row(.restore, "Restore to Inbox", "tray")) }
        let bottom = UIView()
        bottom.heightAnchor.constraint(equalToConstant: 14).isActive = true
        stack.addArrangedSubview(bottom)
    }

    private func button(_ tool: PeekTool, _ title: String) -> UIButton {
        let button = UIButton(type: .system)
        var config = UIButton.Configuration.plain()
        config.background.cornerRadius = 22
        config.background.backgroundInsets = NSDirectionalEdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8)
        button.configuration = config
        button.tintColor = .label
        button.accessibilityLabel = title
        if hasDraft && [.settle, .snooze, .restore].contains(tool) { button.isEnabled = false; button.alpha = 0.4 }
        button.configurationUpdateHandler = { button in
            button.configuration?.background.backgroundColor = button.isHighlighted ? UIColor.label.withAlphaComponent(0.12) : .clear
        }
        button.addAction(UIAction { [weak self] _ in self?.onAction(tool) }, for: .touchUpInside)
        return button
    }

    private func reply(_ tool: PeekTool, _ title: String, _ symbol: String) -> UIButton {
        let button = button(tool, title)
        button.configuration?.image = UIImage(systemName: symbol)
        button.configuration?.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 21, weight: .regular, scale: .small)
        button.configuration?.contentInsets = .zero
        button.heightAnchor.constraint(equalToConstant: 44).isActive = true
        return button
    }

    private func row(_ tool: PeekTool, _ title: String, _ symbol: String) -> UIButton {
        let button = button(tool, title)
        let image = UIImageView(image: UIImage(systemName: symbol))
        image.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 17)
        image.contentMode = .center
        image.widthAnchor.constraint(equalToConstant: 24).isActive = true
        image.heightAnchor.constraint(equalToConstant: 24).isActive = true
        let label = UILabel()
        label.text = title
        label.font = .preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        let content = UIStackView(arrangedSubviews: [image, label])
        content.spacing = 16
        content.alignment = .center
        content.isUserInteractionEnabled = false
        content.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 24),
            content.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -24),
            content.topAnchor.constraint(equalTo: button.topAnchor, constant: 10),
            content.bottomAnchor.constraint(equalTo: button.bottomAnchor, constant: -10),
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        ])
        return button
    }

    @objc private func resize(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: window).y
        switch gesture.state {
        case .began, .changed: onResize(translation)
        case .ended: onResizeEnd(translation + gesture.velocity(in: window).y * 0.12)
        case .cancelled: onResizeEnd(translation)
        default: break
        }
    }
}
