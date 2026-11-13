import SwiftUI

// The preview needs its own scroll view, so its menu uses public glass rendering
// and native control/gesture cancellation rather than UIKit's modal context-menu presenter.
enum PeekTool: Hashable {
    case reply, replyAll, forward, read, settle, snooze, pin, restore
}

struct PeekToolsView: UIViewRepresentable {
    let conversation: Conversation
    let offset: CGFloat
    let expanded: Bool
    let onToggle: () -> Void
    let onResize: (CGFloat) -> Void
    let onResizeEnd: (CGFloat) -> Void
    let onHeight: (CGFloat) -> Void
    let onAction: (PeekTool) -> Void

    func makeUIView(context: Context) -> PeekToolsSurface { PeekToolsSurface() }

    func updateUIView(_ view: PeekToolsSurface, context: Context) {
        view.onToggle = onToggle
        view.onResize = onResize
        view.onResizeEnd = onResizeEnd
        view.onHeight = onHeight
        view.onAction = onAction
        view.update(conversation: conversation, expanded: expanded, offset: offset)
    }
}

final class PeekToolsSurface: UIView {
    var onToggle: () -> Void = {}
    var onResize: (CGFloat) -> Void = { _ in }
    var onResizeEnd: (CGFloat) -> Void = { _ in }
    var onHeight: (CGFloat) -> Void = { _ in }
    var onAction: (PeekTool) -> Void = { _ in }
    private let stack = UIStackView()
    private let handle = UIButton(type: .system)
    private var top: NSLayoutConstraint!
    private var buttons: [PeekTool: UIButton] = [:]
    private var selected: PeekTool?
    private var previous: Conversation?
    private var measuredHeight: CGFloat = 0
    private let feedback = UISelectionFeedbackGenerator()

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "peek-tools"
        shouldGroupAccessibilityChildren = true
        layer.cornerRadius = 28
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
            stack.leadingAnchor.constraint(equalTo: background.contentView.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: background.contentView.trailingAnchor, constant: -8), top
        ])
        handle.accessibilityIdentifier = "peek-menu-handle"
        handle.addTarget(self, action: #selector(toggle), for: .touchUpInside)
        handle.heightAnchor.constraint(equalToConstant: 44).isActive = true
        let grip = UIView()
        grip.backgroundColor = .secondaryLabel
        grip.layer.cornerRadius = 2
        grip.isUserInteractionEnabled = false
        grip.translatesAutoresizingMaskIntoConstraints = false
        handle.addSubview(grip)
        NSLayoutConstraint.activate([
            grip.widthAnchor.constraint(equalToConstant: 32), grip.heightAnchor.constraint(equalToConstant: 4),
            grip.centerXAnchor.constraint(equalTo: handle.centerXAnchor), grip.centerYAnchor.constraint(equalTo: handle.centerYAnchor)
        ])
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(track(_:)))
        hold.minimumPressDuration = 0.3
        hold.allowableMovement = 12
        addGestureRecognizer(hold)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(resize(_:)))
        pan.require(toFail: hold)
        addGestureRecognizer(pan)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(conversation: Conversation, expanded: Bool, offset: CGFloat) {
        handle.accessibilityLabel = expanded ? "Show more message" : "Show tools"
        top.constant = -offset
        if previous?.unread != conversation.unread || previous?.pinned != conversation.pinned || previous?.workflow != conversation.workflow {
            rebuild(conversation)
        }
        previous = conversation
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let height = stack.systemLayoutSizeFitting(
            CGSize(width: max(0, bounds.width - 16), height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel
        ).height + 10
        if abs(height - measuredHeight) > 0.5 {
            measuredHeight = height
            DispatchQueue.main.async { [weak self] in self?.onHeight(height) }
        }
    }

    private func rebuild(_ conversation: Conversation) {
        select(nil)
        for view in stack.arrangedSubviews { stack.removeArrangedSubview(view); view.removeFromSuperview() }
        buttons = [:]
        stack.addArrangedSubview(handle)
        let replies = UIStackView(arrangedSubviews: [
            button(.reply, "Reply", "arrowshape.turn.up.left", iconOnly: true),
            button(.replyAll, "Reply All", "arrowshape.turn.up.left.2", iconOnly: true),
            button(.forward, "Forward", "arrowshape.turn.up.right", iconOnly: true)
        ])
        replies.distribution = .fillEqually
        stack.addArrangedSubview(replies)
        let divider = UIView()
        divider.backgroundColor = .separator
        divider.heightAnchor.constraint(equalToConstant: 0.5).isActive = true
        stack.addArrangedSubview(divider)
        stack.addArrangedSubview(button(.read, conversation.unread ? "Mark read" : "Mark unread", conversation.unread ? "envelope.open" : "envelope.badge"))
        stack.addArrangedSubview(button(.settle, conversation.workflow == .settled ? "Restore to Inbox" : "Settle", conversation.workflow == .settled ? "tray" : "checkmark"))
        stack.addArrangedSubview(button(.snooze, "Snooze", "clock"))
        stack.addArrangedSubview(button(.pin, conversation.pinned ? "Unpin" : "Pin", conversation.pinned ? "pin.slash" : "pin"))
        if conversation.workflow == .snoozed { stack.addArrangedSubview(button(.restore, "Restore to Inbox", "tray")) }
    }

    private func button(_ tool: PeekTool, _ title: String, _ symbol: String, iconOnly: Bool = false) -> UIButton {
        let button = UIButton(type: .system)
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: symbol)
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: iconOnly ? 22 : 20)
        config.title = iconOnly ? nil : title
        config.imagePadding = 12
        config.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFont.preferredFont(forTextStyle: .body)
            return attributes
        }
        config.background.cornerRadius = 18
        button.configuration = config
        button.tintColor = .label
        button.contentHorizontalAlignment = iconOnly ? .center : .leading
        button.titleLabel?.numberOfLines = 0
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.accessibilityLabel = title
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: iconOnly ? 52 : 48).isActive = true
        button.configurationUpdateHandler = { button in
            button.configuration?.background.backgroundColor = button.isHighlighted || button.isSelected ? UIColor.label.withAlphaComponent(0.12) : .clear
        }
        button.addAction(UIAction { [weak self] _ in self?.onAction(tool) }, for: .touchUpInside)
        buttons[tool] = button
        return button
    }

    @objc private func toggle() { onToggle() }

    @objc private func resize(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: window).y
        switch gesture.state {
        case .began, .changed: onResize(translation)
        case .ended: onResizeEnd(translation + gesture.velocity(in: window).y * 0.12)
        case .cancelled: onResizeEnd(translation)
        default: break
        }
    }

    @objc private func track(_ gesture: UILongPressGestureRecognizer) {
        let point = gesture.location(in: self)
        let tool = bounds.contains(point) ? buttons.first(where: { $0.value.convert($0.value.bounds, to: self).contains(point) })?.key : nil
        switch gesture.state {
        case .began, .changed: select(tool)
        case .ended:
            select(nil)
            if let tool { onAction(tool) }
        case .cancelled, .failed: select(nil)
        default: break
        }
    }

    private func select(_ tool: PeekTool?) {
        guard selected != tool else { return }
        // A recognized hold cancels the button's normal touch highlight.
        if let selected { buttons[selected]?.isSelected = false }
        selected = tool
        if let tool {
            buttons[tool]?.isSelected = true
            feedback.selectionChanged()
        }
    }
}
