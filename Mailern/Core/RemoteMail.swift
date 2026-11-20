import Foundation
import Observation

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

enum RemoteStateField: String, Codable, CaseIterable {
    case workflow, removal, unread, pinned, muted
}

struct RemoteStateWrite: Encodable {
    let state: RemoteState
    let fields: Set<RemoteStateField>
    /// The messages the phone knew when it made the change. The server keeps a newer reply in Inbox.
    let messageIDs: [UUID]

    private enum CodingKeys: String, CodingKey { case fields, messageIDs }

    func encode(to encoder: Encoder) throws {
        try state.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(RemoteStateField.allCases.filter(fields.contains), forKey: .fields)
        try container.encode(messageIDs.map { $0.uuidString.lowercased() }, forKey: .messageIDs)
    }
}

struct DeleteConfirmation {
    struct Member: Equatable {
        let messageIDs: Set<UUID>
        let mailboxIdentity: String?
    }

    let mailbox: RemovedMailbox
    let members: [UUID: Member]

    var ids: Set<UUID> { Set(members.keys) }
}

struct RemoteDelete: Codable, Equatable {
    let messageIDs: Set<UUID>
    var expectedWorkflow: Workflow
    var expectedRemoval: RemovedMailbox?
    let removal: RemovedMailbox
    let mailboxIdentity: String?

    private enum CodingKeys: String, CodingKey { case messageIDs, expectedWorkflow, expectedRemoval, removal, mailboxIdentity }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(messageIDs.map { $0.uuidString.lowercased() }.sorted(), forKey: .messageIDs)
        try container.encode(expectedWorkflow, forKey: .expectedWorkflow)
        try container.encodeIfPresent(expectedRemoval, forKey: .expectedRemoval)
        try container.encode(removal, forKey: .removal)
        try container.encodeIfPresent(mailboxIdentity, forKey: .mailboxIdentity)
    }
}

struct PendingRemoteDelete: Codable, Equatable {
    var request: RemoteDelete
    let cached: Conversation
    var needsRefresh = false
}

extension RemoteState {
    func changedFields(since baseline: RemoteState?) -> Set<RemoteStateField> {
        guard let baseline else { return Set(RemoteStateField.allCases) }
        var fields: Set<RemoteStateField> = []
        if workflow != baseline.workflow || snoozedUntil != baseline.snoozedUntil { fields.insert(.workflow) }
        if removal != baseline.removal { fields.insert(.removal) }
        if unread != baseline.unread { fields.insert(.unread) }
        if pinned != baseline.pinned { fields.insert(.pinned) }
        if muted != baseline.muted { fields.insert(.muted) }
        return fields
    }
}

extension Conversation {
    var remoteState: RemoteState {
        RemoteState(workflow: workflow, snoozedUntil: snoozedUntil, removal: removal?.mailbox, unread: unread, pinned: pinned, muted: muted == true)
    }
    /// A change the server has not confirmed yet. Conversations the server never confirmed count as changed.
    var hasUnsyncedChanges: Bool { synced != remoteState }
    var remoteWriteFields: Set<RemoteStateField> {
        remoteState.changedFields(since: synced).union(pendingRemoteWrite ?? [])
    }

    mutating func adoptRemoteState(_ remote: RemoteConversation, keeping fields: Set<RemoteStateField>) {
        if !fields.contains(.workflow) {
            workflow = remote.workflow
            snoozedUntil = remote.snoozedUntil
            // The server knows only its own snooze wakes. A reminder that came due here, such as one for a send
            // confirmed after its date, keeps the local return time while it is overdue.
            returnedFromSnoozeAt = remote.returnedFromSnoozeAt ?? (followUp == .noReply ? returnedFromSnoozeAt : nil)
            // Only the reminder's own wake makes it overdue. Any other move ends it, as a manual move does.
            if followUp == .waiting, workflow != .snoozed {
                followUp = workflow == .inbox && remote.returnedFromSnoozeAt != nil ? .noReply : nil
            }
            // An overdue reminder ends when the thread leaves Inbox, also when another client moved it.
            if followUp == .noReply, workflow != .inbox {
                followUp = nil
                returnedFromSnoozeAt = nil
            }
        }
        if !fields.contains(.removal) {
            // Moving a thread to Trash or Junk ends its reminder, as it does in Mailern, also when another client did it.
            if removal == nil, remote.removal != nil, followUp != nil {
                endReminder()
                returnedFromSnoozeAt = nil
            }
            removal = switch remote.removal {
            case .trash: .trash(since: remote.trashSince ?? .now)
            case .junk: .junk
            case nil: nil
            }
        }
        if !fields.contains(.unread) { unread = remote.unread }
        if workflow == .settled { unread = false }
        if !fields.contains(.pinned) { pinned = remote.pinned }
        if !fields.contains(.muted) { muted = remote.muted ? true : nil }
        synced = remote.state
    }
}

