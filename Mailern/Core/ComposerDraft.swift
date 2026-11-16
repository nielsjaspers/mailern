import Foundation
import Observation

enum ComposeMode: Codable, Equatable, Identifiable, Sendable {
    case new, reply(UUID), replyAll(UUID), forward(UUID), draft(UUID)
    var id: String { String(describing: self) }
    var sourceID: UUID? {
        switch self { case .reply(let id), .replyAll(let id), .forward(let id): id; default: nil }
    }
    var replyID: UUID? {
        switch self { case .reply(let id), .replyAll(let id): id; default: nil }
    }
}

struct MailAttachment: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let name: String
    let data: Data
    let contentType: String

    init(name: String, data: Data, contentType: String) {
        id = UUID()
        self.name = name
        self.data = data
        self.contentType = contentType
    }
    private enum CodingKeys: String, CodingKey { case id, name, contentType }
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        contentType = try values.decode(String.self, forKey: .contentType)
        data = try Data(contentsOf: AttachmentJSON.payloadURL(id, context: decoder.userInfo), options: .mappedIfSafe)
    }
    func encode(to encoder: any Encoder) throws {
        try AttachmentJSON.writePayload(data, id: id, context: encoder.userInfo)
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encode(contentType, forKey: .contentType)
    }
}

struct ComposerDraft: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var mode: ComposeMode = .new
    var accountID = MailAccount.demo[1].id
    var to = ""
    var cc = ""
    var bcc = ""
    var subject = ""
    var text = ""
    var richText: Data?
    var attachments: [MailAttachment] = []
    var updatedAt = Date.now
    var pinned: Bool?
    var snoozedUntil: Date?

    func matchesContent(of other: Self) -> Bool {
        // Pinning and snooze expiry do not change the editor's saved content.
        var content = self
        content.pinned = other.pinned
        content.snoozedUntil = other.snoozedUntil
        return content == other
    }

    static func addresses(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0 == ";" || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
    var canSend: Bool {
        let recipients = Self.addresses(to) + Self.addresses(cc) + Self.addresses(bcc)
        return !recipients.isEmpty && recipients.allSatisfy { address in
            let parts = address.split(separator: "@", omittingEmptySubsequences: false)
            return parts.count == 2 && !parts[0].isEmpty && parts[1].contains(".") && !address.contains(where: \.isWhitespace)
        }
    }
    static func make(mode: ComposeMode, conversation: Conversation?, message: UUID? = nil) -> Self {
        var draft = Self(mode: mode)
        guard let c = conversation else { return draft }
        draft.accountID = c.accountID
        let target = c.message(message)
        let subject = c.subject(at: target)
        switch mode {
        case .reply, .replyAll:
            draft.to = target.outgoing ? target.to.joined(separator: ", ") : target.address
            draft.subject = subject.lowercased().hasPrefix("re:") ? subject : "Re: \(subject)"
            if case .replyAll = mode {
                var seen = Set(MailAccount.demo.map { $0.address.lowercased() } + addresses(draft.to).map { $0.lowercased() })
                draft.cc = (target.to + target.cc).filter { seen.insert($0.lowercased()).inserted }.joined(separator: ", ")
            }
            draft.text = "\n\nOn \(target.date.formatted()), \(target.sender) <\(target.address)> wrote:\n\(target.body)"
        case .forward:
            draft.subject = subject.lowercased().hasPrefix("fwd:") ? subject : "Fwd: \(subject)"
            draft.text = "\n\nBegin forwarded message:\n\nFrom: \(target.sender) <\(target.address)>\nDate: \(target.date.formatted())\nSubject: \(subject)\nTo: \(target.to.joined(separator: ", "))\n\n\(target.body)"
            draft.attachments = target.attachments ?? []
        default: break
        }
        return draft
    }
}

@MainActor @Observable
final class DraftStore {
    private(set) var drafts: [ComposerDraft] = []
    var error: String?
    private let url: URL
    private let write: @Sendable (Data, URL) throws -> Void
    private var loadFailure: String?
    var needsReload: Bool { loadFailure != nil }
    @ObservationIgnored private var pending: Task<Bool, Never>?

