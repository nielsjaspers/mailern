import Foundation
import Observation

/// Everything the mail store persists. Blocked senders live here so a block survives deleting its junk.
struct MailData: Equatable {
    var conversations: [Conversation]
    var accounts = MailAccount.demo
    var blockedSenders: Set<String> = []
    var discardedDraftIDs: Set<UUID> = []
}

protocol ConversationPersistence {
    func load() throws -> MailData?
    func save(_ data: MailData) throws
    /// These rows changed only local metadata. Searchable fields and attachment references are unchanged.
    func saveMetadata(in data: MailData, at indices: [Int]) throws
    /// IDs of conversations whose stored text contains `text`, or nil when the store has no index for it.
    func search(_ text: String) throws -> Set<UUID>?
}

extension ConversationPersistence {
    func saveMetadata(in data: MailData, at indices: [Int]) throws { try save(data) }
    func search(_ text: String) throws -> Set<UUID>? { nil }
}

enum ConversationAction: Equatable {
    case move(Workflow, until: Date? = nil)
    case read(unread: Bool)
    case pin(Bool)
    case remove(RemovedMailbox)
    case restoreRemoved
}

@MainActor @Observable
final class MailStore {
    private(set) var conversations: [Conversation] = [] {
        didSet { mailboxRevision &+= 1 }
    }
    private(set) var mailboxRevision: UInt64 = 0
    private(set) var discardedDraftIDs: Set<UUID> = []
    private var nextExpiryRetry: Date?
    private(set) var blockedSenders: Set<String> = []
    private(set) var accounts = MailAccount.demo
    static let trashRetention: TimeInterval = 30 * 24 * 60 * 60
    var error: String?
    private(set) var notice: String?
    /// Counts the moves a person makes, such as Settle, Snooze, Pin, or Move to Trash. The mailbox plays a haptic on each change.
    private(set) var actionCount = 0
    @ObservationIgnored private let projections = MailboxProjections()

    func mailbox(drafts: [ComposerDraft], status: Workflow?, query: String, filter: MailboxFilter) -> MailboxProjections.Entry {
        projections.list(store: self, drafts: drafts, status: status, query: query, filter: filter)
    }

    var inboxUnreadCount: Int { projections.inboxUnread(store: self) }

    func endAllMailSearch() { projections.endAllMailSearch() }

    private var undoSnapshot: [Conversation] = []
    private var undoAction: ConversationAction?
    @ObservationIgnored private var noticeExpiryTask: Task<Void, Never>?
    private let persistence: any ConversationPersistence
    /// Sends a draft through the mail server before the store records it. Nil for demo mail, which sends nothing.
    @ObservationIgnored var sendRemote: ((ComposerDraft) async throws -> Void)?
    /// Loads a message's HTML part from the mail server.
    @ObservationIgnored var loadRemoteHTML: ((UUID) async throws -> String)?
    /// Accounts come from the mail server, so they cannot be added or deleted here.
    var isServerMailbox: Bool { sendRemote != nil }
    private var loadFailure: String?
    /// False after a failed save, when the stored search index can miss mail that only exists in memory.
    private var indexCurrent = true {
        didSet { if oldValue != indexCurrent { mailboxRevision &+= 1 } }
    }
    var needsReload: Bool { loadFailure != nil }

