import SwiftUI

struct AccountsSettingsView: View {
    @Environment(MailStore.self) private var store

    var body: some View {
        Form {
            Section {
                ForEach(store.accounts) { account in
                    NavigationLink { AccountEditor(account: account, isNew: false) } label: {
                        HStack(spacing: 12) {
                            Circle().fill(account.color.color).frame(width: 12, height: 12)
                            VStack(alignment: .leading) {
                                Text(account.name)
                                Text(account.address).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } footer: {
                Text("New messages are sent from \(store.accounts[0].name). Accounts are stored on this iPhone. No email providers are connected.")
            }
            Section {
                NavigationLink("Add Account") {
                    AccountEditor(account: MailAccount(id: UUID().uuidString, name: "", address: "", color: .teal), isNew: true)
                }
            }
        }
        .navigationTitle("Accounts")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct AccountEditor: View {
    @Environment(MailStore.self) private var store
    @Environment(DraftStore.self) private var drafts
    @Environment(\.dismiss) private var dismiss
    @State var account: MailAccount
    let isNew: Bool
    @State private var confirmingDelete = false
    @State private var error: String?

    private var conversationCount: Int { store.conversations.filter { $0.accountID == account.id }.count }
    private var draftCount: Int { drafts.drafts.filter { $0.accountID == account.id }.count }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $account.name)
                TextField("Email address", text: $account.address)
                    .keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            Section {
                Picker("Color", selection: $account.color) {
                    ForEach(AccountColor.allCases) { color in
                        Label { Text(color.title) } icon: { Circle().fill(color.color).frame(width: 14, height: 14) }
                            .tag(color)
                    }
                }
                .pickerStyle(.navigationLink)
            }
            Section {
                TextField("Signature", text: $account.signature, axis: .vertical)
                    .lineLimit(3...8)
                    .accessibilityLabel("Signature")
            } header: { Text("Signature") } footer: {
                Text("Added to new messages, replies, and forwards from this account.")
            }
            if !isNew {
                Section {
                    Button("Delete Account", role: .destructive) { confirmingDelete = true }
                        .disabled(store.accounts.count == 1)
                } footer: {
                    if store.accounts.count == 1 { Text("You need at least one account.") }
                }
            }
        }
        .navigationTitle(isNew ? "New Account" : account.name.isEmpty ? "Account" : account.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(isNew ? "Add" : "Save") {
                    if store.saveAccount(account) { dismiss() } else { error = store.error ?? store.problem(with: account) }
                }
                .disabled(store.problem(with: account) != nil || store.accounts.contains(account))
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let problem = store.problem(with: account), !account.name.isEmpty || !account.address.isEmpty {
                Text(problem).font(.footnote).foregroundStyle(.secondary).padding()
            }
        }
        .confirmationDialog("Delete \(account.name)?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete Account", role: .destructive) { Task { await delete() } }
        } message: {
            Text("This removes \(conversationCount) conversations and \(draftCount) drafts from this iPhone. This cannot be undone.")
        }
        .alert("Account", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    private func delete() async {
        if let problem = await store.deleteAccount(account.id, drafts: drafts) { error = problem } else { dismiss() }
    }
}
