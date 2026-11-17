import Foundation
import Observation

/// Everything the mail store persists. Blocked senders live here so a block survives deleting its junk.
struct MailData: Codable, Equatable {
    var conversations: [Conversation]
    var blockedSenders: Set<String> = []
}

protocol ConversationPersistence {
    func load() throws -> MailData?
    func save(_ data: MailData) throws
}

struct JSONPersistence: ConversationPersistence {
    var url: URL
    func load() throws -> MailData? {
        try AttachmentJSON.load(MailData.self, from: url)
    }
    func save(_ data: MailData) throws {
        try AttachmentJSON.save(data, to: url)
    }
    static var local: Self {
        Self(url: URL.applicationSupportDirectory.appending(path: "Mailern/demo-v2.json"))
    }
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
    private(set) var conversations: [Conversation] = []
    private(set) var blockedSenders: Set<String> = []
    static let trashRetention: TimeInterval = 30 * 24 * 60 * 60
    var error: String?
    private(set) var notice: String?
    private var undoSnapshot: [Conversation] = []
    private var undoAction: ConversationAction?
    private var undoBlockedSenders: Set<String> = []
    @ObservationIgnored private var noticeExpiryTask: Task<Void, Never>?
    private let persistence: any ConversationPersistence
    private var loadFailure: String?
    var needsReload: Bool { loadFailure != nil }

