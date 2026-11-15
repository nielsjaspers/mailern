import SwiftUI

struct ThreadView: View {
    @Environment(MailStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let id: UUID
    @State private var mode: ComposeMode?
    @State private var snooze = false
    var body: some View {
        Group {
            if let c = store.conversation(id) {
                ConversationContent(conversation: c)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button(c.pinned ? "Unpin" : "Pin", systemImage: "pin") { store.togglePin(id) }
                            Button("Mark unread", systemImage: "envelope.badge") { store.markRead(id, unread: true); dismiss() }
                            Button("Snooze", systemImage: "clock") { snooze = true }
                            if c.workflow != .inbox { Button("Restore to Inbox", systemImage: "tray") { store.move(id, to: .inbox); dismiss() } }
                            Divider()
                            Button("Simulate incoming reply", systemImage: "arrow.down.message") { store.receiveReply(id) }
                        } label: { Label("More actions", systemImage: "ellipsis.circle") }
                    }
                    ToolbarItemGroup(placement: .bottomBar) {
                        Button(c.workflow == .settled ? "Restore" : "Settle", systemImage: c.workflow == .settled ? "tray" : "checkmark") {
                            store.move(id, to: c.workflow == .settled ? .inbox : .settled)
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            dismiss()
                        }
                        Spacer()
                        Button("Snooze", systemImage: "clock") { snooze = true }
                        Spacer()
                        Menu {
                            Button("Reply") { mode = .reply(id) }
                            Button("Reply All") { mode = .replyAll(id) }
                            Button("Forward") { mode = .forward(id) }
                        } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }
                    }
                }
            } else { ContentUnavailableView("Conversation unavailable", systemImage: "envelope") }
        }
        .toolbar(.hidden, for: .tabBar)
        .onAppear { store.markRead(id) }
        .sheet(item: $mode) { ComposerView(mode: $0) }
        .sheet(isPresented: $snooze) { SnoozeView(ids: [id], onSnooze: { dismiss() }) }
    }
}
