import Foundation

/// Workflow state is local to Mailern. When providers arrive, Settle maps to archive: Gmail removes the INBOX label
/// and IMAP moves the message to the Archive folder. Snooze has no provider equivalent and stays on this device, so a
/// snoozed conversation remains in the provider's inbox.
enum Workflow: String, Codable, CaseIterable, Identifiable {
    case inbox, snoozed, settled
    var id: Self { self }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self { case .inbox: "tray"; case .snoozed: "clock"; case .settled: "checkmark.circle" }
    }
}

/// Mailboxes outside the workflow tabs. Mail in them keeps its workflow, so restoring returns it to where it was.
enum RemovedMailbox: String, Codable, CaseIterable, Identifiable, Hashable {
    case junk, trash
    var id: Self { self }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self { case .junk: "xmark.bin"; case .trash: "trash" }
    }
}

enum Removal: Codable, Equatable {
    case trash(since: Date), junk
    var mailbox: RemovedMailbox {
        switch self { case .trash: .trash; case .junk: .junk }
    }
}

/// A reminder on sent mail. The conversation waits in Snoozed and returns marked when nobody replied in time.
enum FollowUp: String, Codable {
    case waiting, noReply
}

/// Colors a person can give an account. Each one stays readable as a small dot in light and dark mode.
enum AccountColor: String, Codable, CaseIterable, Identifiable {
    case blue, teal, green, yellow, orange, red, pink, purple, indigo, brown, gray
    var id: Self { self }
    var title: String { rawValue.capitalized }
}

struct MailAccount: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var address: String
    var color: AccountColor
    var signature = ""
    var mailboxIdentities: RemovedMailboxIdentities?
    /// Seed data for a new or reset store. The first account is the default sender for new mail.
    static let demo = [
        Self(id: "icloud", name: "Personal", address: "morgan@personal.example.com", color: .blue, signature: "Morgan"),
        Self(id: "university", name: "University", address: "morgan@student.example.com", color: .purple,
             signature: "Morgan\nStudent, Example College"),
        Self(id: "proton", name: "Private", address: "morgan@private.example.com", color: .green),
        Self(id: "gmail", name: "Gmail", address: "morgan@mail.example.com", color: .orange, signature: "Morgan")
    ]
    /// Stands in for an account that was removed while something still refers to it.
    static func removed(_ id: String) -> Self { Self(id: id, name: "Removed account", address: "", color: .gray) }
}

struct MailMessage: Codable, Identifiable, Equatable {
    var id = UUID()
    var sender: String
    var address: String
    var to: [String]
    var cc: [String] = []
    var date: Date
    var body: String
    var outgoing = false
    var bcc: [String]?
    var richText: Data?
    var attachments: [MailAttachment]?
    var subject: String?
    /// The HTML part of the message. `body` holds its plain-text alternative for snippets, search, and quotes.
    var html: String?
    /// The RFC 5322 Message-ID header, with angle brackets. Mail from a provider can lack one.
    var messageID: String?
    /// The Message-ID this message answers.
    var inReplyTo: String?
    /// The Message-IDs of the thread before this message, oldest first.
    var references: [String]?
    /// The provider's own ID for this message. Nil for demo mail.
    var remoteID: String?
    /// The mail server holds an HTML part the phone has not loaded yet. The reader loads it on open.
    var remoteHTML: Bool?

    /// The ID other messages use to refer to this one. Messages without a Message-ID get a stable local stand-in.
    var threadingID: String { messageID ?? "<\(id.uuidString)@mailern.local>" }
    /// A Message-ID in the domain of the sending address. Sent mail uses its draft's ID, so the mail server can find
    /// a copy that already went out instead of sending it twice.
    static func newMessageID(from address: String, id: UUID = UUID()) -> String {
        let domain = address.split(separator: "@").last.map(String.init) ?? "mailern.local"
        return "<\(id.uuidString.lowercased())@\(domain)>"
    }
    /// Sets the headers of a reply to `message`.
    mutating func answer(_ message: MailMessage) {
        inReplyTo = message.threadingID
        references = (message.references ?? []) + [message.threadingID]
    }
}

struct Conversation: Codable, Identifiable, Equatable {
    var id = UUID()
    var accountID: String
    var subject: String
    var workflow: Workflow = .inbox
    var unread = true
    var pinned = false
    var snoozedUntil: Date?
    /// Retains the identity of a delivered reminder until a new message or manual move supersedes it.
    var returnedFromSnoozeAt: Date?
    var removal: Removal?
    /// Replies to a muted conversation join it without moving it or marking it unread.
    var muted: Bool?
    var followUp: FollowUp?
    /// Connects a group of blocked replies in Junk to the conversation they answered.
    var blockedReplySourceID: UUID?
    /// The state the mail server last confirmed. Nil for demo mail and for changes the server has not seen.
    var synced: RemoteState?
    /// The fields of a PUT that may have reached the server without a saved acknowledgment.
    var pendingRemoteWrite: Set<RemoteStateField>?
    var messages: [MailMessage]
    var latest: MailMessage { messages[messages.count - 1] }
    var effectiveSubject: String { subject(at: latest) }
    /// The subject in effect when `message` was written. A reply can rename a thread part-way.
    func subject(at message: MailMessage) -> String {
        let index = messages.firstIndex { $0.id == message.id } ?? messages.count - 1
        return messages[...index].last(where: { $0.subject != nil })?.subject ?? subject
    }
    var correspondent: MailMessage { messages.last(where: { !$0.outgoing }) ?? latest }
    /// Everyone who wrote in the thread, in order of first appearance. Sent-only threads show their recipients.
    var participants: String {
        guard messages.contains(where: { !$0.outgoing }) else { return "To: \(latest.to.joined(separator: ", "))" }
        // The address identifies a sender. Two people can share a display name.
        var seen = Set<String>()
        return messages.filter { seen.insert($0.outgoing ? "" : $0.address.lowercased()).inserted }
            .map { $0.outgoing ? "Me" : $0.sender }.joined(separator: ", ")
    }
    var avatarName: String {
        messages.contains(where: { !$0.outgoing }) ? correspondent.sender : latest.to.first ?? latest.sender
    }
    /// The message a reply or forward targets. Falls back to the latest message.
    func message(_ id: UUID?) -> MailMessage { messages.first { $0.id == id } ?? latest }

    /// Moving a conversation by hand ends its reminder. Callers that start one set it after the move.
    mutating func move(to status: Workflow, until: Date? = nil) {
        followUp = nil
        returnedFromSnoozeAt = nil
        if status == .settled { unread = false }
        workflow = status
        snoozedUntil = status == .snoozed ? until : nil
    }
    /// Ends a reminder without the move that usually ends it. A waiting thread sat in Snoozed only for its
    /// reminder, so it settles instead of returning to Inbox later.
    mutating func endReminder() {
        if followUp == .waiting { move(to: .settled) }
        followUp = nil
    }
    mutating func receive(_ message: MailMessage) {
        messages.append(message)
        guard !message.outgoing else { return }
        guard muted != true else { endReminder(); return }
        move(to: .inbox)
        unread = true
        // A reply rescues a thread from Trash. A conversation in Junk must be restored by hand.
        if removal?.mailbox == .trash { removal = nil }
    }
}
