import SwiftUI

struct ConversationPeekView: View {
    @Environment(MailStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let conversation: Conversation
    let onDismiss: () -> Void
    let onOpen: () -> Void
    let onCompose: (ComposeMode) -> Void
    let onSnooze: () -> Void
    @State private var toolsHeight: CGFloat = 300
    @State private var menuPosition: CGFloat?
    @State private var dragOrigin: CGFloat?
    @AccessibilityFocusState private var previewFocused: Bool

    var body: some View {
        GeometryReader { geometry in
            let width = min(geometry.size.width - 32, 440)
            let menuHeight = min(toolsHeight, geometry.size.height * 0.5)
            let compactHeight = max(80, geometry.size.height - menuHeight - 48)
            // Keep the reply shortcuts visible while the remaining actions sit below the screen.
            let menuTeaser = max(44, 84 - geometry.safeAreaInsets.bottom)
            let largeHeight = max(compactHeight, geometry.size.height - 32 - menuTeaser)
            let travel = largeHeight - compactHeight
            let maximum = travel + max(0, toolsHeight - menuHeight)
            let position = menuPosition ?? travel
            let previewHeight = largeHeight - min(position, travel)

            ZStack(alignment: .top) {
                Button(action: onDismiss) {
                    Color.black.opacity(0.32).ignoresSafeArea()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss peek")
                .accessibilitySortPriority(-1)

                VStack(alignment: .leading, spacing: 16) {
                    ConversationContent(conversation: conversation, isPreview: true)
                        .frame(height: previewHeight)
                        .clipShape(RoundedRectangle(cornerRadius: 26))
                        .overlay {
                            RoundedRectangle(cornerRadius: 26)
                                .strokeBorder(.primary.opacity(0.1), lineWidth: 0.5)
                                .allowsHitTesting(false)
                        }
                        .shadow(color: .black.opacity(0.25), radius: 20, y: 8)
                        .contentShape(RoundedRectangle(cornerRadius: 26))
                        .highPriorityGesture(TapGesture().onEnded { onOpen() })
                        .environment(\.openURL, OpenURLAction { _ in onOpen(); return .handled })
                        .accessibilityIdentifier("peek-preview")
                        .accessibilityLabel("Conversation preview")
                        .accessibilityValue(conversation.unread ? "Unread" : "Read")
                        .accessibilityHint("Opens the conversation")
                        .accessibilityAction { onOpen() }
                        .accessibilityAction(named: Text(position < travel ? "Show tools" : "Expand message preview")) {
                            animate { menuPosition = position < travel ? travel : 0 }
                        }
                        .accessibilityFocused($previewFocused)

                    PeekToolsView(
                        conversation: conversation,
                        offset: max(0, position - travel),
                        onResize: { translation in
                            if dragOrigin == nil { dragOrigin = position }
                            menuPosition = min(maximum, max(0, (dragOrigin ?? 0) - translation))
                        },
                        onResizeEnd: { prediction in
                            let destination = min(maximum, max(0, (dragOrigin ?? position) - prediction))
                            dragOrigin = nil
                            animate {
                                menuPosition = destination < travel ? (destination > travel / 2 ? travel : 0) : destination
                            }
                        },
                        onHeight: { toolsHeight = $0 },
                        onAction: perform
                    )
                    .frame(width: min(250, width), height: menuHeight)
                    .shadow(color: .black.opacity(0.22), radius: 20, y: 8)
                    .accessibilityScrollAction { edge in
                        animate { menuPosition = min(maximum, max(0, position + (edge == .bottom ? 100 : -100))) }
                    }
                }
                .frame(width: width)
                .padding(.top, 16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .onAppear {
                previewFocused = true
            }
            .onChange(of: maximum) { _, value in
                if let menuPosition { self.menuPosition = min(menuPosition, value) }
            }
            .onChange(of: geometry.size) { _, _ in
                dragOrigin = nil
                menuPosition = nil
            }
        }
        .accessibilityAction(.escape, onDismiss)
    }

    private func animate(_ changes: () -> Void) {
        withAnimation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.86), changes)
    }

    private func perform(_ tool: PeekTool) {
        switch tool {
        case .reply: onCompose(.reply(conversation.id))
        case .replyAll: onCompose(.replyAll(conversation.id))
        case .forward: onCompose(.forward(conversation.id))
        case .snooze: onSnooze()
        case .read:
            onDismiss()
            store.markRead(conversation.id, unread: !conversation.unread)
        case .settle:
            onDismiss()
            store.move(conversation.id, to: conversation.workflow == .settled ? .inbox : .settled)
        case .pin:
            onDismiss()
            store.togglePin(conversation.id)
        case .restore:
            onDismiss()
            store.move(conversation.id, to: .inbox)
        }
    }
}