struct RemovedMailboxIdentities: Codable, Hashable {
    var trash: String?
    var junk: String?

    subscript(_ mailbox: RemovedMailbox) -> String? {
        switch mailbox {
        case .trash: trash
        case .junk: junk
        }
    }
}

struct RemoteAccount: Decodable, Equatable {
    var id: String
    var name: String
    var address: String
    var aliases: [String]?
    var mailboxIdentities: RemovedMailboxIdentities?
}

struct RemoteMessage: Decodable, Equatable {
    var id: UUID
    var sender: String
    var address: String
    var to: [String]?
    var cc: [String]?
    var replyTo: [String]?
    var deliveredTo: [String]?
    var date: Date
    var body: String
    var outgoing: Bool
    var subject: String
    var hasHTML: Bool
    var messageID: String?
    var inReplyTo: String?
    var references: [String]?
    /// Another client marked the message deleted. It is on its way out and does not count as a reply.
    var deleted: Bool?
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

struct PreparedRemoteSend: Codable, Equatable {
    struct Reply: Codable, Equatable {
        let id: UUID
        let threadingID: String
        let references: [String]
    }

    let draft: ComposerDraft
    let conversationID: UUID
    let from: MailAccount
    let replyTo: Reply?
    /// The thread's incoming messages when the send started. A reply that arrives during the send is not among them.
    var incomingIDs: [UUID]?
}

struct PendingRemoteSend: Codable, Equatable {
    let prepared: PreparedRemoteSend
    var accepted = false
}

struct RemoteSendUnavailable: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// The server cannot confirm an earlier attempt and will not send this message again. Only the recipient can say
/// whether it arrived.
struct RemoteSendUnconfirmable: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct RemoteSendRejection: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum DraftDelivery {
    case filed, refused, waitingToFile
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
    /// A pull takes new messages and keeps only the state fields with local edits.
    @discardableResult func mergeRemote(_ sync: RemoteSync, resolvingDeletes: Set<UUID> = []) -> Bool {
        guard !needsReload else { return false }
        var accounts = sync.accounts.enumerated().map { index, remote in
            var account = self.accounts.first { $0.id == remote.id }
                ?? MailAccount(id: remote.id, name: remote.name, address: remote.address,
                               color: AccountColor.allCases[index % AccountColor.allCases.count])
            account.address = remote.address
            account.aliases = remote.aliases?.isEmpty == false ? remote.aliases : nil
            account.mailboxIdentities = remote.mailboxIdentities
            return account
        }
        if accounts.isEmpty { accounts = self.accounts }
        if !sync.reset && sync.conversations.isEmpty && sync.deleted.isEmpty {
            return replaceRemote(conversations: conversations, accounts: accounts, invalidatingUndo: [], revision: sync.revision)
        }
        let pending = pendingRemoteDeletes.filter { !resolvingDeletes.contains($0.key) }
        var updated = sync.reset ? [] : conversations
        let originalCount = updated.count
        let localByID = Dictionary(uniqueKeysWithValues: conversations.map { ($0.id, $0) })
        var positions = Dictionary(uniqueKeysWithValues: updated.enumerated().map { ($0.element.id, $0.offset) })
        let deleted = Set(sync.deleted)
        var invalidated = deleted
        for remote in sync.conversations where pending[remote.id] == nil {
            let recovering = resolvingDeletes.contains(remote.id)
            let local = localByID[remote.id] ?? (recovering ? pendingRemoteDeletes[remote.id]?.cached : nil)
            var merged = merge(remote, into: local, keeping: recovering ? [] : local?.remoteWriteFields ?? [])
            if recovering { merged.pendingRemoteWrite = nil }
            if local == nil, !recovering,
               let sender = merged.messages.last(where: { !$0.outgoing })?.address, isSenderBlocked(sender) {
                merged.removal = .junk
            }
            if let local, merged.messages.map(\.id) != local.messages.map(\.id) { invalidated.insert(remote.id) }
            if let index = positions[remote.id] {
                updated[index] = merged
            } else {
                positions[remote.id] = updated.count
                updated.append(merged)
            }
        }
        // Move the appended rows to the front after all updates have used the original indices.
        updated = updated.dropFirst(originalCount).reversed() + updated.prefix(originalCount)
        updated.removeAll { deleted.contains($0.id) || pending[$0.id] != nil }
        if sync.reset { invalidated.formUnion(localByID.keys.filter { positions[$0] == nil }) }
        return replaceRemote(conversations: updated, accounts: accounts, invalidatingUndo: invalidated,
                             revision: sync.revision, pendingDeletes: pending)
    }

