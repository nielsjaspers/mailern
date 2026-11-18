import SwiftUI

struct Sender: Hashable {
    let name: String
    let address: String
}

struct SenderHistoryView: View {
    @Environment(MailStore.self) private var store
    let sender: Sender

    var body: some View {
        List {
            Section {
                Text(sender.address).textSelection(.enabled)
                SenderBlockButton(address: sender.address)
            }
            Section("Conversations") {
                ForEach(store.conversations(with: sender.address)) { conversation in
                    NavigationLink(value: MailboxRoute.conversation(conversation.id)) {
                        VStack(alignment: .leading, spacing: 5) {
                            ConversationRow(conversation: conversation)
                            Text(conversation.removal?.mailbox.title ?? conversation.workflow.title)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
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

    var body: some View {
        Group {
            if store.blockedSenders.isEmpty {
                ContentUnavailableView("No Blocked Senders", systemImage: "hand.raised")
            } else {
                List(store.blockedSenders.sorted(), id: \.self) { address in
                    HStack {
                        Text(address)
                        Spacer()
                        Button("Unblock") { store.setSenderBlocked(false, address: address) }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Unblock \(address)")
                    }
                }
            }
        }
        .navigationTitle("Blocked Senders")
        .navigationBarTitleDisplayMode(.inline)
    }
}
