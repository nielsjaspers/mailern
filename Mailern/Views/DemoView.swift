import SwiftUI

struct DemoView: View {
    @Environment(MailStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var reset = false
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button("Receive a new email", systemImage: "envelope.badge") { store.receiveNew(); dismiss() }
                } footer: { Text("All accounts and messages are fictional. No email providers are connected.") }
                Section("Receive a reply") {
                    ForEach(store.conversations.sorted { $0.workflow.rawValue > $1.workflow.rawValue }) { c in
                        Button {
                            store.receiveReply(c.id); dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(c.subject).foregroundStyle(.primary)
                                Text("\(c.workflow.title) · \(c.account.name)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section {
                    Button("Reset Demo Data", role: .destructive) { reset = true }
                }
            }
            .navigationTitle("Demo").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Replace all local demo messages?", isPresented: $reset, titleVisibility: .visible) {
                Button("Reset Demo Data", role: .destructive) { store.reset(); dismiss() }
            }
        }
    }
}
