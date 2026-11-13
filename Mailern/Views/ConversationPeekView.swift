import SwiftUI

struct ConversationPeekView: View {
    @Environment(MailStore.self) private var store
    @Binding var presentedID: UUID?
    let id: UUID
    let onOpen: () -> Void
    @State private var snooze = false

    var body: some View {
        Group {
            if let conversation = store.conversation(id) {
                VStack(spacing: 0) {
                    ConversationContent(conversation: conversation)
                        .frame(minHeight: 100, idealHeight: 220, maxHeight: 220)
                    Divider()
                    VStack(spacing: 0) {
                        action("Open conversation", symbol: "envelope.open") {
                            presentedID = nil
                            onOpen()
                        }
                        Divider()
                        HStack(spacing: 0) {
                            action(conversation.unread ? "Mark read" : "Mark unread", symbol: conversation.unread ? "envelope.open" : "envelope.badge") {
                                presentedID = nil
                                store.markRead(id, unread: !conversation.unread)
                            }
                            action(conversation.workflow == .settled ? "Restore" : "Settle", symbol: conversation.workflow == .settled ? "tray" : "checkmark") {
                                presentedID = nil
                                store.move(id, to: conversation.workflow == .settled ? .inbox : .settled)
                            }
                        }
                        HStack(spacing: 0) {
                            action("Snooze", symbol: "clock") { snooze = true }
                            action(conversation.pinned ? "Unpin" : "Pin", symbol: conversation.pinned ? "pin.slash" : "pin") {
                                presentedID = nil
                                store.togglePin(id)
                            }
                        }
                        if conversation.workflow == .snoozed {
                            action("Restore to Inbox", symbol: "tray") {
                                presentedID = nil
                                store.move(id, to: .inbox)
                            }
                        }
                    }
                }
            } else {
                ContentUnavailableView("Conversation unavailable", systemImage: "envelope")
            }
        }
        .frame(width: 320)
        .sheet(isPresented: $snooze) { SnoozeView(id: id, beforeSnooze: { presentedID = nil }) }
    }

    private func action(_ title: String, symbol: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Label(title, systemImage: symbol)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
    }
}
