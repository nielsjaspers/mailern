import Foundation
import Observation

enum ComposeMode: Codable, Equatable, Identifiable, Sendable {
    case new, reply(UUID), replyAll(UUID), forward(UUID), draft(UUID)
    /// A new message filled from a `mailto:` link. Its draft is saved as `.new`.
    case mailto(MailtoLink)
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
    /// Attachment bytes never change after import, so the identity decides equality without reading the file.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.contentType == rhs.contentType
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
    var accountID = MailAccount.demo[0].id
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
    /// The message a reply or forward was started from. Nil means the latest message at that time.
    var messageID: UUID?
    /// The message a reply answers, fixed when the draft is made, so mail that arrives later does not change it.
    var answering: UUID?
    /// The signature the composer inserted. The composer replaces it on a sender change while it is still unedited.
    var signature: String?
    /// When scheduled mail goes out. Nil for a draft.
    var sendAt: Date?
    /// When to return the sent conversation to Inbox if nobody replied.
    var followUp: Date?

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
        return !recipients.isEmpty && recipients.allSatisfy(Self.isAddress)
    }
    static func isAddress(_ address: String) -> Bool {
        let parts = address.split(separator: "@", omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].isEmpty && parts[1].contains(".") && !address.contains(where: \.isWhitespace)
    }
    /// The text a signature adds to a body. It sits above any quote, separated from the text you type by a blank line.
    static func signatureBlock(_ signature: String) -> String { signature.isEmpty ? "" : "\n\n\(signature)" }

    /// Swaps the block for `old` in `text` for `replacement` and returns the range it replaced.
    /// The inserted signature is the last text above the quote that starts at `quoteStart`, or the end of a new
    /// message. Any edit to it, or text typed below it, leaves it in place and returns nil. `unedited` checks the
    /// block for changes the text does not show, such as formatting. With no old signature, the replacement goes
    /// in that same spot.
    static func swapSignature(in text: NSMutableAttributedString, old: String, replacement: NSAttributedString, quoteStart: Int?,
                              unedited: (NSRange) -> Bool = { _ in true }) -> NSRange? {
        let string = text.string as NSString
        // A quote follows a blank line, which stays below the signature.
        let end = quoteStart.map { min(max(0, $0 - 2), string.length) } ?? string.length
        let block = signatureBlock(old) as NSString
        guard end >= block.length, string.substring(with: NSRange(location: end - block.length, length: block.length)) == block as String else { return nil }
        let range = NSRange(location: end - block.length, length: block.length)
        guard unedited(range) else { return nil }
        text.replaceCharacters(in: range, with: replacement)
        return range
    }

    /// A new draft from `accounts[0]`, or a reply or forward from the conversation's account, with that account's signature.
    static func make(mode: ComposeMode, conversation: Conversation?, message: UUID? = nil, accounts: [MailAccount]) -> Self {
        var draft = Self(mode: mode, messageID: message)
        draft.accountID = conversation?.accountID ?? accounts.first?.id ?? draft.accountID
        let signature = accounts.first { $0.id == draft.accountID }?.signature ?? ""
        draft.signature = signature
        draft.text = signatureBlock(signature)
        if case .mailto(let link) = mode {
            draft.mode = .new
            draft.to = link.to.joined(separator: ", ")
            draft.cc = link.cc.joined(separator: ", ")
            draft.bcc = link.bcc.joined(separator: ", ")
            draft.subject = link.subject
            draft.text = link.body + draft.text
        }
        guard let c = conversation else { return draft }
        let target = c.message(message)
        let subject = c.subject(at: target)
        switch mode {
        case .reply, .replyAll:
            draft.answering = target.id
            draft.to = target.outgoing ? target.to.joined(separator: ", ") : target.address
            draft.subject = subject.lowercased().hasPrefix("re:") ? subject : "Re: \(subject)"
            if case .replyAll = mode {
                var seen = Set(accounts.map { $0.address.lowercased() } + addresses(draft.to).map { $0.lowercased() })
                draft.cc = (target.to + target.cc).filter { seen.insert($0.lowercased()).inserted }.joined(separator: ", ")
            }
            draft.text += "\n\n\(QuotedText.attribution(for: target))\n\(target.body)"
        case .forward:
            draft.subject = subject.lowercased().hasPrefix("fwd:") ? subject : "Fwd: \(subject)"
            draft.text += "\n\nBegin forwarded message:\n\nFrom: \(target.sender) <\(target.address)>\nDate: \(target.date.formatted())\nSubject: \(subject)\nTo: \(target.to.joined(separator: ", "))\n\n\(target.body)"
            draft.attachments = target.attachments ?? []
        default: break
        }
        return draft
    }
}

