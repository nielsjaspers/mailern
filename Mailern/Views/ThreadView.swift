import SwiftUI

struct ThreadView: View {
    @Environment(MailStore.self) private var store
    @Environment(DraftStore.self) private var drafts
    @Environment(\.dismiss) private var dismiss
    let id: UUID
    @Namespace private var composeTransition
    @State private var mode: ComposeMode?
    // The message a per-message reply targets. Nil for the toolbar, which targets the latest.
    @State private var target: UUID?
    @State private var snooze = false
    @State private var deleting = false
    @State private var settling: DraftDiscard?
    @State private var deletingConversation = false
    private var attachedDrafts: [ComposerDraft] { drafts.drafts.filter { $0.mode.replyID == id }.sorted { $0.updatedAt < $1.updatedAt } }
    private func compose(_ mode: ComposeMode, message: UUID? = nil) {
        target = message
        self.mode = mode
    }
    private func remove(to mailbox: RemovedMailbox) {
        if !attachedDrafts.isEmpty { settling = DraftDiscard(ids: [id], action: .remove(mailbox)); return }
        store.apply(ids: [id], action: .remove(mailbox))
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        dismiss()
    }
    var body: some View {
        Group {
            if let c = store.conversation(id) {
                ConversationContent(conversation: c, drafts: attachedDrafts, editDraft: { mode = .draft($0) }, discardDraft: { draftID in
                    Task {
                        deleting = true
                        defer { deleting = false }
                        await drafts.delete(draftID)
                    }
                }, deletingDraft: deleting, compose: c.removal == nil ? { compose($0, message: $1) } : nil)
                // A mailto: link starts a message here. Other links go to the system, which opens web links in the browser.
                .environment(\.openURL, OpenURLAction { url in
                    guard let link = MailtoLink(url) else { return .systemAction }
                    compose(.mailto(link))
                    return .handled
                })
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            if c.removal == nil {
                                Button(c.pinned ? "Unpin" : "Pin", systemImage: "pin") { store.togglePin(id) }
                            }
                            if c.workflow != .settled {
                                Button("Mark unread", systemImage: "envelope.badge") { store.markRead(id, unread: true); dismiss() }
                            }
                            if c.removal == nil {
                                Button("Snooze", systemImage: "clock") { snooze = true }
                                if c.workflow != .inbox { Button("Restore to Inbox", systemImage: "tray") { store.move(id, to: .inbox); dismiss() } }
                                Button("Move to Junk", systemImage: RemovedMailbox.junk.symbol) { remove(to: .junk) }
                            }
                            Button(c.muted == true ? "Unmute" : "Mute", systemImage: c.muted == true ? "bell" : "bell.slash") { store.toggleMute(id) }
                            Divider()
                            Button("Simulate incoming reply", systemImage: "arrow.down.message") { store.receiveReply(id) }
                        } label: { Label("More actions", systemImage: "ellipsis.circle") }
                    }
                    ToolbarItemGroup(placement: .bottomBar) {
                        if let mailbox = c.removal?.mailbox {
                            Button(mailbox == .junk ? "Not Junk" : "Restore", systemImage: "arrow.uturn.backward") {
                                store.apply(ids: [id], action: .restoreRemoved)
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                dismiss()
                            }
                            Spacer()
                            Button("Delete Permanently", systemImage: "trash") { deletingConversation = true }
                        } else {
                            Button(c.workflow == .settled ? "Restore" : "Settle", systemImage: c.workflow == .settled ? "tray" : "checkmark") {
                                if c.workflow != .settled && !attachedDrafts.isEmpty { settling = DraftDiscard(ids: [id], action: .move(.settled)); return }
                                store.move(id, to: c.workflow == .settled ? .inbox : .settled)
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                dismiss()
                            }
                            Spacer()
                            Button("Snooze", systemImage: "clock") { snooze = true }
                            Spacer()
                            Button("Move to Trash", systemImage: RemovedMailbox.trash.symbol) { remove(to: .trash) }
                            Spacer()
                            Menu {
                                Button("Reply") { compose(.reply(id)) }
                                Button("Reply All") { compose(.replyAll(id)) }
                                Button("Forward") { compose(.forward(id)) }
                            } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }
                            .modifier(ComposerSource(source: "reply", namespace: composeTransition))
                        }
                    }
                }
            } else { ContentUnavailableView("Conversation unavailable", systemImage: "envelope") }
        }
        .toolbar(.hidden, for: .tabBar)
        .onAppear { store.markRead(id) }
        .sheet(item: $mode) { mode in
            switch mode {
            case .draft, .mailto: ComposerView(mode: mode)
            // The zoom transition belongs to the toolbar's Reply button.
            default:
                if target != nil { ComposerView(mode: mode, messageID: target) }
                else { ComposerView(mode: mode).modifier(ComposerTransition(source: "reply", namespace: composeTransition)) }
            }
        }
        .modifier(DraftStorageAlert(active: mode == nil))
        .modifier(DiscardDraftsConfirmation(request: $settling, onDone: { dismiss() }))
        .confirmationDialog("Delete this conversation permanently?", isPresented: $deletingConversation, titleVisibility: .visible) {
            Button("Delete Permanently", role: .destructive) {
                Task {
                    guard await drafts.discardDrafts(for: [id]) else { return }
                    store.deletePermanently([id])
                    dismiss()
                }
            }
        } message: { Text("This can't be undone.") }
        .sheet(isPresented: $snooze) { SnoozeView(ids: [id], onSnooze: { dismiss() }) }
    }
}
