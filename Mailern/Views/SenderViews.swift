import SwiftUI

struct Sender: Hashable {
    let name: String
    let address: String
}

struct SenderHistoryView: View {
    @Environment(MailStore.self) private var store
    let sender: Sender
    let open: (UUID, [UUID]) -> Void

    var body: some View {
        let conversations = store.conversations(with: sender.address)
        return List {
            Section {
                Text(sender.address).textSelection(.enabled)
                SenderBlockButton(address: sender.address)
            }
            Section("Conversations") {
                ForEach(conversations) { conversation in
                    Button { open(conversation.id, conversations.map(\.id)) } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            ConversationRow(conversation: conversation)
                            Text(conversation.removal?.mailbox.title ?? conversation.workflow.title)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.buttonStyle(.plain)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { UndoBanner() }
        .navigationTitle(sender.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct SenderBlockButton: View {
    @Environment(MailStore.self) private var store
    let address: String

    var body: some View {
        let blocked = store.isSenderBlocked(address)
        Button(blocked ? "Unblock Sender" : "Block Sender", systemImage: blocked ? "person.crop.circle.badge.checkmark" : "hand.raised",
               role: blocked ? nil : .destructive) {
            store.setSenderBlocked(!blocked, address: address)
        }
    }
}

struct BlockedSendersView: View {
    @Environment(MailStore.self) private var store
    @State private var error: String?

    var body: some View {
        Group {
            if store.blockedSenders.isEmpty {
                ContentUnavailableView("No Blocked Senders", systemImage: "hand.raised")
            } else {
                List(store.blockedSenders.sorted(), id: \.self) { address in
                    HStack {
                        Text(address)
                        Spacer()
                        Button("Unblock") {
                            if !store.setSenderBlocked(false, address: address) {
                                error = store.error
                                store.error = nil
                            }
                        }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Unblock \(address)")
                    }
                }
            }
        }
        .navigationTitle("Blocked Senders")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Could Not Unblock Sender", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }
}
