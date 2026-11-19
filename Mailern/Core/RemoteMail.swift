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

struct PreparedRemoteSend {
    let draft: ComposerDraft
    let conversationID: UUID
    let from: MailAccount
    let replyTo: MailMessage?
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
    /// Applies a sync from the mail server. Conversations with unsynced local changes keep their workflow state until
    /// the server confirms it, but always take new messages. Local-only state stays: reminders, blocked replies,
    /// and the HTML, rich text, and attachments the phone already holds.
    @discardableResult func mergeRemote(_ sync: RemoteSync, preservingLocalState ids: Set<UUID> = []) -> Bool {
        guard !needsReload else { return false }
        var accounts = sync.accounts.enumerated().map { index, remote in
            var account = self.accounts.first { $0.id == remote.id }
                ?? MailAccount(id: remote.id, name: remote.name, address: remote.address,
                               color: AccountColor.allCases[index % AccountColor.allCases.count])
            account.address = remote.address
            return account
        }
        if accounts.isEmpty { accounts = self.accounts }
        if !sync.reset && sync.conversations.isEmpty && sync.deleted.isEmpty {
            return replaceRemote(conversations: conversations, accounts: accounts, invalidatingUndo: [], revision: sync.revision)
        }
        var updated = sync.reset ? [] : conversations
        let originalCount = updated.count
        let localByID = Dictionary(uniqueKeysWithValues: conversations.map { ($0.id, $0) })
        var positions = Dictionary(uniqueKeysWithValues: updated.enumerated().map { ($0.element.id, $0.offset) })
        let deleted = Set(sync.deleted)
        var invalidated = deleted
        for remote in sync.conversations where pendingRemoteDeletes[remote.id] == nil {
            let local = localByID[remote.id]
            let merged = merge(remote, into: local, keepLocalState: local.map { ids.contains(remote.id) || $0.hasUnsyncedChanges } ?? false)
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
        updated.removeAll { deleted.contains($0.id) || pendingRemoteDeletes[$0.id] != nil }
        if sync.reset { invalidated.formUnion(localByID.keys.filter { positions[$0] == nil }) }
        return replaceRemote(conversations: updated, accounts: accounts, invalidatingUndo: invalidated, revision: sync.revision)
    }

    func acknowledgeRemoteState(_ remote: RemoteConversation) -> Bool {
        // A delete can commit while the state request is in flight.
        guard let index = conversations.firstIndex(where: { $0.id == remote.id }) else { return true }
        var updated = conversations
        // The PUT confirms the new baseline. Undo or sending a reply can change the local copy while it is in flight.
        updated[index].synced = remote.state
        return replaceRemote(conversations: updated, accounts: accounts, invalidatingUndo: [])
    }

    private func merge(_ remote: RemoteConversation, into local: Conversation?, keepLocalState: Bool) -> Conversation {
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
        if !keepLocalState {
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

@MainActor
protocol RemoteMailboxClient {
    func sync(since revision: UInt64, wait: Int) async throws -> RemoteSync
    func setState(_ id: UUID, _ state: RemoteState) async throws -> RemoteConversation?
    func delete(_ id: UUID) async throws
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
    @ObservationIgnored private var unconfirmedStateWrites: Set<UUID> = []

    init(client: any RemoteMailboxClient, store: MailStore) {
        self.client = client
        self.store = store
    }

    func run() async {
        var wait = 0
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
        let changes = try await client.sync(since: needsFullSync ? 0 : store.remoteRevision, wait: wait)
        await pushTask?.value
        try Task.checkCancellation()
        // A long poll can return a snapshot taken before a concurrent write was acknowledged.
        guard generation == pushGeneration, sendGeneration == store.remoteSendGeneration else { return false }
        guard store.mergeRemote(changes, preservingLocalState: unconfirmedStateWrites) else { throw saveFailure }
        unconfirmedStateWrites.formIntersection(store.conversations.map(\.id))
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
              !store.pendingRemoteDeletes.isEmpty || store.conversations.contains(where: needsStateWrite) else { return }
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
        for (id, state) in store.pendingRemoteDeletes {
            do {
                // Trash or Junk may have been changed locally just before the permanent delete.
                if try await client.setState(id, state) != nil { try await client.delete(id) }
                guard store.confirmRemoteDelete(id) else { throw saveFailure }
                unconfirmedStateWrites.remove(id)
            } catch {
                problem = error.localizedDescription
            }
        }
        let ids = store.conversations.filter(needsStateWrite).map(\.id)
        for id in ids {
            while let conversation = store.conversation(id), needsStateWrite(conversation) {
                let state = conversation.remoteState
                unconfirmedStateWrites.insert(id)
                do {
                    guard let confirmed = try await client.setState(id, state) else {
                        unconfirmedStateWrites.remove(id)
                        needsFullSync = true
                        break
                    }
                    guard store.acknowledgeRemoteState(confirmed) else { throw saveFailure }
                    unconfirmedStateWrites.remove(id)
                } catch {
                    problem = error.localizedDescription
                    break
                }
            }
        }
    }

    private func needsStateWrite(_ conversation: Conversation) -> Bool {
        conversation.hasUnsyncedChanges || unconfirmedStateWrites.contains(conversation.id)
    }

    private var saveFailure: CocoaError {
        CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: store.error ?? "Server changes could not be saved."])
    }
}
