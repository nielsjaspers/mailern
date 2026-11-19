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
    static let currentOutboxVersion = 2
    var outboxVersion: Int? = currentOutboxVersion
    /// The brief Undo Send hold uses the outbox but does not need a Send Later reminder.
    var holdingForUndo: Bool?
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

    /// A new draft from the preferred account, or a reply or forward from the conversation's account, with that account's signature.
    static func make(mode: ComposeMode, conversation: Conversation?, message: UUID? = nil, accounts: [MailAccount], preferredAccountID: String? = nil) -> Self {
        var draft = Self(mode: mode, messageID: message)
        draft.accountID = conversation?.accountID ?? accounts.first { $0.id == preferredAccountID }?.id ?? accounts.first?.id ?? draft.accountID
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
    private(set) var all: [ComposerDraft] = [] {
        didSet { reminderRevision &+= 1 }
    }
    private(set) var reminderRevision: UInt64 = 0
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
    private var mail: MailStore?
    private let url: URL
    private let write: @Sendable (Data, URL) throws -> Void
    private var loadFailure: String?
    var hasReadableManifest: Bool { loadFailure == nil }
    var needsReload: Bool { !hasReadableManifest || mail?.discardedDraftIDs.isEmpty == false }
    private var needsMailRecovery = false
    private var retryMailRecoveryAfter: Date?
    private var recoveryFailureReported = false
    private struct DraftWake: Hashable {
        let id: UUID
        let deadline: Date
    }
    private var failedDraftWakes: Set<DraftWake> = []
    private var retryDraftWakeAfter: Date?
    @ObservationIgnored private var pending: Task<Bool, Never>?

    init(url: URL = URL.applicationSupportDirectory.appending(path: "Mailern/drafts-v1.json"), mail: MailStore? = nil,
         write: @escaping @Sendable (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) {
        self.url = url
        self.mail = mail
        self.write = write
        if let mail, mail.needsReload {
            loadFailure = mail.error
            needsMailRecovery = true
            return
        }
        do {
            loadManifest(try Self.read(url, write: write))
            needsMailRecovery = mail?.discardedDraftIDs.isEmpty == false
        }
        catch { failedToLoad(error) }
    }
    private nonisolated static func read(_ url: URL, write: @Sendable (Data, URL) throws -> Void) throws -> [ComposerDraft] {
        let stored = try AttachmentJSON.load([ComposerDraft].self, from: url) ?? []
        let current = stored.filter { $0.sendAt == nil || $0.outboxVersion == ComposerDraft.currentOutboxVersion }
        if current.count != stored.count { try AttachmentJSON.save(current, to: url, write: write) }
        return current
    }
    private func loadManifest(_ loaded: [ComposerDraft]) {
        all = loaded.filter { mail?.discardedDraftIDs.contains($0.id) != true }
        clearResolvedWakeFailures()
    }

    func reload(automatic: Bool = false) async {
        let url = url
        _ = await enqueue {
            do {
                if let mail = self.mail, mail.needsReload { self.error = mail.error; return false }
                let write = self.write
                let loaded = try await Task.detached { try Self.read(url, write: write) }.value
                self.loadManifest(loaded)
                self.loadFailure = nil
                if self.mail?.discardedDraftIDs.isEmpty == false {
                    self.needsMailRecovery = true
                    guard await self.persist(self.all, reportFailure: !automatic || !self.recoveryFailureReported),
                          self.mail?.discardedDraftIDs.isEmpty != false else { return false }
                }
                self.needsMailRecovery = false
                self.recoveryFailureReported = false
                self.retryMailRecoveryAfter = nil
                self.error = nil
                return true
            } catch { self.failedToLoad(error, report: !automatic || !self.recoveryFailureReported); return false }
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
            guard self.all.contains(where: { $0.id == id }) || self.mail?.discardedDraftIDs.contains(id) == true else {
                if self.loadFailure == nil {
                    let url = self.url
                    await Task.detached { AttachmentJSON.removeUnusedPayloads(for: url, as: [ComposerDraft].self) }.value
                }
                return true
            }
            return await self.persist(self.all.filter { $0.id != id })
        }
    }
    /// Mail records the discarded IDs in the same transaction as the move. The draft file can catch up after a crash.
    func discardDrafts(for ids: Set<UUID>, scheduled: Bool = false,
                       committingMail: (@MainActor (Set<UUID>) -> Bool)? = nil) async -> Bool {
        await enqueue {
            guard self.loadFailure == nil else { self.error = self.loadFailure; return false }
            let removed = Set(self.all.filter { draft in
                (scheduled || draft.sendAt == nil) && (ids.contains(draft.id) || draft.mode.replyID.map(ids.contains) == true)
            }.map(\.id))
            guard !removed.isEmpty else { return committingMail?([]) ?? true }
            let standalone = self.drafts.contains { removed.contains($0.id) && ids.contains($0.id) }
            let discards = removed.union(self.mail?.discardedDraftIDs ?? [])
            let remaining = self.all.filter { !discards.contains($0.id) }
            if let committingMail {
                let url = self.url
                let write = self.write
                let staged: URL
                do {
                    staged = try await Task.detached(priority: .utility) {
                        try AttachmentJSON.stageRemoval(remaining, at: url, write: write)
                    }.value
                } catch {
                    self.error = "Could not save drafts. \(error.localizedDescription)"
                    return false
                }
                defer { try? FileManager.default.removeItem(at: staged.deletingLastPathComponent()) }
                guard committingMail(removed) else { return false }
                self.all = remaining
                self.clearResolvedWakeFailures()
                do {
                    try AttachmentJSON.installRemoval(staged, at: url)
                    self.mail?.finishDraftDiscards(discards)
                    self.error = nil
                    await Task.detached { AttachmentJSON.removeUnusedPayloads(for: url, as: [ComposerDraft].self) }.value
                } catch {
                    self.error = "Mail was updated. Retry draft cleanup. \(error.localizedDescription)"
                }
            } else {
                guard await self.persist(remaining) else { return false }
            }
            if standalone { self.actionCount += 1 }
            return true
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
    func schedule(_ draft: ComposerDraft, at date: Date, holdingForUndo: Bool = false) async -> Bool {
        var draft = draft
        draft.outboxVersion = ComposerDraft.currentOutboxVersion
        draft.sendAt = date
        draft.holdingForUndo = holdingForUndo ? true : nil
        return await save(draft)
    }
    /// Takes scheduled mail back into Drafts. False when it already went out.
    func unschedule(_ id: UUID) async -> Bool {
        await enqueue {
            guard let i = self.all.firstIndex(where: { $0.id == id && $0.sendAt != nil }) else { return false }
            var updated = self.all
            updated[i].sendAt = nil
            updated[i].holdingForUndo = nil
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
    func sendDue(through store: MailStore, now: Date = .now, whileActive: @escaping @MainActor () -> Bool = { true }) async {
        guard all.contains(where: { ($0.sendAt ?? .distantFuture) <= now }) else { return }
        _ = await deliver(through: store, automatic: true) { whileActive() && ($0.sendAt ?? .distantFuture) <= now }
    }
    /// Sends one scheduled message at once.
    func sendNow(_ id: UUID, through store: MailStore) async -> Bool {
        await deliver(through: store) { $0.id == id }
    }
    /// Sends the scheduled mail that `pick` selects. Each message goes out with its draft's ID, so a retry after a
    /// failed draft write removes the draft without sending it again. Mail the store refuses goes back to Drafts.
    private func deliver(through store: MailStore, automatic: Bool = false, pick: @escaping (ComposerDraft) -> Bool) async -> Bool {
        await enqueue {
            // A failed reload can leave an obsolete outbox snapshot in memory.
            guard self.hasReadableManifest, !store.needsReload else { return false }
            // Standalone draft stores bind to their mailbox the first time they deliver.
            if self.mail == nil { self.mail = store }
            let queued = Set(self.all.lazy.filter { $0.sendAt != nil && pick($0) }.map(\.id))
            guard !queued.isEmpty else { return true }
            var failure: String?
            let updated = self.all.compactMap { draft -> ComposerDraft? in
                guard queued.contains(draft.id) else { return draft }
                guard !store.discardedDraftIDs.contains(draft.id) else { return nil }
                if store.sendUnsentOutboxDraft(draft) { return nil }
                var refused = draft
                refused.sendAt = nil
                refused.holdingForUndo = nil
                failure = "“\(draft.title)” could not be sent and is back in Drafts. \(store.error ?? "")"
                return refused
            }
            let saved = await self.persist(updated, reportFailure: !automatic || !self.recoveryFailureReported)
            if !saved, !store.discardedDraftIDs.isEmpty {
                self.all.removeAll { store.discardedDraftIDs.contains($0.id) }
                self.clearResolvedWakeFailures()
                self.needsMailRecovery = true
            }
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
    func wakeDue(now: Date = .now, whileActive: @escaping @MainActor () -> Bool = { true }) async {
        guard all.contains(where: { ($0.snoozedUntil ?? .distantFuture) <= now }) else { return }
        _ = await enqueue {
            guard whileActive(), self.hasReadableManifest, (self.retryDraftWakeAfter ?? .distantPast) <= now else { return false }
            var updated = self.all
            for i in updated.indices where (updated[i].snoozedUntil ?? .distantFuture) <= now {
                updated[i].snoozedUntil = nil
            }
            if updated == self.all { return true }
            let saved = await self.persist(updated, reportFailure: !self.recoveryFailureReported && self.retryDraftWakeAfter == nil)
            if !saved {
                self.failedDraftWakes = Set(self.all.compactMap { draft in
                    guard let date = draft.snoozedUntil, date <= now else { return nil }
                    return DraftWake(id: draft.id, deadline: date)
                })
                self.retryDraftWakeAfter = now.addingTimeInterval(30)
            }
            return saved
        }
    }
    func recoverAfterMailLoad(now: Date = .now) async {
        guard needsMailRecovery, mail?.needsReload != true, (retryMailRecoveryAfter ?? .distantPast) <= now else { return }
        await reload(automatic: true)
        needsMailRecovery = !hasReadableManifest || mail?.discardedDraftIDs.isEmpty == false
        if needsMailRecovery { retryMailRecoveryAfter = now.addingTimeInterval(30) }
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
    private func persist(_ updated: [ComposerDraft], reportFailure: Bool = true) async -> Bool {
        guard loadFailure == nil else { error = loadFailure; return false }
        let url = url
        let write = write
        let discarded = mail?.discardedDraftIDs ?? []
        let updated = discarded.isEmpty ? updated : updated.filter { !discarded.contains($0.id) }
        do {
            try await Task.detached(priority: .utility) {
                try AttachmentJSON.save(updated, to: url, write: write)
            }.value
            all = updated
            clearResolvedWakeFailures()
            mail?.finishDraftDiscards(discarded, reportFailure: reportFailure)
            needsMailRecovery = mail?.discardedDraftIDs.isEmpty == false
            recoveryFailureReported = needsMailRecovery
            error = nil
            return true
        } catch {
            if !discarded.isEmpty {
                needsMailRecovery = true
                recoveryFailureReported = recoveryFailureReported || reportFailure
            }
            if reportFailure { self.error = "Could not save drafts. \(error.localizedDescription)" }
            return false
        }
    }
    private func clearResolvedWakeFailures() {
        guard !failedDraftWakes.isEmpty else { return }
        if all.contains(where: { draft in
            guard let date = draft.snoozedUntil else { return false }
            return failedDraftWakes.contains(DraftWake(id: draft.id, deadline: date))
        }) { return }
        failedDraftWakes.removeAll()
        retryDraftWakeAfter = nil
    }

    private func failedToLoad(_ error: any Error, report: Bool = true) {
        needsMailRecovery = true
        loadFailure = "Could not load drafts. Existing storage has not been changed. \(error.localizedDescription)"
        if report { self.error = loadFailure; recoveryFailureReported = true }
    }
}
