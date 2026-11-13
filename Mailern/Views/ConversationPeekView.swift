import SwiftUI

struct ConversationPeekView: View {
    @Environment(MailStore.self) private var store
    let conversation: Conversation
    let onDismiss: () -> Void
    let onOpen: () -> Void
    let onCompose: (ComposeMode) -> Void
    let onSnooze: () -> Void
    @State private var toolsHeight: CGFloat = 280
    @AccessibilityFocusState private var previewFocused: Bool

    var body: some View {
        GeometryReader { geometry in
            let width = min(geometry.size.width - 32, 440)
            let visibleToolsHeight = min(toolsHeight, geometry.size.height * 0.48)
            let previewHeight = min(380, max(80, geometry.size.height - visibleToolsHeight - 48))

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
                        .accessibilityFocused($previewFocused)

                    ScrollView {
                        tools
                            .background {
                                GeometryReader { content in
                                    Color.clear.preference(key: PeekToolsHeight.self, value: content.size.height)
                                }
                            }
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(width: min(300, width * 0.78), height: visibleToolsHeight)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28))
                    .overlay {
                        RoundedRectangle(cornerRadius: 28)
                            .strokeBorder(.primary.opacity(0.12), lineWidth: 0.5)
                            .allowsHitTesting(false)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 28))
                    .shadow(color: .black.opacity(0.22), radius: 20, y: 8)
                    .accessibilityIdentifier("peek-tools")
                }
                .frame(width: width)
                .padding(.top, 16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onPreferenceChange(PeekToolsHeight.self) { toolsHeight = $0 }
        }
        .accessibilityAction(.escape, onDismiss)
        .onAppear { previewFocused = true }
    }

    private var tools: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                reply("Reply", symbol: "arrowshape.turn.up.left", mode: .reply(conversation.id))
                reply("Reply All", symbol: "arrowshape.turn.up.left.2", mode: .replyAll(conversation.id))
                reply("Forward", symbol: "arrowshape.turn.up.right", mode: .forward(conversation.id))
            }
            .padding(.horizontal, 10)
            Divider().padding(.horizontal, 18)
            action(conversation.unread ? "Mark read" : "Mark unread", symbol: conversation.unread ? "envelope.open" : "envelope.badge") {
                onDismiss()
                store.markRead(conversation.id, unread: !conversation.unread)
            }
            Divider().padding(.leading, 18)
            action(conversation.workflow == .settled ? "Restore to Inbox" : "Settle", symbol: conversation.workflow == .settled ? "tray" : "checkmark") {
                onDismiss()
                store.move(conversation.id, to: conversation.workflow == .settled ? .inbox : .settled)
            }
            Divider().padding(.leading, 18)
            action("Snooze", symbol: "clock", perform: onSnooze)
            Divider().padding(.leading, 18)
            action(conversation.pinned ? "Unpin" : "Pin", symbol: conversation.pinned ? "pin.slash" : "pin") {
                onDismiss()
                store.togglePin(conversation.id)
            }
            if conversation.workflow == .snoozed {
                Divider().padding(.leading, 18)
                action("Restore to Inbox", symbol: "tray") {
                    onDismiss()
                    store.move(conversation.id, to: .inbox)
                }
            }
        }
        .foregroundStyle(.primary)
    }

    private func reply(_ title: String, symbol: String, mode: ComposeMode) -> some View {
        Button { onCompose(mode) } label: {
            Label(title, systemImage: symbol)
                .labelStyle(.iconOnly)
                .font(.system(size: 22))
                .frame(maxWidth: .infinity, minHeight: 60)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func action(_ title: String, symbol: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            HStack(spacing: 12) {
                Image(systemName: symbol).frame(width: 24)
                Text(title).frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.body)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct PeekToolsHeight: PreferenceKey {
    static var defaultValue: CGFloat = 280
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
