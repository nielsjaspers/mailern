import SwiftUI
import UIKit

/// Talks to mailern-server over HTTPS on the tailnet, or plain HTTP on this machine during development.
struct MailServerClient: RemoteMailboxClient {
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

    func setState(_ id: UUID, _ state: RemoteState, fields: Set<RemoteStateField>, messageIDs: [UUID]) async throws -> RemoteConversation? {
        do {
            let body = try RemoteJSON.encoder.encode(RemoteStateWrite(state: state, fields: fields, messageIDs: messageIDs))
            let data = try await send("PUT", "v1/conversations/\(id.uuidString.lowercased())", body: body)
            return try RemoteJSON.decoder.decode(RemoteConversation.self, from: data)
        } catch let failure as Failure where failure.status == 404 {
            return nil
        }
    }

    /// A conflict leaves the conversation on the server and requires a fresh mailbox snapshot.
    func delete(_ id: UUID, _ request: RemoteDelete) async throws -> Bool {
        do {
            let body = try RemoteJSON.encoder.encode(request)
            _ = try await send("DELETE", "v1/conversations/\(id.uuidString.lowercased())", body: body)
            return true
        } catch let failure as Failure where failure.status == 404 {
            return true
        } catch let failure as Failure where failure.status == 409 {
            return false
        }
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
        var from: String
    }

    func send(_ message: Outgoing) async throws {
        do {
            _ = try await send("POST", "v1/send", body: RemoteJSON.encoder.encode(message))
        } catch let failure as Failure where [400, 403, 404, 422].contains(failure.status) {
            throw RemoteSendRejection(message: failure.localizedDescription)
        }
    }
}

extension ServerSync {
    convenience init(url: URL, store: MailStore) {
        let client = MailServerClient(base: url)
        self.init(client: client, store: store)
        store.sendRemote = { prepared in try await client.send(Self.outgoing(prepared)) }
        store.loadRemoteHTML = { id in try await client.html(id) }
    }

    private static func outgoing(_ prepared: PreparedRemoteSend) -> MailServerClient.Outgoing {
        let draft = prepared.draft
        let target = prepared.replyTo
        return .init(
            id: draft.id.uuidString.lowercased(),
            conversationID: prepared.conversationID.uuidString.lowercased(),
            accountID: prepared.from.id,
            to: ComposerDraft.addresses(draft.to), cc: ComposerDraft.addresses(draft.cc), bcc: ComposerDraft.addresses(draft.bcc),
            subject: draft.subject.isEmpty ? "(No Subject)" : draft.subject,
            text: draft.text,
            html: draft.richText.flatMap { html(RichText.decode($0, fallback: draft.text)) },
            inReplyTo: target?.threadingID,
            references: target?.references,
            attachments: draft.attachments.map { .init(name: $0.name, contentType: $0.contentType, data: $0.data) },
            from: draft.sender(in: prepared.from))
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