@MainActor @Observable
final class DraftStore {
    /// Drafts and scheduled mail, as stored.
    private(set) var all: [ComposerDraft] = []
    /// Drafts being written. Scheduled mail waits in `outbox` instead.
    var drafts: [ComposerDraft] { all.filter { $0.sendAt == nil } }
    /// Mail waiting to be sent, soonest first. Undo Send holds mail here for its short delay.
    var outbox: [ComposerDraft] { all.filter { $0.sendAt != nil }.sorted { $0.sendAt! < $1.sendAt! } }
    /// The outbox message that Undo Send can still take back.
    var undoable: UUID?
    /// A draft to open in the composer, set when Undo Send or Edit takes scheduled mail back.
    var reopening: UUID?
    var error: String?
    /// Counts Pin, Snooze, Restore, Settle, and Discard on standalone drafts, like `MailStore.actionCount`.
    private(set) var actionCount = 0
    private let url: URL
    private let write: @Sendable (Data, URL) throws -> Void
    private var loadFailure: String?
    var needsReload: Bool { loadFailure != nil }
    @ObservationIgnored private var pending: Task<Bool, Never>?

    init(url: URL = URL.applicationSupportDirectory.appending(path: "Mailern/drafts-v1.json"),
         write: @escaping @Sendable (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) {
        self.url = url
        self.write = write
        do { all = try Self.read(url) }
        catch { failedToLoad(error) }
    }
    private nonisolated static func read(_ url: URL) throws -> [ComposerDraft] {
        try AttachmentJSON.load([ComposerDraft].self, from: url) ?? []
    }
    func reload() async {
        let url = url
        _ = await enqueue {
            do {
                self.all = try await Task.detached { try Self.read(url) }.value
                self.loadFailure = nil
                self.error = nil
                return true
            } catch { self.failedToLoad(error); return false }
        }
    }
    @discardableResult func save(_ draft: ComposerDraft) async -> Bool {
        await enqueue {
            var draft = draft
            if let existing = self.all.first(where: { $0.id == draft.id }) {
                // An open editor can hold mailbox state from before a snooze expired.
                draft.pinned = existing.pinned
                draft.snoozedUntil = existing.snoozedUntil
            }
            var updated = self.all.filter { $0.id != draft.id }
            updated.insert(draft, at: 0)
            return await self.persist(updated)
        }
    }
    @discardableResult func delete(_ id: UUID) async -> Bool {
        await enqueue {
            guard self.all.contains(where: { $0.id == id }) else {
                if self.loadFailure == nil {
                    let url = self.url
                    await Task.detached { AttachmentJSON.removeUnusedPayloads(for: url, as: [ComposerDraft].self) }.value
                }
                return true
            }
            return await self.persist(self.all.filter { $0.id != id })
        }
    }
    /// The original draft file and its attachment bytes stay readable until the mail action commits.
    func discardDrafts(for ids: Set<UUID>, scheduled: Bool = false,
                       committingMail: @escaping @MainActor () -> Bool = { true }) async -> Bool {
        await enqueue {
            guard self.loadFailure == nil else { self.error = self.loadFailure; return false }
            let remaining = self.all.filter { draft in
                guard scheduled || draft.sendAt == nil else { return true }
                return !ids.contains(draft.id) && !(draft.mode.replyID.map(ids.contains) ?? false)
            }
            guard remaining.count != self.all.count else { return committingMail() }
            let standalone = self.drafts.contains { ids.contains($0.id) }
            let url = self.url
            let write = self.write
            do {
                let staged = try await Task.detached(priority: .utility) {
                    try AttachmentJSON.stageRemoval(remaining, at: url, write: write)
                }.value
                defer { try? FileManager.default.removeItem(at: staged.deletingLastPathComponent()) }
                guard committingMail() else { return false }
                try AttachmentJSON.installRemoval(staged, at: url)
                self.all = remaining
                self.error = nil
                if standalone { self.actionCount += 1 }
                await Task.detached { AttachmentJSON.removeUnusedPayloads(for: url, as: [ComposerDraft].self) }.value
                return true
            } catch {
                self.error = "Could not discard drafts. \(error.localizedDescription)"
                return false
            }
        }
    }
    /// Discards every draft sent from the given account.
    func discardDrafts(accountID: String) async -> Bool {
        await enqueue {
            // An unreadable store can still hold this account's drafts.
            guard self.loadFailure == nil else { self.error = self.loadFailure; return false }
            guard self.all.contains(where: { $0.accountID == accountID }) else { return true }
            return await self.persist(self.all.filter { $0.accountID != accountID })
        }
    }
    /// Puts back drafts that `discardDrafts(accountID:)` removed.
    func restore(_ restored: [ComposerDraft]) async -> Bool {
        await enqueue {
            let ids = Set(self.all.map(\.id))
            return await self.persist(restored.filter { !ids.contains($0.id) } + self.all)
        }
    }
    /// Saves `draft` to go out at `date`.
    func schedule(_ draft: ComposerDraft, at date: Date) async -> Bool {
        var draft = draft
        draft.sendAt = date
        return await save(draft)
    }
    /// Takes scheduled mail back into Drafts. False when it already went out.
    func unschedule(_ id: UUID) async -> Bool {
        await enqueue {
            guard let i = self.all.firstIndex(where: { $0.id == id && $0.sendAt != nil }) else { return false }
            var updated = self.all
            updated[i].sendAt = nil
            guard await self.persist(updated) else { return false }
            if self.undoable == id { self.undoable = nil }
            return true
        }
    }
    /// Takes scheduled mail back and asks the app to open it in the composer.
    func edit(_ id: UUID) async {
        if await unschedule(id) { reopening = id }
    }
    /// Sends outbox mail that is due.
    func sendDue(through store: MailStore, now: Date = .now) async {
        guard all.contains(where: { ($0.sendAt ?? .distantFuture) <= now }) else { return }
        _ = await deliver(through: store) { ($0.sendAt ?? .distantFuture) <= now }
    }
    /// Sends one scheduled message at once.
    func sendNow(_ id: UUID, through store: MailStore) async -> Bool {
        await deliver(through: store) { $0.id == id }
    }
    /// Sends the scheduled mail that `pick` selects. Each message goes out with its draft's ID, so a retry after a
    /// failed draft write removes the draft without sending it again. Mail the store refuses goes back to Drafts.
    private func deliver(through store: MailStore, pick: @escaping (ComposerDraft) -> Bool) async -> Bool {
        await enqueue {
            // Unreadable mail storage is temporary. The mail keeps waiting until it loads.
            guard !store.needsReload else { return false }
            var updated = self.all
            var failure: String?
            for draft in self.all where draft.sendAt != nil && pick(draft) {
                if store.send(draft, id: draft.id) {
                    updated.removeAll { $0.id == draft.id }
                } else if let i = updated.firstIndex(where: { $0.id == draft.id }) {
                    updated[i].sendAt = nil
                    failure = "“\(draft.title)” could not be sent and is back in Drafts. \(store.error ?? "")"
                }
            }
            guard updated != self.all else { return true }
            let saved = await self.persist(updated)
            if let undoable = self.undoable, !self.all.contains(where: { $0.id == undoable && $0.sendAt != nil }) { self.undoable = nil }
            if let failure { store.error = failure }
            return saved && failure == nil
        }
    }
    func togglePin(_ id: UUID) async {
        if await updateMailbox(ids: [id], change: { $0.pinned = !($0.pinned ?? false) }) { actionCount += 1 }
    }
    func snooze(_ ids: Set<UUID>, until date: Date) async -> Bool {
        guard date > .now else { return false }
        guard await updateMailbox(ids: ids, change: { $0.snoozedUntil = date }) else { return false }
        actionCount += 1
        return true
    }
    func restore(_ id: UUID) async -> Bool {
        guard await updateMailbox(ids: [id], change: { $0.snoozedUntil = nil }) else { return false }
        actionCount += 1
        return true
    }
    func wakeDue(now: Date = .now) async {
        guard all.contains(where: { ($0.snoozedUntil ?? .distantFuture) <= now }) else { return }
        _ = await enqueue {
            var updated = self.all
            for i in updated.indices where (updated[i].snoozedUntil ?? .distantFuture) <= now {
                updated[i].snoozedUntil = nil
            }
            if updated == self.all { return true }
            return await self.persist(updated)
        }
    }
    func finishPendingWrites() async {
        _ = await pending?.value
    }
    private func updateMailbox(ids: Set<UUID>, change: @escaping (inout ComposerDraft) -> Void) async -> Bool {
        await enqueue {
            var updated = self.all
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
            all = updated
            error = nil
            return true
        } catch { self.error = "Could not save drafts. \(error.localizedDescription)"; return false }
    }
    private func failedToLoad(_ error: any Error) {
        loadFailure = "Could not load drafts. Existing storage has not been changed. \(error.localizedDescription)"
        self.error = loadFailure
    }
}
