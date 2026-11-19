import SwiftUI
import UIKit

/// Talks to mailern-server over HTTPS on the tailnet, or plain HTTP on this machine during development.
struct MailServerClient {
    let base: URL
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 70
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    struct Failure: LocalizedError {
        let status: Int
        let message: String
        var errorDescription: String? { message.isEmpty ? "The mail server returned status \(status)." : message }
    }

    private func send(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Data? = nil) async throws -> Data {
        var components = URLComponents(url: base.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await Self.session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw Failure(status: status, message: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return data
    }

    /// Changes after `revision`. With `wait`, the server holds the request until something changes.
    func sync(since revision: UInt64, wait: Int) async throws -> RemoteSync {
        let data = try await send("GET", "v1/sync", query: [.init(name: "since", value: String(revision)), .init(name: "wait", value: String(wait))])
        return try RemoteJSON.decoder.decode(RemoteSync.self, from: data)
    }

    func setState(_ id: UUID, _ state: RemoteState) async throws -> RemoteConversation {
        let data = try await send("PUT", "v1/conversations/\(id.uuidString.lowercased())", body: RemoteJSON.encoder.encode(state))
        return try RemoteJSON.decoder.decode(RemoteConversation.self, from: data)
    }

    func delete(_ id: UUID) async throws {
        do { _ = try await send("DELETE", "v1/conversations/\(id.uuidString.lowercased())") }
        catch let failure as Failure where failure.status == 404 {}
    }

    func html(_ messageID: UUID) async throws -> String {
        String(decoding: try await send("GET", "v1/messages/\(messageID.uuidString.lowercased())/html"), as: UTF8.self)
    }

    struct Outgoing: Encodable {
        struct Attachment: Encodable { var name: String; var contentType: String; var data: Data }
        var id: String
        var conversationID: String
        var accountID: String
        var to: [String], cc: [String], bcc: [String]
        var subject: String
        var text: String
        var html: String?
        var inReplyTo: String?
        var references: [String]?
        var attachments: [Attachment]
    }

    func send(_ message: Outgoing) async throws {
        _ = try await send("POST", "v1/send", body: RemoteJSON.encoder.encode(message))
    }
}

/// Keeps a server mailbox in step with mailern-server while the app is open: it waits for changes, merges them into
/// the store, and sends conversations the phone changed.
@MainActor @Observable
final class ServerSync {
    let client: MailServerClient
    @ObservationIgnored private let store: MailStore
    @ObservationIgnored private let defaults: UserDefaults
    private(set) var problem: String?
    private(set) var lastSync: Date?
    @ObservationIgnored private var inFlight = Set<UUID>()
    /// Server conversations in Trash or Junk, so a permanent delete on the phone also deletes them on the server.
    @ObservationIgnored private var removed = Set<UUID>()
    private static let revisionKey = "mailServerRevision"

    init(url: URL, store: MailStore, defaults: UserDefaults) {
        client = MailServerClient(base: url)
        self.store = store
        self.defaults = defaults
        store.sendRemote = { [client, store] draft in try await client.send(Self.outgoing(draft, store: store)) }
        store.loadRemoteHTML = { [client] id in try await client.html(id) }
        noteRemoved()
    }

    private var revision: UInt64 {
        get { store.conversations.isEmpty ? 0 : UInt64(defaults.string(forKey: Self.revisionKey) ?? "") ?? 0 }
        set { defaults.set(String(newValue), forKey: Self.revisionKey) }
    }

    /// Runs until cancelled. The first request returns at once; later ones wait up to 25 seconds for a change.
    func run() async {
        var wait = 0
        while !Task.isCancelled {
            do {
                let changes = try await client.sync(since: revision, wait: wait)
                try Task.checkCancellation()
                store.mergeRemote(changes)
                if !store.needsReload { revision = changes.revision }
                noteRemoved()
                problem = nil
                lastSync = .now
                wait = 25
                await push()
            } catch is CancellationError {
                return
            } catch let error as URLError where error.code == .cancelled {
                return
            } catch {
                problem = error.localizedDescription
                wait = 0
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    /// Sends every conversation with unconfirmed changes, and deletes the ones the phone deleted for good.
    func push() async {
        let present = Set(store.conversations.map(\.id))
        for id in removed.subtracting(present).subtracting(inFlight) {
            inFlight.insert(id)
            defer { inFlight.remove(id) }
            do {
                try await client.delete(id)
                removed.remove(id)
            } catch { problem = error.localizedDescription }
        }
        for conversation in store.conversations where conversation.hasUnsyncedChanges && !inFlight.contains(conversation.id) {
            let id = conversation.id
            let state = conversation.remoteState
            inFlight.insert(id)
            defer { inFlight.remove(id) }
            do {
                let confirmed = try await client.setState(id, state)
                store.mergeRemote(RemoteSync(revision: 0, reset: false, accounts: [], conversations: [confirmed], deleted: []))
                noteRemoved()
            } catch let failure as MailServerClient.Failure where failure.status == 404 {
                // The server no longer has it. The next full sync settles which side is right.
                revision = 0
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    private func noteRemoved() {
        removed.formUnion(store.conversations.filter { $0.removal != nil && $0.synced?.removal != nil }.map(\.id))
        removed.subtract(store.conversations.filter { $0.removal == nil }.map(\.id))
    }

    private static func outgoing(_ draft: ComposerDraft, store: MailStore) -> MailServerClient.Outgoing {
        let thread = draft.mode.replyID.flatMap(store.conversation)
        let target = thread?.message(draft.answering ?? draft.messageID)
        return .init(
            id: draft.id.uuidString.lowercased(),
            conversationID: (thread?.id ?? draft.id).uuidString.lowercased(),
            accountID: draft.accountID,
            to: ComposerDraft.addresses(draft.to), cc: ComposerDraft.addresses(draft.cc), bcc: ComposerDraft.addresses(draft.bcc),
            subject: draft.subject.isEmpty ? "(No Subject)" : draft.subject,
            text: draft.text,
            html: draft.richText.flatMap { html(RichText.decode($0, fallback: draft.text)) },
            inReplyTo: target?.threadingID,
            references: target.map { ($0.references ?? []) + [$0.threadingID] },
            attachments: draft.attachments.map { .init(name: $0.name, contentType: $0.contentType, data: $0.data) })
    }

    /// Formatted mail goes out with an HTML part, so other clients show the formatting.
    private static func html(_ text: NSAttributedString) -> String? {
        let range = NSRange(location: 0, length: text.length)
        guard let data = try? text.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.html]) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// What Settings needs to show and change the mail server connection.
struct MailServerConnection {
    var url: URL?
    var sync: ServerSync?
    var connect: @MainActor (URL?) async throws -> Void = { _ in }
}

extension EnvironmentValues {
    @Entry var mailServer = MailServerConnection()
}

struct MailServerSettingsView: View {
    @Environment(\.mailServer) private var server
    @State private var address = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                TextField("https://mailern.example.ts.net", text: $address)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("mail-server-address")
                Button(server.url == nil ? "Connect" : "Connect to This Server") { connect(URL(string: address.trimmingCharacters(in: .whitespaces))) }
                    .disabled(working || URL(string: address.trimmingCharacters(in: .whitespaces))?.host() == nil)
            } footer: {
                Text("mailern-server syncs your Gmail, iCloud, and Proton Mail accounts and serves them on your tailnet. Connecting shows its mail instead of the demo mail. Snoozes, reminders, and drafts stay in Mailern.")
            }
            if let url = server.url {
                Section("Connected") {
                    LabeledContent("Server", value: url.absoluteString)
                    if let problem = server.sync?.problem {
                        Text(problem).foregroundStyle(.red).accessibilityIdentifier("mail-server-problem")
                    } else if let last = server.sync?.lastSync {
                        LabeledContent("Last sync") { Text(last, style: .relative) }
                    } else {
                        ProgressView("Syncing")
                    }
                    Button("Use Demo Mail", role: .destructive) { connect(nil) }.disabled(working)
                }
            }
        }
        .navigationTitle("Mail Server")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if address.isEmpty { address = server.url?.absoluteString ?? "" } }
        .alert("Could Not Connect", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    private func connect(_ url: URL?) {
        guard !working else { return }
        working = true
        Task {
            defer { working = false }
            do { try await server.connect(url) } catch { self.error = error.localizedDescription }
        }
    }
}