    func acknowledgeRemoteState(_ remote: RemoteConversation, sent: RemoteState, fields: Set<RemoteStateField>) -> Bool {
        guard let index = conversations.firstIndex(where: { $0.id == remote.id }) else {
            return acknowledgePlacementBeforeDelete(remote, sent: sent, fields: fields)
        }
        var updated = conversations
        let editedAfterSend = updated[index].remoteState.changedFields(since: sent)
        updated[index].adoptRemoteState(remote, keeping: editedAfterSend)
        updated[index].pendingRemoteWrite = nil
        return replaceRemote(conversations: updated, accounts: accounts, invalidatingUndo: [])
    }

    private func merge(_ remote: RemoteConversation, into local: Conversation?, keeping fields: Set<RemoteStateField>) -> Conversation {
        var c = local ?? Conversation(id: remote.id, accountID: remote.accountID, subject: remote.subject, messages: [])
        let known = Set(local?.messages.map(\.id) ?? [])
        c.accountID = remote.accountID
        c.subject = remote.subject
        c.messages = remote.messages.map { message in
            var m = MailMessage(id: message.id, sender: message.sender, address: message.address, to: message.to ?? [],
                                cc: message.cc ?? [], date: message.date, body: message.body, outgoing: message.outgoing,
                                subject: message.subject, messageID: message.messageID, inReplyTo: message.inReplyTo,
                                references: message.references)
            if let old = local?.messages.first(where: { $0.id == message.id }) {
                m.html = old.html
                m.richText = old.richText
                m.attachments = old.attachments
                m.bcc = old.bcc
            }
            // Mail sent from this phone keeps its own rich text, with the composer's foldable quote.
            m.remoteHTML = message.hasHTML && m.html == nil && m.richText == nil ? true : nil
            m.replyTo = message.replyTo?.isEmpty == false ? message.replyTo : nil
            m.deliveredTo = message.deliveredTo?.isEmpty == false ? message.deliveredTo : nil
            return m
        }
        if c.messages.isEmpty, let local { c.messages = local.messages }
        let replies = local == nil ? [] : remote.messages.filter { !$0.outgoing && $0.deleted != true && !known.contains($0.id) }
        let replied = !replies.isEmpty
        // The reminder this sync may end, judged before the server's wake can turn it into No Reply.
        let deadline = c.followUp == .waiting ? c.snoozedUntil : c.followUp == .noReply ? c.returnedFromSnoozeAt : nil
        // A new reply wins over a move the server has not confirmed, as an arrival does in Mailern: it returns the
        // thread to Inbox, rescues it from Trash, and ends its reminder.
        var keeping = fields
        // An unconfirmed mute counts, as it does on the server.
        let muted = fields.contains(.muted) ? c.muted == true : remote.muted
        if replied && !muted {
            keeping.subtract([.workflow, .unread])
            if c.removal?.mailbox == .trash { keeping.remove(.removal) }
        }
        c.adoptRemoteState(remote, keeping: keeping)
        // A reply that answers a reminder on a muted thread settles it quietly, as in Mailern, even when this sync
        // also brings the reminder's wake. A reply after the deadline only clears the No Reply mark.
        if replied && muted, let deadline, replies.contains(where: { $0.date <= deadline }) {
            c.move(to: .settled)
            c.followUp = nil
        } else if replied && muted {
            c.endReminder()
        } else if replied {
            c.followUp = nil
        }
        return c
    }
}

@MainActor
protocol RemoteMailboxClient {
    func sync(since revision: UInt64, wait: Int) async throws -> RemoteSync
    func setState(_ id: UUID, _ state: RemoteState, fields: Set<RemoteStateField>, messageIDs: [UUID]) async throws -> RemoteConversation?
    func delete(_ id: UUID, _ request: RemoteDelete) async throws -> Bool
}

@MainActor @Observable
final class ServerSync {
    @ObservationIgnored private let client: any RemoteMailboxClient
    @ObservationIgnored private let store: MailStore
    private(set) var problem: String?
    private(set) var lastSync: Date?
    @ObservationIgnored private var pushTask: Task<Void, Never>?
    @ObservationIgnored private var pushRequested = false
    @ObservationIgnored private var pushGeneration: UInt64 = 0
    @ObservationIgnored private var needsFullSync = false
    @ObservationIgnored private var deleteConflicts: Set<UUID> = []