    init(persistence: any ConversationPersistence = JSONPersistence.local) {
        self.persistence = persistence
        reload()
    }
    @discardableResult
    func reload() -> Bool {
        do {
            let data = try persistence.load() ?? MailData(conversations: DemoData.conversations())
            let loaded = data.conversations
            conversations = loaded.map { conversation in
                var normalized = conversation
                if normalized.workflow == .settled { normalized.unread = false }
                return normalized
            }
            blockedSenders = data.blockedSenders
            loadFailure = nil
            error = nil
            clearNotice()
            if conversations != loaded { save() }
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
    func list(_ status: Workflow, search: String = "") -> [Conversation] {
        conversations.filter { c in
            c.removal == nil && c.workflow == status && c.matches(search)
        }.sorted {
            if status == .inbox && $0.pinned != $1.pinned { return $0.pinned }
            if status == .snoozed { return ($0.snoozedUntil ?? .distantFuture) < ($1.snoozedUntil ?? .distantFuture) }
            if $0.latest.date != $1.latest.date { return $0.latest.date > $1.latest.date }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
    /// Junk and Trash, newest first.
    func list(_ mailbox: RemovedMailbox, search: String = "") -> [Conversation] {
        conversations.filter { $0.removal?.mailbox == mailbox && $0.matches(search) }.sorted {
            if $0.latest.date != $1.latest.date { return $0.latest.date > $1.latest.date }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
    private var data: MailData { MailData(conversations: conversations, blockedSenders: blockedSenders) }
    private func save() {
        guard canWrite() else { return }
        do { try persistence.save(data) }
        catch { self.error = "Changes could not be saved. \(error.localizedDescription)" }
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
        guard conversation(id)?.workflow != .settled else { return }
        if case .read = undoAction { clearNotice() }
        update(id) { $0.unread = unread }
    }
    func togglePin(_ id: UUID) {
        if case .pin = undoAction { clearNotice() }
        update(id) { $0.pinned.toggle() }
    }
    func move(_ id: UUID, to status: Workflow, until: Date? = nil) {
        apply(ids: [id], action: .move(status, until: until))
    }
    func apply(ids: Set<UUID>, action: ConversationAction) {
        if case .move(.snoozed, let until) = action, (until ?? .distantPast) <= .now { return }
        let before = conversations.filter {
            guard ids.contains($0.id) else { return false }
            switch action {
            case .read: return $0.workflow != .settled
            case .remove(let mailbox): return $0.removal?.mailbox != mailbox
            case .restoreRemoved: return $0.removal != nil
            case .move, .pin: return true
            }
        }
        guard !before.isEmpty else { return }
        undoSnapshot = before
        undoAction = action
        undoBlockedSenders = blockedSenders
        let affectedIDs = Set(before.map(\.id))
        for i in conversations.indices where affectedIDs.contains(conversations[i].id) {
            switch action {
            case .move(let status, let until): conversations[i].move(to: status, until: until)
            case .read(let unread): conversations[i].unread = unread
            case .pin(let pinned): conversations[i].pinned = pinned
            case .remove(.trash): conversations[i].removal = .trash(since: .now)
            case .remove(.junk):
                conversations[i].removal = .junk
                blockedSenders.formUnion(conversations[i].senderAddresses)
            case .restoreRemoved:
                if conversations[i].removal == .junk { blockedSenders.subtract(conversations[i].senderAddresses) }
                conversations[i].removal = nil
            }
        }
        let message: String
        switch action {
        case .move(let status, _):
            message = status == .settled ? "Moved to Settled" : status == .snoozed ? "Conversation snoozed" : "Restored to Inbox"
        case .read(let unread): message = unread ? "Marked unread" : "Marked read"
        case .pin(let pinned): message = pinned ? "Pinned" : "Unpinned"
        case .remove(let mailbox): message = "Moved to \(mailbox.title)"
        case .restoreRemoved: message = "Restored"
        }
        notice = before.count > 1 ? "\(before.count) conversations: \(message)" : message
        noticeExpiryTask?.cancel()
        noticeExpiryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) }
            catch { return }
            self?.clearNotice()
        }
        save()
    }
    func undo() {
        guard let action = undoAction, !undoSnapshot.isEmpty else { return }
        // Incoming messages invalidate undo so a stale action cannot hide new mail.
        guard undoSnapshot.allSatisfy({ conversation($0.id)?.messages == $0.messages }) else { clearNotice(); return }
        for old in undoSnapshot {
            guard let i = conversations.firstIndex(where: { $0.id == old.id }) else { continue }
            switch action {
            case .move(let status, _):
                if status == .settled { conversations[i].unread = old.unread }
                if old.workflow == .settled { conversations[i].unread = false }
                conversations[i].workflow = old.workflow
                conversations[i].snoozedUntil = old.snoozedUntil
            case .read: conversations[i].unread = old.unread
            case .pin: conversations[i].pinned = old.pinned
            case .remove, .restoreRemoved: conversations[i].removal = old.removal
            }
        }
        blockedSenders = undoBlockedSenders
        save()
        clearNotice()
    }
    func clearNotice() {
        noticeExpiryTask?.cancel()
        noticeExpiryTask = nil
        notice = nil
        undoSnapshot = []
        undoAction = nil
        undoBlockedSenders = []
    }
    func clearWorkflowUndo(involving ids: Set<UUID>) {
        guard case .move = undoAction, undoSnapshot.contains(where: { ids.contains($0.id) }) else { return }
        clearNotice()
    }
    func wakeDue(now: Date = .now) {
        var changed = false
        for i in conversations.indices where conversations[i].workflow == .snoozed {
            if let date = conversations[i].snoozedUntil, date <= now { conversations[i].move(to: .inbox); changed = true }
        }
        if changed { clearNotice(); save() }
        let expired = Set(conversations.filter {
            if case .trash(let since) = $0.removal { return since <= now.addingTimeInterval(-Self.trashRetention) }
            return false
        }.map(\.id))
        if !expired.isEmpty { deletePermanently(expired) }
    }
    /// Deletes conversations without Undo. Callers confirm first; expired Trash needs no confirmation.
    func deletePermanently(_ ids: Set<UUID>) {
        guard canWrite(), conversations.contains(where: { ids.contains($0.id) }) else { return }
        if undoSnapshot.contains(where: { ids.contains($0.id) }) { clearNotice() }
        conversations.removeAll { ids.contains($0.id) }
        save()
    }
    func emptyTrash() { deletePermanently(Set(list(.trash).map(\.id))) }
    private func deliver(_ message: MailMessage, to id: UUID) {
        update(id) {
            $0.receive(message)
            if blockedSenders.contains(message.address.lowercased()) { $0.removal = .junk }
        }
    }
    func receiveReply(_ id: UUID) {
        guard let c = conversation(id) else { return }
        clearNotice()
        deliver(MailMessage(sender: c.correspondent.sender, address: c.correspondent.address, to: [c.account.address], date: .now,
                            body: "Hi Morgan,\n\nA quick follow-up on this. Have you had a chance to take a look? Let me know what you think.\n\nThanks,\n\(c.correspondent.sender)", subject: c.effectiveSubject), to: id)
    }
    func receiveNew() {
        receive(Conversation(accountID: "icloud", subject: "Coffee this week?", messages: [MailMessage(sender: "Riley", address: "riley@example.com", to: [MailAccount.demo[1].address], date: .now, body: "Hi Morgan,\n\nI'll be in town on Thursday. Do you have time for a coffee around 11?\n\nRiley")]))
    }
    /// Demo mail that a spam filter caught before it reached the Inbox.
    func receiveJunk() {
        receive(Conversation(accountID: "gmail", subject: "You have been selected", removal: .junk, messages: [MailMessage(sender: "Prize Desk", address: "winner@prizes.example.net", to: [MailAccount.demo[3].address], date: .now, body: "Congratulations!\n\nYour address was selected for an exclusive reward. Confirm your details within 24 hours to claim it.\n\nPrize Desk")]))
    }
    private func receive(_ conversation: Conversation) {
        guard canWrite() else { return }
        clearNotice()
        var conversation = conversation
        if !conversation.senderAddresses.isDisjoint(with: blockedSenders) { conversation.removal = .junk }
        conversations.insert(conversation, at: 0)
        save()
    }
    @discardableResult
    func send(threadID: UUID?, account: MailAccount, to: [String], cc: [String], subject: String, body: String,
              bcc: [String] = [], richText: Data? = nil, attachments: [MailAttachment] = []) -> Bool {
        guard canWrite() else { return false }
        if let threadID, conversation(threadID) == nil {
            error = "The original conversation is no longer available. Your draft has not been sent."
            return false
        }
        let before = conversations
        let message = MailMessage(sender: "Morgan", address: account.address, to: to, cc: cc, date: .now, body: body,
                                  outgoing: true, bcc: bcc.isEmpty ? nil : bcc, richText: richText, attachments: attachments.isEmpty ? nil : attachments, subject: subject)
        if let threadID, let i = conversations.firstIndex(where: { $0.id == threadID }) {
            conversations[i].messages.append(message)
            conversations[i].move(to: .settled)
            conversations[i].removal = nil
        } else {
            conversations.insert(Conversation(accountID: account.id, subject: subject, workflow: .settled, unread: false, messages: [message]), at: 0)
        }
        do {
            try persistence.save(data)
            clearNotice()
            error = nil
            return true
        } catch {
            conversations = before
            self.error = "Message could not be saved. Your draft has not been sent. \(error.localizedDescription)"
            return false
        }
    }
    func reset() {
        let replacement = MailData(conversations: DemoData.conversations())
        do {
            try persistence.save(replacement)
            conversations = replacement.conversations
            blockedSenders = []
            loadFailure = nil
            error = nil
            clearNotice()
        } catch { self.error = "Demo data could not be reset. \(error.localizedDescription)" }
    }
}

extension Conversation {
    func matches(_ search: String) -> Bool {
        search.isEmpty || ([subject, account.name] + messages.flatMap { [$0.sender, $0.address, $0.body, $0.subject ?? ""] })
            .contains { $0.localizedCaseInsensitiveContains(search) }
    }
}
