import SwiftUI

enum ComposeMode: Identifiable {
    case new, reply(UUID), replyAll(UUID), forward(UUID)
    var id: String { String(describing: self) }
    var sourceID: UUID? {
        switch self { case .new: nil; case .reply(let id), .replyAll(let id), .forward(let id): id }
    }
    var replyID: UUID? {
        switch self { case .reply(let id), .replyAll(let id): id; default: nil }
    }
    var title: String {
        switch self { case .new: "New message"; case .reply: "Reply"; case .replyAll: "Reply All"; case .forward: "Forward" }
    }
}

struct ComposerView: View {
    @Environment(MailStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let mode: ComposeMode
    @State private var account = MailAccount.demo[1]
    @State private var to = ""
    @State private var cc = ""
    @State private var subject = ""
    @State private var bodyText = ""
    @State private var loaded = false
    @State private var discard = false
    @State private var initialBody = ""
    @State private var initialTo = ""
    @State private var initialCC = ""
    @State private var initialSubject = ""
    @State private var initialAccount = MailAccount.demo[1]
    private func addresses(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0 == ";" }).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
    private func valid(_ address: String) -> Bool {
        let parts = address.split(separator: "@", omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].isEmpty && parts[1].contains(".") && !address.contains(where: \.isWhitespace)
    }
    private var canSend: Bool {
        !addresses(to).isEmpty && (addresses(to) + addresses(cc)).allSatisfy(valid) && !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private var dirty: Bool { bodyText != initialBody || to != initialTo || cc != initialCC || subject != initialSubject || account != initialAccount }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("From", selection: $account) {
                        ForEach(MailAccount.demo) { Text("\($0.name) · \($0.address)").tag($0) }
                    }.disabled(mode.replyID != nil)
                    TextField("To", text: $to).keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Cc", text: $cc).keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Subject", text: $subject)
                }
                Section {
                    TextEditor(text: $bodyText).frame(minHeight: 270).accessibilityLabel("Message body")
                } footer: { Text("Demo mode. Messages are saved on this device and are not delivered.") }
            }
            .navigationTitle(mode.title).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { if dirty { discard = true } else { dismiss() } } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send", systemImage: "arrow.up") {
                        store.send(threadID: mode.replyID, account: account, to: addresses(to), cc: addresses(cc), subject: subject, body: bodyText)
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                        dismiss()
                    }.disabled(!canSend)
                }
            }
            .confirmationDialog("Discard this message?", isPresented: $discard, titleVisibility: .visible) { Button("Discard", role: .destructive) { dismiss() } }
        }
        .interactiveDismissDisabled(dirty)
        .onAppear {
            guard !loaded else { return }; loaded = true
            if let id = mode.sourceID, let c = store.conversation(id) {
                account = c.account
                switch mode {
                case .reply, .replyAll:
                    let target = c.correspondent
                    to = target.outgoing ? target.to.joined(separator: ", ") : target.address
                    subject = c.subject.lowercased().hasPrefix("re:") ? c.subject : "Re: \(c.subject)"
                    if case .replyAll = mode {
                        let own = Set(MailAccount.demo.map { $0.address.lowercased() })
                        var seen = own.union(addresses(to).map { $0.lowercased() })
                        cc = (target.to + target.cc).filter { seen.insert($0.lowercased()).inserted }.joined(separator: ", ")
                    }
                case .forward:
                    subject = "Fwd: \(c.subject)"
                    bodyText = "\n\nForwarded message\nFrom: \(c.latest.sender) <\(c.latest.address)>\nDate: \(c.latest.date.formatted())\nSubject: \(c.subject)\n\n\(c.latest.body)"
                case .new: break
                }
            }
            initialBody = bodyText; initialTo = to; initialCC = cc; initialSubject = subject; initialAccount = account
        }
    }
}
