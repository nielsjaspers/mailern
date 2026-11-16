import SwiftUI

struct ThreadView: View {
    @Environment(MailStore.self) private var store
    @Environment(DraftStore.self) private var drafts
    @Environment(\.dismiss) private var dismiss
    let id: UUID
    @Namespace private var composeTransition
    @State private var mode: ComposeMode?
    @State private var snooze = false
    @State private var deleting = false
    private var attachedDrafts: [ComposerDraft] { drafts.drafts.filter { $0.mode.replyID == id }.sorted { $0.updatedAt < $1.updatedAt } }
    var body: some View {
        Group {
            if let c = store.conversation(id) {
                ConversationContent(conversation: c, drafts: attachedDrafts, editDraft: { mode = .draft($0) }, discardDraft: { draftID in
                    Task {
                        deleting = true
                        defer { deleting = false }
                        await drafts.delete(draftID)
                    }
                }, deletingDraft: deleting)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button(c.pinned ? "Unpin" : "Pin", systemImage: "pin") { store.togglePin(id) }
                            if c.workflow != .settled {
                                Button("Mark unread", systemImage: "envelope.badge") { store.markRead(id, unread: true); dismiss() }
                            }
                            Button("Snooze", systemImage: "clock") { snooze = true }.disabled(!attachedDrafts.isEmpty)
                            if c.workflow != .inbox && attachedDrafts.isEmpty { Button("Restore to Inbox", systemImage: "tray") { store.move(id, to: .inbox); dismiss() } }
                            Divider()
                            Button("Simulate incoming reply", systemImage: "arrow.down.message") { store.receiveReply(id) }
                        } label: { Label("More actions", systemImage: "ellipsis.circle") }
                    }
                    ToolbarItemGroup(placement: .bottomBar) {
                        Button(c.workflow == .settled ? "Restore" : "Settle", systemImage: c.workflow == .settled ? "tray" : "checkmark") {
                            store.move(id, to: c.workflow == .settled ? .inbox : .settled)
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            dismiss()
                        }.disabled(!attachedDrafts.isEmpty)
                        Spacer()
                        Button("Snooze", systemImage: "clock") { snooze = true }.disabled(!attachedDrafts.isEmpty)
                        Spacer()
                        Menu {
                            Button("Reply") { mode = .reply(id) }
                            Button("Reply All") { mode = .replyAll(id) }
                            Button("Forward") { mode = .forward(id) }
                        } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }
                        .modifier(ComposerSource(source: "reply", namespace: composeTransition))
                    }
                }
            } else { ContentUnavailableView("Conversation unavailable", systemImage: "envelope") }
        }
        .toolbar(.hidden, for: .tabBar)
        .onAppear { store.markRead(id) }
        .sheet(item: $mode) { mode in
            if case .draft = mode { ComposerView(mode: mode) }
            else { ComposerView(mode: mode).modifier(ComposerTransition(source: "reply", namespace: composeTransition)) }
        }
        .modifier(DraftStorageAlert(active: mode == nil))
        .sheet(isPresented: $snooze) { SnoozeView(ids: [id], onSnooze: { dismiss() }) }
    }
}