    init(persistence: any ConversationPersistence = SQLitePersistence.local) {
        self.persistence = persistence
        reload()
    }
    @discardableResult
    func reload() -> Bool {
        do {
            let stored = try persistence.load()
            let data = stored ?? MailData(conversations: DemoData.conversations())
            let loaded = data.conversations
            conversations = loaded.map { conversation in
                var normalized = conversation
                if normalized.workflow == .settled { normalized.unread = false }
                return normalized
            }
            discardedDraftIDs = data.discardedDraftIDs
            blockedSenders = data.blockedSenders
            accounts = data.accounts
            loadFailure = nil
            error = nil
            clearNotice()
            indexCurrent = true
            // Seed data is saved at once, so the search index covers it before the first change.
            if stored == nil || conversations != loaded { save() }
            wakeDue()
            return true
        } catch {
            let message = "Stored mail could not be loaded. Restore access, then retry loading mail. \(error.localizedDescription)"
            loadFailure = message
            self.error = message
            return false
        }
    }
    func conversation(_ id: UUID) -> Conversation? { conversations.first { $0.id == id } }
    func account(_ id: String) -> MailAccount { accounts.first { $0.id == id } ?? .removed(id) }
    /// Matches conversations against `text`. Queries the stored full-text index when it is current.
    func search(_ text: String) -> MailSearch {
        var result = MailSearch(text: text, accounts: accounts)
        if !text.isEmpty && indexCurrent {
            do { result.indexed = try persistence.search(text) }
            catch { result.canCache = false }
        }
        return result
    }
    func list(_ status: Workflow, search: String = "") -> [Conversation] {
        let search = self.search(search)
        return conversations.filter { c in
            c.removal == nil && c.workflow == status && search.matches(c)
        }.sorted {
            if status == .inbox && $0.pinned != $1.pinned { return $0.pinned }
            if status == .snoozed { return ($0.snoozedUntil ?? .distantFuture) < ($1.snoozedUntil ?? .distantFuture) }
            if $0.latest.date != $1.latest.date { return $0.latest.date > $1.latest.date }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
    /// Junk and Trash, newest first.
    func list(_ mailbox: RemovedMailbox, search: String = "") -> [Conversation] {
        let search = self.search(search)
        return conversations.filter { $0.removal?.mailbox == mailbox && search.matches($0) }.sorted {
            if $0.latest.date != $1.latest.date { return $0.latest.date > $1.latest.date }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
    func conversations(with address: String) -> [Conversation] {
        let address = address.lowercased()
        return conversations.filter { conversation in
            conversation.messages.contains { message in
                message.address.lowercased() == address ||
                (message.to + message.cc + (message.bcc ?? [])).contains { $0.lowercased() == address }
            }
        }.sorted {
            if $0.latest.date != $1.latest.date { return $0.latest.date > $1.latest.date }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
    func isSenderBlocked(_ address: String) -> Bool { blockedSenders.contains(address.lowercased()) }

    @discardableResult func setSenderBlocked(_ blocked: Bool, address: String) -> Bool {
        let address = address.lowercased()
        guard canWrite() else { return false }
        guard blocked != blockedSenders.contains(address) else { return true }
        let before = blockedSenders
        if blocked { blockedSenders.insert(address) } else { blockedSenders.remove(address) }
        guard save() else { blockedSenders = before; return false }
        return true
    }

    private var data: MailData { MailData(conversations: conversations, accounts: accounts, blockedSenders: blockedSenders, discardedDraftIDs: discardedDraftIDs) }
    @discardableResult private func save(replacingConversations updated: [Conversation]? = nil, metadataAt indices: [Int]? = nil, draftDiscards: Set<UUID>? = nil, reportFailure: Bool = true) -> Bool {
        guard canWrite() else { return false }
        var data = self.data
        if let updated { data.conversations = updated }
        if let draftDiscards { data.discardedDraftIDs = draftDiscards }
        do {
            if let indices, indexCurrent { try persistence.saveMetadata(in: data, at: indices) }
            else { try persistence.save(data) }
            if let draftDiscards { discardedDraftIDs = draftDiscards }
            indexCurrent = true
            return true
        } catch {
            if updated == nil { indexCurrent = false }
            if reportFailure { self.error = "Changes could not be saved. \(error.localizedDescription)" }
            return false
        }
    }
    func finishDraftDiscards(_ completed: Set<UUID>, reportFailure: Bool = true) {
        guard !discardedDraftIDs.isDisjoint(with: completed) else { return }
        save(replacingConversations: conversations, metadataAt: [], draftDiscards: discardedDraftIDs.subtracting(completed), reportFailure: reportFailure)
    }

    private func canWrite() -> Bool {
        guard let loadFailure else { return true }
        error = loadFailure
        return false
    }
    private func update(_ id: UUID, _ action: (inout Conversation) -> Void) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        action(&conversations[index]); save()
    }
    func markRead(_ id: UUID, unread: Bool = false) {
        guard let index = conversations.firstIndex(where: { $0.id == id }), conversations[index].workflow != .settled else { return }
        if case .read = undoAction { clearNotice() }
        guard conversations[index].unread != unread || !indexCurrent else { return }
        conversations[index].unread = unread
        save(metadataAt: [index])
    }
    func togglePin(_ id: UUID) {
        guard conversation(id) != nil else { return }
        if case .pin = undoAction { clearNotice() }
        update(id) { $0.pinned.toggle() }
        actionCount += 1
    }
    /// Read or Unread chosen by a person. Opening a conversation calls `markRead` instead, without a haptic.
    func setUnread(_ id: UUID, _ unread: Bool) {
        guard conversation(id)?.workflow ?? .settled != .settled else { return }
        markRead(id, unread: unread)
        actionCount += 1
    }
    func toggleMute(_ id: UUID) {
        update(id) { $0.muted = $0.muted == true ? nil : true }
    }
    @discardableResult func move(_ id: UUID, to status: Workflow, until: Date? = nil) -> Bool {
        apply(ids: [id], action: .move(status, until: until))
    }
    @discardableResult func apply(ids: Set<UUID>, action: ConversationAction, discarding drafts: Set<UUID> = []) -> Bool {
        if case .move(.snoozed, let until) = action, (until ?? .distantPast) <= .now { return false }
        let indices = conversations.indices.filter { index in
            let conversation = conversations[index]
            guard ids.contains(conversation.id) else { return false }
            switch action {
            case .read: return conversation.workflow != .settled
            case .remove(let mailbox): return conversation.removal?.mailbox != mailbox
            case .restoreRemoved: return conversation.removal != nil
            case .move, .pin: return true
            }
        }
        guard !indices.isEmpty else { return false }
        var updated = conversations
        for i in indices {
            switch action {
            case .move(let status, let until): updated[i].move(to: status, until: until)
            case .read(let unread): updated[i].unread = unread
            case .pin(let pinned): updated[i].pinned = pinned
            case .remove(.trash):
                updated[i].endReminder()
                updated[i].returnedFromSnoozeAt = nil
                updated[i].removal = .trash(since: .now)
            case .remove(.junk):
                updated[i].endReminder()
                updated[i].returnedFromSnoozeAt = nil
                updated[i].removal = .junk
            case .restoreRemoved:
                updated[i].removal = nil
                updated[i].blockedReplySourceID = nil
            }
        }
        let changed = indices.filter { conversations[$0] != updated[$0] }
        guard commitBatch(updated, changed: changed, discarding: drafts) else { return false }
        actionCount += 1
        undoSnapshot = indices.map { conversations[$0] }
        undoAction = action
        if !changed.isEmpty { conversations = updated }
        let message: String
        switch action {
        case .move(let status, _):
            message = status == .settled ? "Moved to Settled" : status == .snoozed ? "Conversation snoozed" : "Restored to Inbox"
        case .read(let unread): message = unread ? "Marked unread" : "Marked read"
        case .pin(let pinned): message = pinned ? "Pinned" : "Unpinned"
        case .remove(let mailbox): message = "Moved to \(mailbox.title)"
        case .restoreRemoved: message = "Restored"
        }
        notice = indices.count > 1 ? "\(indices.count) conversations: \(message)" : message
        noticeExpiryTask?.cancel()
        noticeExpiryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) }
            catch { return }
            self?.clearNotice()
        }
        return true
    }
    private func commitBatch(_ updated: [Conversation], changed: [Int], discarding drafts: Set<UUID> = []) -> Bool {
        if changed.isEmpty && drafts.isEmpty && indexCurrent { return true }
        return save(replacingConversations: updated, metadataAt: changed, draftDiscards: drafts.isEmpty ? nil : discardedDraftIDs.union(drafts))
    }

    func undo() {
        guard let action = undoAction, !undoSnapshot.isEmpty else { return }
        // Incoming messages invalidate undo so a stale action cannot hide new mail.
        let originals = Dictionary(uniqueKeysWithValues: undoSnapshot.map { ($0.id, $0) })
        let indices = conversations.indices.filter { originals[conversations[$0].id] != nil }
        guard indices.count == originals.count,
              indices.allSatisfy({ originals[conversations[$0].id]?.messages == conversations[$0].messages }) else {
            clearNotice()
            return
        }
        var updated = conversations
        for i in indices {
            let old = originals[updated[i].id]!
            switch action {
            case .move(let status, _):
                if status == .settled { updated[i].unread = old.unread }
                if old.workflow == .settled { updated[i].unread = false }
                updated[i].workflow = old.workflow
                updated[i].snoozedUntil = old.snoozedUntil
                updated[i].followUp = old.followUp
                updated[i].returnedFromSnoozeAt = old.returnedFromSnoozeAt
            case .read: updated[i].unread = old.unread
            case .pin: updated[i].pinned = old.pinned
            case .remove:
                // Removal can end a reminder, which settles the conversation.
                updated[i].removal = old.removal
                updated[i].workflow = old.workflow
                updated[i].snoozedUntil = old.snoozedUntil
                updated[i].followUp = old.followUp
                updated[i].returnedFromSnoozeAt = old.returnedFromSnoozeAt
                updated[i].unread = old.unread
            case .restoreRemoved:
                updated[i].removal = old.removal
                updated[i].blockedReplySourceID = old.blockedReplySourceID
            }
        }
        let changed = indices.filter { conversations[$0] != updated[$0] }
        guard commitBatch(updated, changed: changed) else {
            // Keep the same Undo available after dismissing a storage error.
            noticeExpiryTask?.cancel()
            return
        }
        if !changed.isEmpty { conversations = updated }
        clearNotice()
    }
    func clearNotice() {
        noticeExpiryTask?.cancel()
        noticeExpiryTask = nil
        notice = nil
        undoSnapshot = []
        undoAction = nil
    }
    /// A new reply draft must not ride a stale Undo back into Trash, Junk, or another section.
    func clearWorkflowUndo(involving ids: Set<UUID>) {
        switch undoAction {
        case .move, .remove, .restoreRemoved: break
        case .read, .pin, nil: return
        }
        guard undoSnapshot.contains(where: { ids.contains($0.id) }) else { return }
        clearNotice()
    }
    func wakeDue(now: Date = .now) {
        let due = conversations.indices.filter { index in
            let conversation = conversations[index]
            return conversation.workflow == .snoozed && conversation.snoozedUntil.map { $0 <= now } == true
        }
        if due.isEmpty { nextExpiryRetry = nil }
        if !due.isEmpty, nextExpiryRetry.map({ $0 <= now }) ?? true {
            var updated = conversations
            for i in due {
                let date = updated[i].snoozedUntil
                let waiting = updated[i].followUp == .waiting
                updated[i].move(to: .inbox)
                updated[i].returnedFromSnoozeAt = date
                if waiting { updated[i].followUp = .noReply }
            }
            if save(replacingConversations: updated, metadataAt: due, reportFailure: nextExpiryRetry == nil) {
                nextExpiryRetry = nil
                conversations = updated
                clearNotice()
            } else { nextExpiryRetry = now.addingTimeInterval(60) }
        }
        let expired = Set(conversations.filter {
            if case .trash(let since) = $0.removal { return since <= now.addingTimeInterval(-Self.trashRetention) }
            return false
        }.map(\.id))
        if !expired.isEmpty { deletePermanently(expired) }
    }
    /// Deletes conversations without Undo. Callers confirm first; expired Trash needs no confirmation.
    @discardableResult func deletePermanently(_ ids: Set<UUID>, from confirmedMailbox: RemovedMailbox? = nil, discarding drafts: Set<UUID> = []) -> Bool {
        guard canWrite(), !ids.isEmpty else { return false }
        if let confirmedMailbox {
            let stillInMailbox = conversations.count { ids.contains($0.id) && $0.removal?.mailbox == confirmedMailbox }
            guard stillInMailbox == ids.count else {
                error = "The mailbox changed. Review the selection before deleting."
                return false
            }
        }
        let remaining = conversations.filter { !ids.contains($0.id) }
        guard remaining.count != conversations.count else { return false }
        let discards = discardedDraftIDs.union(drafts)
        guard save(replacingConversations: remaining, draftDiscards: discards) else { return false }
        if undoSnapshot.contains(where: { ids.contains($0.id) }) { clearNotice() }
        conversations = remaining
        return true
    }
    /// Replaces mail with a merged server sync. Undo cannot restore a conversation that gained or lost mail since.
    func replaceRemote(conversations updated: [Conversation], accounts: [MailAccount], invalidatingUndo ids: Set<UUID>) {
        guard canWrite() else { return }
        let before = (self.accounts, conversations)
        self.accounts = accounts
        guard save(replacingConversations: updated) else { self.accounts = before.0; return }
        conversations = updated
        if !ids.isEmpty { clearWorkflowUndo(involving: ids) }
    }
    /// Loads and stores the HTML part of a message from the mail server.
    func loadHTML(message id: UUID, in conversationID: UUID) async {
        guard let loadRemoteHTML else { return }
        do {
            let html = try await loadRemoteHTML(id)
            guard let c = conversations.firstIndex(where: { $0.id == conversationID }),
                  let m = conversations[c].messages.firstIndex(where: { $0.id == id }) else { return }
            conversations[c].messages[m].html = html.isEmpty ? nil : html
            conversations[c].messages[m].remoteHTML = nil
            save()
        } catch {
            self.error = "The message could not be loaded. \(error.localizedDescription)"
        }
    }
    /// Why `account` cannot be saved, or nil when it can.
    func problem(with account: MailAccount) -> String? {
        if account.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Enter a name for this account." }
        let address = account.address.trimmingCharacters(in: .whitespacesAndNewlines)
        if !ComposerDraft.isAddress(address) { return "Enter a valid email address." }
        if accounts.contains(where: { $0.id != account.id && $0.address.caseInsensitiveCompare(address) == .orderedSame }) {
            return "Another account already uses this address."
        }
        return nil
    }
    /// Adds `account`, or replaces the stored account with the same ID.
    @discardableResult func saveAccount(_ account: MailAccount) -> Bool {
        guard canWrite(), problem(with: account) == nil else { return false }
        var account = account
        account.name = account.name.trimmingCharacters(in: .whitespacesAndNewlines)
        account.address = account.address.trimmingCharacters(in: .whitespacesAndNewlines)
        account.signature = account.signature.trimmingCharacters(in: .whitespacesAndNewlines)
        let before = accounts
        if let i = accounts.firstIndex(where: { $0.id == account.id }) { accounts[i] = account } else { accounts.append(account) }
        guard save() else { accounts = before; return false }
        error = nil
        return true
    }
    /// Removes an account with its drafts and conversations, and returns why it failed. Drafts go first:
    /// a draft left behind by a deleted account would have no sender address.
    func deleteAccount(_ id: String, drafts: DraftStore) async -> String? {
        guard canWrite(), accounts.count > 1 else { return error ?? "You need at least one account." }
        let removed = drafts.all.filter { $0.accountID == id }
        guard await drafts.discardDrafts(accountID: id) else {
            defer { drafts.error = nil }
            return drafts.error ?? "The account's drafts could not be deleted."
        }
        guard deleteAccount(id) else {
            let problem = error ?? "This account could not be deleted."
            _ = await drafts.restore(removed)
            return problem
        }
        return nil
    }
    /// Removes an account and its conversations without Undo. Callers confirm first. The last account stays.
    @discardableResult func deleteAccount(_ id: String) -> Bool {
        guard canWrite(), accounts.count > 1, accounts.contains(where: { $0.id == id }) else { return false }
        let before = (accounts, conversations)
        let removed = Set(conversations.filter { $0.accountID == id }.map(\.id))
        accounts.removeAll { $0.id == id }
        conversations.removeAll { removed.contains($0.id) }
        guard save() else { (accounts, conversations) = before; return false }
        if undoSnapshot.contains(where: { removed.contains($0.id) }) { clearNotice() }
        error = nil
        return true
    }
    /// Delivers an incoming message. It joins the conversation in `accountID` that holds a message it answers,
    /// by its In-Reply-To or References headers, or it starts a new conversation. `junk` marks mail a spam filter caught.
    func receive(_ message: MailMessage, accountID: String, junk: Bool = false) {
        guard canWrite() else { return }
        clearNotice()
        let blocked = isSenderBlocked(message.address)
        let junk = junk || blocked
        var target = replyTarget(for: message, in: accountID)
        var blockedReplySourceID: UUID?
        if let index = target {
            let parent = conversations[index]
            if blocked {
                let split = conversations.firstIndex { $0.blockedReplySourceID == parent.id && $0.removal == .junk }
                if split != nil || parent.removal != .junk {
                    blockedReplySourceID = parent.id
                    target = split
                }
            } else if !junk, parent.removal == .junk, let sourceID = parent.blockedReplySourceID {
                // A regular reply to a blocked message goes back to the original while the split is in Junk.
                target = conversations.firstIndex { $0.id == sourceID } ?? index
            }
        }
        if let i = target {
            conversations[i].receive(message)
            if junk { conversations[i].removal = .junk }
        } else {
            conversations.insert(Conversation(accountID: accountID, subject: message.subject ?? "(No Subject)",
                                              removal: junk ? .junk : nil, blockedReplySourceID: blockedReplySourceID,
                                              messages: [message]), at: 0)
        }
        save()
    }

    private func replyTarget(for message: MailMessage, in accountID: String) -> Int? {
        // References are oldest first. A known In-Reply-To outranks them all.
        let parents = (message.references ?? []) + (message.inReplyTo.map { [$0] } ?? [])
        guard !parents.isEmpty else { return nil }
        let priorities = Dictionary(parents.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: max)
        var closest: (index: Int, priority: Int)?
        for (index, conversation) in conversations.enumerated() where conversation.accountID == accountID {
            for parent in conversation.messages {
                guard let priority = priorities[parent.threadingID] else { continue }
                if priority == parents.count - 1 { return index }
                if priority > (closest?.priority ?? -1) { closest = (index, priority) }
            }
        }
        return closest?.index
    }
    func receiveReply(_ id: UUID) {
        guard let c = conversation(id) else { return }
        var reply = MailMessage(sender: c.correspondent.sender, address: c.correspondent.address, to: [account(c.accountID).address], date: .now,
                                body: "Hi Morgan,\n\nA quick follow-up on this. Have you had a chance to take a look? Let me know what you think.\n\nThanks,\n\(c.correspondent.sender)",
                                subject: c.effectiveSubject, messageID: MailMessage.newMessageID(from: c.correspondent.address))
        reply.answer(c.latest)
        receive(reply, accountID: c.accountID)
    }
    func receiveNew() {
        let account = accounts[0]
        receive(MailMessage(sender: "Riley", address: "riley@example.com", to: [account.address], date: .now,
                            body: "Hi Morgan,\n\nI'll be in town on Thursday. Do you have time for a coffee around 11?\n\nRiley",
                            subject: "Coffee this week?", messageID: MailMessage.newMessageID(from: "riley@example.com")), accountID: account.id)
    }
    /// Demo mail that a spam filter caught before it reached the Inbox.
    func receiveJunk() {
        let account = accounts[accounts.count - 1]
        receive(MailMessage(sender: "Prize Desk", address: "winner@prizes.example.net", to: [account.address], date: .now,
                            body: "Congratulations!\n\nYour address was selected for an exclusive reward. Confirm your details within 24 hours to claim it.\n\nPrize Desk",
                            subject: "You have been selected", messageID: MailMessage.newMessageID(from: "winner@prizes.example.net")),
                accountID: account.id, junk: true)
    }
    @discardableResult
    /// Sends a message. With a `threadID`, it answers the message `replyingTo` in that conversation, or the latest one.
    /// The conversation settles, or waits in Snoozed until `followUp` when that is still ahead.
    func send(threadID: UUID?, replyingTo: UUID? = nil, account: MailAccount, to: [String], cc: [String], subject: String, body: String,
              bcc: [String] = [], richText: Data? = nil, attachments: [MailAttachment] = [], followUp: Date? = nil, id: UUID = UUID(), discardingDraft: UUID? = nil) -> Bool {
        guard canWrite() else { return false }
        guard accounts.contains(where: { $0.id == account.id }) else {
            error = "The sending account no longer exists. Choose another From address."
            return false
        }
        if let threadID, conversation(threadID) == nil {
            error = "The original conversation is no longer available. Your draft has not been sent."
            return false
        }
        let before = conversations
        var message = MailMessage(id: id, sender: "Morgan", address: account.address, to: to, cc: cc, date: .now, body: body,
                                  outgoing: true, bcc: bcc.isEmpty ? nil : bcc, richText: richText, attachments: attachments.isEmpty ? nil : attachments,
                                  subject: subject, messageID: MailMessage.newMessageID(from: account.address, id: id))
        if let threadID, let i = conversations.firstIndex(where: { $0.id == threadID }) {
            message.answer(conversations[i].message(replyingTo))
            conversations[i].messages.append(message)
            conversations[i].removal = nil
        } else {
            // A new conversation takes the message's ID, so the mail server files the sent copy in the same thread.
            conversations.insert(Conversation(id: id, accountID: account.id, subject: subject, unread: false, messages: [message]), at: 0)
        }
        let i = threadID.flatMap { id in conversations.firstIndex { $0.id == id } } ?? 0
        if let followUp, followUp > .now {
            conversations[i].move(to: .snoozed, until: followUp)
            conversations[i].followUp = .waiting
        } else {
            conversations[i].move(to: .settled)
        }
        var sent = data
        if let discardingDraft { sent.discardedDraftIDs.insert(discardingDraft) }
        do {
            try persistence.save(sent)
            if discardingDraft != nil { discardedDraftIDs = sent.discardedDraftIDs }
            indexCurrent = true
            clearNotice()
            error = nil
            return true
        } catch {
            indexCurrent = false
            conversations = before
            self.error = "Message could not be saved. Your draft has not been sent. \(error.localizedDescription)"
            return false
        }
    }
    func hasSentOrDiscarded(_ id: UUID) -> Bool {
        discardedDraftIDs.contains(id) || conversations.contains { thread in
            thread.messages.contains { $0.outgoing && $0.id == id }
        }
    }

    /// Immediate sends use the same durable cleanup receipt as scheduled sends.
    @discardableResult func send(_ draft: ComposerDraft) -> Bool {
        if hasSentOrDiscarded(draft.id) { return true }
        return sendUnsentOutboxDraft(draft)
    }
    /// Sends now. Mail for a server account goes out through the server first; the store records only what it accepted.
    func sendNow(_ draft: ComposerDraft) async -> Bool {
        if hasSentOrDiscarded(draft.id) { return true }
        if let sendRemote {
            do { try await sendRemote(draft) } catch {
                self.error = "Message could not be sent. \(error.localizedDescription)"
                return false
            }
        }
        return sendUnsentOutboxDraft(draft)
    }

    /// Delivery checks the queued IDs together before calling this method.
    func sendUnsentOutboxDraft(_ draft: ComposerDraft) -> Bool {
        sendDraft(draft, id: draft.id, discardingDraft: draft.id)
    }

    private func sendDraft(_ draft: ComposerDraft, id: UUID, discardingDraft: UUID? = nil) -> Bool {
        return send(threadID: draft.mode.replyID, replyingTo: draft.answering ?? draft.messageID, account: account(draft.accountID),
                    to: ComposerDraft.addresses(draft.to), cc: ComposerDraft.addresses(draft.cc),
                    subject: draft.subject.isEmpty ? "(No Subject)" : draft.subject, body: draft.text,
                    bcc: ComposerDraft.addresses(draft.bcc), richText: draft.richText, attachments: draft.attachments,
                    followUp: draft.followUp, id: id, discardingDraft: discardingDraft)
    }
    func reset() {
        let replacement = MailData(conversations: DemoData.conversations(), discardedDraftIDs: discardedDraftIDs)
        do {
            try persistence.save(replacement)
            conversations = replacement.conversations
            discardedDraftIDs = replacement.discardedDraftIDs
            accounts = replacement.accounts
            blockedSenders = []
            indexCurrent = true
            loadFailure = nil
            error = nil
            clearNotice()
        } catch { self.error = "Demo data could not be reset. \(error.localizedDescription)" }
    }
}

/// A search over conversations and drafts. `indexed` holds full-text hits; nil scans message text in memory.
struct MailSearch {
    var text = ""
    var accounts = MailAccount.demo
    var indexed: Set<UUID>?
    var canCache = true

    private func accountName(_ id: String) -> String { accounts.first { $0.id == id }?.name ?? "" }
    private func contains(_ fields: [String]) -> Bool { fields.contains { $0.localizedCaseInsensitiveContains(text) } }
    func matches(_ conversation: Conversation) -> Bool {
        guard !text.isEmpty else { return true }
        if accountName(conversation.accountID).localizedCaseInsensitiveContains(text) { return true }
        if let indexed { return indexed.contains(conversation.id) }
        return contains([conversation.searchText])
    }
    func matches(_ draft: ComposerDraft) -> Bool {
        text.isEmpty || contains([draft.subject, draft.to, draft.cc, draft.bcc, draft.text, accountName(draft.accountID)])
    }
}
