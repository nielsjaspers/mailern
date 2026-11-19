import SwiftUI

struct ThreadView: View {
    @Environment(MailStore.self) private var store
    @Environment(DraftStore.self) private var drafts
    @Environment(\.dismiss) private var dismiss
    let id: UUID
    var inboxAccountID: String?
    var initialQuery = ""
    var previousID: UUID?
    var nextID: UUID?
    @State private var finding = false
    /// The conversation below this one in the list it was opened from, read before Settle removes it.
    let next: () -> UUID?
    /// Replaces this thread with another conversation.
    let open: (UUID) -> Void
    let showSender: (Sender) -> Void
    @AppStorage(AfterSettle.key) private var afterSettle = AfterSettle.returnToList
    // The conversation to open after Settle waits for the discard-drafts confirmation.
    @State private var settleNext: UUID?
    @State private var mode: ComposeMode?
    // The message a per-message reply targets. Nil for the toolbar, which targets the latest.
    @State private var target: UUID?
    @State private var snooze = false
    @State private var deleting = false
    @State private var settling: DraftDiscard?
    @State private var deletingConversation = false
    @State private var confirmedMailbox = RemovedMailbox.trash
    private var scheduled: [ComposerDraft] { drafts.outbox.filter { $0.mode.replyID == id } }
    private var attachedDrafts: [ComposerDraft] { drafts.drafts.filter { $0.mode.replyID == id }.sorted { $0.updatedAt < $1.updatedAt } }
    private func compose(_ mode: ComposeMode, message: UUID? = nil) {
        target = message
        self.mode = mode
    }
    private func leave(after next: UUID?) {
        if afterSettle == .openNext, let next { open(next) } else { dismiss() }
    }
    private func remove(to mailbox: RemovedMailbox) {
        if !attachedDrafts.isEmpty { settleNext = nil; settling = DraftDiscard(ids: [id], action: .remove(mailbox)); return }
        if store.apply(ids: [id], action: .remove(mailbox)) { dismiss() }
    }
    var body: some View {
        Group {
            if let c = store.conversation(id) {
                ConversationContent(conversation: c, initialQuery: initialQuery, finding: $finding, drafts: attachedDrafts, scheduled: scheduled, editDraft: { mode = .draft($0) }, discardDraft: { draftID in
                    Task {
                        deleting = true
                        defer { deleting = false }
                        await drafts.delete(draftID)
                    }
                }, deletingDraft: deleting, compose: c.removal == nil ? { compose($0, message: $1) } : nil, showSender: showSender)
                // A mailto: link starts a message here. Other links go to the system, which opens web links in the browser.
                .environment(\.openURL, OpenURLAction { url in
                    guard let link = MailtoLink(url) else { return .systemAction }
                    compose(.mailto(link))
                    return .handled
                })
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        if !finding {
                            Button("Previous conversation", systemImage: "chevron.up") { if let previousID { open(previousID) } }
                                .disabled(previousID == nil)
                            Button("Next conversation", systemImage: "chevron.down") { if let nextID { open(nextID) } }
                                .disabled(nextID == nil)
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button("Find in conversation", systemImage: "magnifyingglass") { finding = true }
                            if c.removal == nil {
                                Button(c.pinned ? "Unpin" : "Pin", systemImage: "pin") { store.togglePin(id) }
                            }
                            if c.workflow != .settled {
                                Button("Mark unread", systemImage: "envelope.badge") { store.setUnread(id, true); dismiss() }
                            }
                            if c.removal == nil {
                                Button("Snooze", systemImage: "clock") { snooze = true }
                                if c.workflow != .inbox {
                                    Button("Restore to Inbox", systemImage: "tray") { if store.move(id, to: .inbox) { dismiss() } }
                                }
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
                                if store.apply(ids: [id], action: .restoreRemoved) { dismiss() }
                            }
                            Spacer()
                            Button("Delete Permanently", systemImage: "trash") {
                                confirmedMailbox = mailbox
                                deletingConversation = true
                            }
                        } else {
                            Button(c.workflow == .settled ? "Restore" : "Settle", systemImage: c.workflow == .settled ? "tray" : "checkmark") {
                                if c.workflow == .settled {
                                    if store.move(id, to: .inbox) { dismiss() }
                                    return
                                }
                                let next = next()
                                if !attachedDrafts.isEmpty { settleNext = next; settling = DraftDiscard(ids: [id], action: .move(.settled)); return }
                                if store.move(id, to: .settled) { leave(after: next) }
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
                        }
                    }
                }
            } else { ContentUnavailableView("Conversation unavailable", systemImage: "envelope") }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { UndoBanner(sendingOnly: true) }
        .toolbar(.hidden, for: .tabBar)
        .onAppear { store.markRead(id) }
        .sheet(item: $mode) { mode in
            switch mode {
            case .draft, .mailto: ComposerView(mode: mode, inboxAccountID: inboxAccountID)
            default: ComposerView(mode: mode, messageID: target)
            }
        }
        .modifier(DraftStorageAlert(active: mode == nil))
        .modifier(DiscardDraftsConfirmation(request: $settling, onDone: { leave(after: settleNext) }))
        .confirmationDialog("Delete this conversation permanently?", isPresented: $deletingConversation, titleVisibility: .visible) {
            Button("Delete Permanently", role: .destructive) {
                Task {
                    let committed = await drafts.discardDrafts(for: [id], scheduled: true) { store.deletePermanently([id], from: confirmedMailbox, discarding: $0) }
                    if committed { dismiss() }
                }
            }
        } message: { Text("This can't be undone.") }
        .sheet(isPresented: $snooze) { SnoozeView(ids: [id], onSnooze: { dismiss() }) }
    }
}
