import SwiftUI

struct DemoView: View {
    @Environment(MailStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let benchmark: BenchmarkMailbox?
    let selectBenchmark: ((BenchmarkMailbox?) async throws -> Void)?
    @State private var reset = false
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                if let selectBenchmark {
                    Section("Large Mailbox") {
                        if loading { ProgressView("Opening mailbox…") }
                        ForEach(BenchmarkMailbox.allCases) { size in
                            Button {
                                open(size, using: selectBenchmark)
                            } label: {
                                Label(size.title, systemImage: size == benchmark ? "checkmark" : "tray.full")
                            }
                            .disabled(size == benchmark)
                            .accessibilityIdentifier("benchmark-\(size.rawValue)")
                        }
                        if benchmark != nil {
                            Button("Return to Demo Mail", systemImage: "arrow.uturn.backward") {
                                open(nil, using: selectBenchmark)
                            }
                        }
                    }
                }
                Section {
                    Button("Receive a new email", systemImage: "envelope.badge") { store.receiveNew(); dismiss() }
                    Button("Receive junk mail", systemImage: "xmark.bin") { store.receiveJunk(); dismiss() }
                } footer: { Text("All accounts and messages are fictional. No email providers are connected.") }
                Section("Receive a reply") {
                    ForEach(store.conversations.sorted { $0.workflow.rawValue > $1.workflow.rawValue }) { c in
                        Button {
                            store.receiveReply(c.id); dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(c.subject).foregroundStyle(.primary)
                                Text("\(c.removal?.mailbox.title ?? c.workflow.title) · \(store.account(c.accountID).name)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if benchmark == nil {
                    Section {
                        Button("Reset Demo Data", role: .destructive) { reset = true }
                    }
                }
            }
            .disabled(loading)
            .navigationTitle("Demo").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.disabled(loading) } }
            .confirmationDialog("Replace all local demo messages and accounts?", isPresented: $reset, titleVisibility: .visible) {
                Button("Reset Demo Data", role: .destructive) { store.reset(); dismiss() }
            }
            .alert("Could Not Open Mailbox", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "") }
        }
        .interactiveDismissDisabled(loading)
    }

    private func open(_ benchmark: BenchmarkMailbox?, using select: @escaping (BenchmarkMailbox?) async throws -> Void) {
        guard !loading else { return }
        loading = true
        Task {
            defer { loading = false }
            do {
                try await select(benchmark)
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}
