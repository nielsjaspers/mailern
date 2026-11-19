import Foundation

/// The part of a conversation the mail server stores for Mailern. The server changes the provider's mailboxes to
/// match it: Settle archives, Pin flags, Trash and Junk move the thread. Snooze stays on the server only.
struct RemoteState: Codable, Equatable {
    var workflow: Workflow
    var snoozedUntil: Date?
    var removal: RemovedMailbox?
    var unread: Bool
    var pinned: Bool
    var muted: Bool

    init(workflow: Workflow, snoozedUntil: Date?, removal: RemovedMailbox?, unread: Bool, pinned: Bool, muted: Bool) {
        self.workflow = workflow
        // The wire format has whole seconds. Rounding here keeps a local snooze equal to the server's copy of it.
        self.snoozedUntil = snoozedUntil.map { Date(timeIntervalSince1970: $0.timeIntervalSince1970.rounded(.down)) }
        self.removal = removal
        self.unread = unread
        self.pinned = pinned
        self.muted = muted
    }
}

extension Conversation {
    var remoteState: RemoteState {
        RemoteState(workflow: workflow, snoozedUntil: snoozedUntil, removal: removal?.mailbox, unread: unread, pinned: pinned, muted: muted == true)
    }
    /// A change the server has not confirmed yet. Conversations the server never confirmed count as changed.
    var hasUnsyncedChanges: Bool { synced != remoteState }
}

struct RemoteAccount: Decodable, Equatable {
    var id: String
    var name: String
    var address: String
}

struct RemoteMessage: Decodable, Equatable {
    var id: UUID
    var sender: String
    var address: String
    var to: [String]?
    var cc: [String]?
    var date: Date
    var body: String
    var outgoing: Bool
    var subject: String
    var hasHTML: Bool
    var messageID: String?
    var inReplyTo: String?
    var references: [String]?
}

struct RemoteConversation: Decodable, Equatable {
    var id: UUID
    var accountID: String
    var subject: String
    var workflow: Workflow
    var snoozedUntil: Date?
    var returnedFromSnoozeAt: Date?
    var removal: RemovedMailbox?
    var trashSince: Date?
    var unread: Bool
    var pinned: Bool
    var muted: Bool
    var messages: [RemoteMessage]

    var state: RemoteState {
        RemoteState(workflow: workflow, snoozedUntil: snoozedUntil, removal: removal, unread: unread, pinned: pinned, muted: muted)
    }
}

struct RemoteSync: Decodable, Equatable {
    var revision: UInt64
    /// The server lost or replaced its state. Mailern drops what it has and keeps only this response.
    var reset: Bool
    var accounts: [RemoteAccount]
    var conversations: [RemoteConversation]
    var deleted: [UUID]
}

/// The JSON format of the mail server. Dates are UTC with whole seconds.
enum RemoteJSON {
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

extension MailStore {
    /// Applies a sync from the mail server. Conversations with unsynced local changes keep their workflow state until
    /// the server confirms it, but always take new messages. Local-only state stays: reminders, blocked replies,
    /// and the HTML, rich text, and attachments the phone already holds.
    func mergeRemote(_ sync: RemoteSync) {
        guard !needsReload else { return }
        var accounts = sync.accounts.enumerated().map { index, remote in
            var account = self.accounts.first { $0.id == remote.id }
                ?? MailAccount(id: remote.id, name: remote.name, address: remote.address,
                               color: AccountColor.allCases[index % AccountColor.allCases.count])
            account.address = remote.address
            return account
        }
        if accounts.isEmpty { accounts = self.accounts }
        var updated = sync.reset ? [] : conversations
        let positions = Dictionary(updated.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        var received = Set<UUID>()
        for remote in sync.conversations {
            let local = conversation(remote.id)
            let merged = merge(remote, into: local)
            if let local, merged.messages.count > local.messages.count { received.insert(remote.id) }
            if let index = positions[remote.id] { updated[index] = merged } else { updated.insert(merged, at: 0) }
        }
        let deleted = Set(sync.deleted)
        updated.removeAll { deleted.contains($0.id) }
        replaceRemote(conversations: updated, accounts: accounts, invalidatingUndo: received.union(deleted))
    }

    private func merge(_ remote: RemoteConversation, into local: Conversation?) -> Conversation {
        var c = local ?? Conversation(id: remote.id, accountID: remote.accountID, subject: remote.subject, messages: [])
        let known = Set(local?.messages.map(\.id) ?? [])
        c.accountID = remote.accountID
        c.subject = remote.subject
        c.messages = remote.messages.map { message in
            var m = MailMessage(id: message.id, sender: message.sender, address: message.address, to: message.to ?? [],
                                cc: message.cc ?? [], date: message.date, body: message.body, outgoing: message.outgoing,
                                subject: message.subject, messageID: message.messageID, inReplyTo: message.inReplyTo,
                                references: message.references, remoteID: message.id.uuidString)
            if let old = local?.messages.first(where: { $0.id == message.id }) {
                m.html = old.html
                m.richText = old.richText
                m.attachments = old.attachments
                m.bcc = old.bcc
            }
            m.remoteHTML = message.hasHTML && m.html == nil ? true : nil
            return m
        }
        if c.messages.isEmpty, let local { c.messages = local.messages }
        let replied = c.messages.contains { !$0.outgoing && !known.contains($0.id) } && local != nil
        if local?.hasUnsyncedChanges != true {
            let state = remote.state
            c.workflow = state.workflow
            c.snoozedUntil = state.snoozedUntil
            c.removal = switch state.removal {
            case .trash: .trash(since: remote.trashSince ?? .now)
            case .junk: .junk
            case nil: nil
            }
            c.unread = state.unread && state.workflow != .settled
            c.pinned = state.pinned
            c.muted = state.muted ? true : nil
            c.returnedFromSnoozeAt = remote.returnedFromSnoozeAt
            // A reply ends a reminder. Without one, a reminder that returned to Inbox is overdue.
            if c.followUp == .waiting, state.workflow != .snoozed {
                c.followUp = replied ? nil : .noReply
            }
        } else if replied, c.followUp == .waiting {
            c.followUp = nil
        }
        c.synced = remote.state
        if local == nil, let sender = c.messages.last(where: { !$0.outgoing })?.address, isSenderBlocked(sender) {
            // New mail from a blocked sender goes to Junk. The change syncs back like any other.
            c.removal = .junk
        }
        return c
    }
}
