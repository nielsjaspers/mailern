import Foundation
import Observation

protocol ConversationPersistence {
    func load() throws -> [Conversation]?
    func save(_ conversations: [Conversation]) throws
}

struct JSONPersistence: ConversationPersistence {
    var url: URL
    func load() throws -> [Conversation]? {
        try AttachmentJSON.load([Conversation].self, from: url)
    }
    func save(_ conversations: [Conversation]) throws {
        try AttachmentJSON.save(conversations, to: url)
    }
    static var local: Self {
        Self(url: URL.applicationSupportDirectory.appending(path: "Mailern/demo-v1.json"))
    }
}

enum ConversationAction {
    case move(Workflow, until: Date? = nil)
    case read(unread: Bool)
    case pin(Bool)
}

@MainActor @Observable
final class MailStore {
    private(set) var conversations: [Conversation] = []
    var error: String?
    private(set) var notice: String?
    private var undoSnapshot: [Conversation] = []
    private var undoAction: ConversationAction?
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
            let loaded = try persistence.load() ?? DemoData.conversations()
            conversations = loaded.map { conversation in
                var normalized = conversation
                if normalized.workflow == .settled { normalized.unread = false }
                return normalized
            }
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
            c.workflow == status && (search.isEmpty || ([c.subject, c.account.name] + c.messages.flatMap { [$0.sender, $0.address, $0.body, $0.subject ?? ""] }).contains { $0.localizedCaseInsensitiveContains(search) })
        }.sorted {
            if status == .inbox && $0.pinned != $1.pinned { return $0.pinned }
            if status == .snoozed { return ($0.snoozedUntil ?? .distantFuture) < ($1.snoozedUntil ?? .distantFuture) }
            if $0.latest.date != $1.latest.date { return $0.latest.date > $1.latest.date }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
    private func save() {
        guard canWrite() else { return }
        do { try persistence.save(conversations) }
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
            if case .read = action { return $0.workflow != .settled }
            return true
        }
        guard !before.isEmpty else { return }
        undoSnapshot = before
        undoAction = action
        let affectedIDs = Set(before.map(\.id))
        for i in conversations.indices where affectedIDs.contains(conversations[i].id) {
            switch action {
            case .move(let status, let until): conversations[i].move(to: status, until: until)
            case .read(let unread): conversations[i].unread = unread
            case .pin(let pinned): conversations[i].pinned = pinned
            }
        }
        let message: String
        switch action {
        case .move(let status, _):
            message = status == .settled ? "Moved to Settled" : status == .snoozed ? "Conversation snoozed" : "Restored to Inbox"
        case .read(let unread): message = unread ? "Marked unread" : "Marked read"
        case .pin(let pinned): message = pinned ? "Pinned" : "Unpinned"
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
            }
        }
        save()
        clearNotice()
    }
    func clearNotice() {
        noticeExpiryTask?.cancel()
        noticeExpiryTask = nil
        notice = nil
        undoSnapshot = []
        undoAction = nil
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
    }
    func receiveReply(_ id: UUID) {
        guard let c = conversation(id) else { return }
        clearNotice()
        update(id) {
            $0.receive(MailMessage(sender: c.correspondent.sender, address: c.correspondent.address, to: [c.account.address], date: .now,
                                   body: "Hi Morgan,\n\nA quick follow-up on this. Have you had a chance to take a look? Let me know what you think.\n\nThanks,\n\(c.correspondent.sender)", subject: c.effectiveSubject))
        }
    }
    func receiveNew() {
        guard canWrite() else { return }
        clearNotice()
        conversations.insert(Conversation(accountID: "icloud", subject: "Coffee this week?", messages: [MailMessage(sender: "Riley", address: "riley@example.com", to: [MailAccount.demo[1].address], date: .now, body: "Hi Morgan,\n\nI'll be in town on Thursday. Do you have time for a coffee around 11?\n\nRiley")]), at: 0)
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
        } else {
            conversations.insert(Conversation(accountID: account.id, subject: subject, workflow: .settled, unread: false, messages: [message]), at: 0)
        }
        do {
            try persistence.save(conversations)
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
        let replacement = DemoData.conversations()
        do {
            try persistence.save(replacement)
            conversations = replacement
            loadFailure = nil
            error = nil
            clearNotice()
        } catch { self.error = "Demo data could not be reset. \(error.localizedDescription)" }
    }
}