    init(client: any RemoteMailboxClient, store: MailStore) {
        self.client = client
        self.store = store
    }

    func run() async {
        var wait = 0
        store.fileReadyRemoteSends()
        await push()
        while !Task.isCancelled {
            do {
                let applied = try await pull(wait: wait)
                wait = applied ? 25 : 0
                if applied { await push() }
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

    @discardableResult func pull(wait: Int) async throws -> Bool {
        await pushTask?.value
        try Task.checkCancellation()
        let generation = pushGeneration
        let sendGeneration = store.remoteSendGeneration
        let resolving = conflictedDeletes
        let changes = try await client.sync(since: needsFullSync || !resolving.isEmpty ? 0 : store.remoteRevision, wait: wait)
        await pushTask?.value
        try Task.checkCancellation()
        // A long poll can return a snapshot taken before a concurrent write was acknowledged.
        guard generation == pushGeneration, sendGeneration == store.remoteSendGeneration else { return false }
        try applyPull(changes, resolvingDeletes: resolving)
        needsFullSync = false
        problem = nil
        lastSync = .now
        return true
    }

    func push() async {
        if let pushTask {
            pushRequested = true
            await pushTask.value
            return
        }
        guard !store.needsReload,
              !store.pendingRemoteDeletes.isEmpty || store.conversations.contains(where: { !$0.remoteWriteFields.isEmpty }) else { return }
        pushGeneration &+= 1
        let task = Task {
            repeat {
                pushRequested = false
                await pushChanges()
            } while pushRequested && !Task.isCancelled
        }
        pushTask = task
        await task.value
        pushTask = nil
    }

    private func pushChanges() async {
        for (id, pending) in store.pendingRemoteDeletes where !pending.needsRefresh && !deleteConflicts.contains(id) {
            do {
                if try await client.delete(id, pending.request) {
                    guard store.confirmRemoteDelete(id) else { throw saveFailure }
                } else {
                    deleteConflicts.insert(id)
                    guard store.markRemoteDeleteConflict(id) else { throw saveFailure }
                    deleteConflicts.remove(id)
                }
            } catch {
                problem = error.localizedDescription
            }
        }
        let resolving = conflictedDeletes
        if !resolving.isEmpty {
            do {
                let sendGeneration = store.remoteSendGeneration
                let changes = try await client.sync(since: 0, wait: 0)
                if sendGeneration == store.remoteSendGeneration {
                    try applyPull(changes, resolvingDeletes: resolving)
                    lastSync = .now
                }
            } catch {
                problem = error.localizedDescription
            }
        }
        let ids = store.conversations.filter { !$0.remoteWriteFields.isEmpty }.map(\.id)
        for id in ids {
            while let conversation = store.conversation(id), !conversation.remoteWriteFields.isEmpty {
                let state = conversation.remoteState
                let fields = conversation.remoteWriteFields
                let messageIDs = conversation.messages.map(\.id)
                do {
                    guard store.recordPendingRemoteWrite(id, fields: fields) else { throw saveFailure }
                    guard let confirmed = try await client.setState(id, state, fields: fields, messageIDs: messageIDs) else {
                        needsFullSync = true
                        break
                    }
                    guard store.acknowledgeRemoteState(confirmed, sent: state, fields: fields) else { throw saveFailure }
                } catch {
                    problem = error.localizedDescription
                    break
                }
            }
            if store.pendingRemoteDeletes[id] != nil { pushRequested = true }
        }
    }

    private func applyPull(_ changes: RemoteSync, resolvingDeletes: Set<UUID>) throws {
        guard store.mergeRemote(changes, resolvingDeletes: resolvingDeletes) else { throw saveFailure }
        store.fileReadyRemoteSends()
        if !resolvingDeletes.isEmpty {
            deleteConflicts.subtract(resolvingDeletes)
            store.error = "Mail changed before deletion. Review it before deleting again."
        }
    }

    private var conflictedDeletes: Set<UUID> {
        Set(store.pendingRemoteDeletes.compactMap { id, pending in
            pending.needsRefresh || deleteConflicts.contains(id) ? id : nil
        })
    }

    private var saveFailure: CocoaError {
        CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: store.error ?? "Server changes could not be saved."])
    }
}
