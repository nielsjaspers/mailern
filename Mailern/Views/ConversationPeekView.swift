import SwiftUI

struct ConversationPeekView: View {
    @Environment(MailStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let id: UUID
    let onOpen: () -> Void
    @State private var snooze = false

    var body: some View {
        NavigationStack {
            Group {
                if let conversation = store.conversation(id) {
                    ConversationContent(conversation: conversation)
                        .toolbar {
                            ToolbarItemGroup(placement: .bottomBar) {
                                Button(
                                    conversation.unread ? "Mark read" : "Mark unread",
                                    systemImage: conversation.unread ? "envelope.open" : "envelope.badge"
                                ) {
                                    store.markRead(id, unread: !conversation.unread)
                                    dismiss()
                                }
                                Spacer()
                                if conversation.workflow != .settled {
                                    Button("Settle", systemImage: "checkmark") {
                                        store.move(id, to: .settled)
                                        dismiss()
                                    }
                                    Spacer()
                                }
                                if conversation.workflow != .inbox {
                                    Button("Restore to Inbox", systemImage: "tray") {
                                        store.move(id, to: .inbox)
                                        dismiss()
                                    }
                                    Spacer()
                                }
                                Button("Snooze", systemImage: "clock") { snooze = true }
                                Spacer()
                                Button(
                                    conversation.pinned ? "Unpin" : "Pin",
                                    systemImage: conversation.pinned ? "pin.slash" : "pin"
                                ) {
                                    store.togglePin(id)
                                    dismiss()
                                }
                            }
                        }
                } else {
                    ContentUnavailableView("Conversation unavailable", systemImage: "envelope")
                }
            }
            .navigationTitle("Peek")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Open") {
                        dismiss()
                        onOpen()
                    }
                    .disabled(store.conversation(id) == nil)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .sheet(isPresented: $snooze) { SnoozeView(id: id, onSnooze: { dismiss() }) }
    }
}
