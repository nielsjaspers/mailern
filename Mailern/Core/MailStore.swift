import Foundation
import Observation

protocol ConversationPersistence {
    func load() throws -> [Conversation]?
    func save(_ conversations: [Conversation]) throws
}

struct JSONPersistence: ConversationPersistence {
    var url: URL
    func load() throws -> [Conversation]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode([Conversation].self, from: Data(contentsOf: url))
    }
    func save(_ conversations: [Conversation]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(conversations).write(to: url, options: .atomic)
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
    private let persistence: any ConversationPersistence

    init(persistence: any ConversationPersistence = JSONPersistence.local) {
        self.persistence = persistence
        do { conversations = try persistence.load() ?? DemoData.conversations() }
        catch { self.error = "Could not load demo data. Reset Demo Data to start again. \(error.localizedDescription)" }
        wakeDue()
    }
    func conversation(_ id: UUID) -> Conversation? { conversations.first { $0.id == id } }
    func list(_ status: Workflow, search: String = "", unreadFirst: Bool = false) -> [Conversation] {
        conversations.filter { c in
            c.workflow == status && (search.isEmpty || ([c.subject, c.account.name] + c.messages.flatMap { [$0.sender, $0.address, $0.body, $0.subject ?? ""] }).contains { $0.localizedCaseInsensitiveContains(search) })
        }.sorted {
            if status == .inbox && $0.pinned != $1.pinned { return $0.pinned }
            if status == .inbox && unreadFirst && $0.unread != $1.unread { return $0.unread }
            if status == .snoozed { return ($0.snoozedUntil ?? .distantFuture) < ($1.snoozedUntil ?? .distantFuture) }
            if $0.latest.date != $1.latest.date { return $0.latest.date > $1.latest.date }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
    private func save() {
        do { try persistence.save(conversations) }
        catch { self.error = "Changes could not be saved. \(error.localizedDescription)" }
    }
    private func update(_ id: UUID, _ action: (inout Conversation) -> Void) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        action(&conversations[index]); save()
    }
    func markRead(_ id: UUID, unread: Bool = false) {
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
        let before = conversations.filter { ids.contains($0.id) }
        guard !before.isEmpty else { return }
        undoSnapshot = before
        undoAction = action
        for i in conversations.indices where ids.contains(conversations[i].id) {
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
        save()
    }
    func undo() {
        guard let action = undoAction, !undoSnapshot.isEmpty else { return }
        // Incoming messages invalidate undo so a stale action cannot hide new mail.
        guard undoSnapshot.allSatisfy({ conversation($0.id)?.messages == $0.messages }) else { clearNotice(); return }
        for old in undoSnapshot {
            guard let i = conversations.firstIndex(where: { $0.id == old.id }) else { continue }
            switch action {
            case .move:
                conversations[i].workflow = old.workflow
                conversations[i].snoozedUntil = old.snoozedUntil
            case .read: conversations[i].unread = old.unread
            case .pin: conversations[i].pinned = old.pinned
            }
        }
        save()
        clearNotice()
    }
    func clearNotice() { notice = nil; undoSnapshot = []; undoAction = nil }
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
                                   body: "Hi Morgan,\n\nA quick follow-up on this. Have you had a chance to take a look? Let me know what you think.\n\nThanks,\n\(c.correspondent.sender)"))
        }
    }
    func receiveNew() {
        clearNotice()
        conversations.insert(Conversation(accountID: "icloud", subject: "Coffee this week?", messages: [MailMessage(sender: "Riley", address: "riley@example.com", to: [MailAccount.demo[1].address], date: .now, body: "Hi Morgan,\n\nI'll be in town on Thursday. Do you have time for a coffee around 11?\n\nRiley")]), at: 0)
        save()
    }
    @discardableResult
    func send(threadID: UUID?, account: MailAccount, to: [String], cc: [String], subject: String, body: String,
              bcc: [String] = [], richText: Data? = nil, attachments: [MailAttachment] = []) -> Bool {
        if let threadID, conversation(threadID) == nil {
            error = "The original conversation is no longer available. Your draft has not been sent."
            return false
        }
        clearNotice()
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
            error = nil
            return true
        } catch {
            conversations = before
            self.error = "Message could not be saved. Your draft has not been sent. \(error.localizedDescription)"
            return false
        }
    }
    func reset() { clearNotice(); conversations = DemoData.conversations(); save() }
}
