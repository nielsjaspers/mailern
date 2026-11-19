import SwiftUI

/// Junk or Trash, pushed from the Mailboxes menu onto the current tab's stack.
struct RemovedMailboxView: View {
    @Environment(MailStore.self) private var store
    @Environment(DraftStore.self) private var drafts
    let mailbox: RemovedMailbox
    let open: (UUID, [UUID], String) -> Void
    @State private var searchInput = MailboxSearchInput()
    private var search: String { searchInput.text }
    @State private var selecting = false
    @State private var selectedIDs: Set<UUID> = []
    @State private var deleting: DeleteConfirmation?
    // A thread pushed on top shows its own draft storage alert.
    @State private var visible = false

    private var conversations: [Conversation] { store.list(mailbox, search: search) }
    private var restoreTitle: String { mailbox == .junk ? "Not Junk" : "Restore" }

    var body: some View {
        content
            .safeAreaInset(edge: .bottom, spacing: 0) { UndoBanner() }
            .navigationTitle(mailbox.title)
            .searchable(text: $searchInput.text, prompt: "Search \(mailbox.title)")
            .navigationBarBackButtonHidden(selecting)
            .toolbar(.hidden, for: .tabBar)
            .toolbar {
                if selecting {
                    ToolbarItem(placement: .topBarLeading) {
                        let visibleIDs = Set(conversations.map(\.id))
                        let allSelected = !visibleIDs.isEmpty && visibleIDs.isSubset(of: selectedIDs)
                        Button(allSelected ? "Deselect All" : "Select All") { selectedIDs = allSelected ? [] : visibleIDs }
                            .disabled(visibleIDs.isEmpty)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(selecting ? "Cancel" : "Select") {
                        selecting.toggle()
                        selectedIDs = []
                    }
                    .disabled(!selecting && conversations.isEmpty)
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    if selecting {
                        Button(restoreTitle, systemImage: "arrow.uturn.backward") {
                            if apply(selectedIDs) { endSelection() }
                        }
                        .disabled(selectedIDs.isEmpty)
                        Spacer()
                        Button("Delete Permanently", systemImage: "trash") { deleting = store.prepareDelete(selectedIDs, from: mailbox) }
                            .disabled(selectedIDs.isEmpty)
                    } else if mailbox == .trash {
                        Spacer()
                        Button("Empty Trash") { deleting = store.prepareDelete(Set(store.list(.trash).map(\.id)), from: .trash) }
                            .disabled(store.list(.trash).isEmpty)
                    }
                }
            }
            .confirmationDialog(
                deleting?.members.count == 1 ? "Delete this conversation permanently?" : "Delete \(deleting?.members.count ?? 0) conversations permanently?",
                isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                titleVisibility: .visible, presenting: deleting
            ) { confirmation in
                Button("Delete Permanently", role: .destructive) {
                    Task {
                        // Some conversations in Junk still have scheduled or saved replies.
                        let committed = await drafts.discardDrafts(for: confirmation.ids, scheduled: true) {
                            store.deletePermanently(confirmation, discarding: $0)
                        }
                        if committed { endSelection() }
                    }
                }
            } message: { _ in Text("This can't be undone.") }
            .modifier(DraftStorageAlert(active: visible))
            .onAppear { visible = true }
            .onDisappear { visible = false }
            // Bulk actions apply only to visible conversations.
            .onChange(of: store.conversations) { _, _ in pruneSelection() }
            .onChange(of: search) { _, _ in pruneSelection() }
    }

    @ViewBuilder private var content: some View {
        let conversations = conversations
        if conversations.isEmpty {
            ContentUnavailableView(
                search.isEmpty ? "No \(mailbox.rawValue)" : "No results",
                systemImage: search.isEmpty ? mailbox.symbol : "magnifyingglass",
                description: Text(search.isEmpty ? footer : "Try another search in \(mailbox.title).")
            )
        } else {
            List(selection: selecting ? $selectedIDs : nil) {
                Section {
                    ForEach(conversations) { conversation in
                        Group {
                            if selecting {
                                ConversationRow(query: search, searchSession: searchInput.session, conversation: conversation, hasDraft: false)
                            } else {
                                Button { open(conversation.id, conversations.map(\.id), search) } label: {
                                    ConversationRow(query: search, searchSession: searchInput.session, conversation: conversation, hasDraft: false)
                                }.buttonStyle(.plain)
                            }
                        }
                        .listRowBackground(conversation.unread ? ConversationRow.unreadBackground : Color.clear)
                        .tag(conversation.id)
                        .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            if !selecting {
                                Button(restoreTitle, systemImage: "arrow.uturn.backward") { apply([conversation.id]) }.tint(.blue)
                                Button("Delete", systemImage: "trash") { deleting = store.prepareDelete([conversation.id], from: mailbox) }.tint(.red)
                            }
                        }
                    }
                } footer: {
                    Text(footer).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .listStyle(.plain)
            .environment(\.editMode, .constant(selecting ? .active : .inactive))
        }
    }

    private var footer: String {
        switch mailbox {
        case .junk: "Mail from blocked senders arrives here."
        case .trash: "Conversations in Trash are deleted after 30 days."
        }
    }

    @discardableResult private func apply(_ ids: Set<UUID>) -> Bool {
        withAnimation { store.apply(ids: ids, action: .restoreRemoved) }
    }
    private func endSelection() { selecting = false; selectedIDs = [] }
    private func pruneSelection() { selectedIDs.formIntersection(conversations.map(\.id)) }
}