    init(url: URL = URL.applicationSupportDirectory.appending(path: "Mailern/drafts-v1.json"),
         write: @escaping @Sendable (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) {
        self.url = url
        self.write = write
        do { drafts = try Self.read(url) }
        catch { failedToLoad(error) }
    }
    private nonisolated static func read(_ url: URL) throws -> [ComposerDraft] {
        try AttachmentJSON.load([ComposerDraft].self, from: url) ?? []
    }
    func reload() async {
        let url = url
        _ = await enqueue {
            do {
                self.drafts = try await Task.detached { try Self.read(url) }.value
                self.loadFailure = nil
                self.error = nil
                return true
            } catch { self.failedToLoad(error); return false }
        }
    }
    @discardableResult func save(_ draft: ComposerDraft) async -> Bool {
        await enqueue {
            var draft = draft
            if let existing = self.drafts.first(where: { $0.id == draft.id }) {
                // An open editor can hold mailbox state from before a snooze expired.
                draft.pinned = existing.pinned
                draft.snoozedUntil = existing.snoozedUntil
            }
            var updated = self.drafts.filter { $0.id != draft.id }
            updated.insert(draft, at: 0)
            return await self.persist(updated)
        }
    }
    @discardableResult func delete(_ id: UUID) async -> Bool {
        await enqueue {
            guard self.drafts.contains(where: { $0.id == id }) else {
                if self.loadFailure == nil {
                    let url = self.url
                    await Task.detached { AttachmentJSON.removeUnusedPayloads(for: url, as: [ComposerDraft].self) }.value
                }
                return true
            }
            return await self.persist(self.drafts.filter { $0.id != id })
        }
    }
    func discardForSettling(_ ids: Set<UUID>) async -> Bool {
        await enqueue {
            await self.persist(self.drafts.filter { !ids.contains($0.id) && !($0.mode.replyID.map(ids.contains) ?? false) })
        }
    }
    func togglePin(_ id: UUID) async {
        _ = await updateMailbox(ids: [id]) { $0.pinned = !($0.pinned ?? false) }
    }
    func snooze(_ ids: Set<UUID>, until date: Date) async -> Bool {
        guard date > .now else { return false }
        return await updateMailbox(ids: ids) { $0.snoozedUntil = date }
    }
    func restore(_ id: UUID) async -> Bool {
        await updateMailbox(ids: [id]) { $0.snoozedUntil = nil }
    }
    func wakeDue(now: Date = .now) async {
        guard drafts.contains(where: { ($0.snoozedUntil ?? .distantFuture) <= now }) else { return }
        _ = await enqueue {
            var updated = self.drafts
            for i in updated.indices where (updated[i].snoozedUntil ?? .distantFuture) <= now {
                updated[i].snoozedUntil = nil
            }
            if updated == self.drafts { return true }
            return await self.persist(updated)
        }
    }
    private func updateMailbox(ids: Set<UUID>, change: @escaping (inout ComposerDraft) -> Void) async -> Bool {
        await enqueue {
            var updated = self.drafts
            for i in updated.indices where ids.contains(updated[i].id) { change(&updated[i]) }
            return await self.persist(updated)
        }
    }
    private func enqueue(_ operation: @escaping @MainActor () async -> Bool) async -> Bool {
        let previous = pending
        // Once submitted, writes finish in order even if an autosave task is cancelled.
        let task = Task { @MainActor in
            _ = await previous?.value
            return await operation()
        }
        pending = task
        return await task.value
    }
    private func persist(_ updated: [ComposerDraft]) async -> Bool {
        guard loadFailure == nil else { error = loadFailure; return false }
        let url = url
        let write = write
        do {
            try await Task.detached(priority: .utility) {
                try AttachmentJSON.save(updated, to: url, write: write)
            }.value
            drafts = updated
            error = nil
            return true
        } catch { self.error = "Could not save drafts. \(error.localizedDescription)"; return false }
    }
    private func failedToLoad(_ error: any Error) {
        loadFailure = "Could not load drafts. Existing storage has not been changed. \(error.localizedDescription)"
        self.error = loadFailure
    }
}
