import Foundation

enum Workflow: String, Codable, CaseIterable, Identifiable {
    case inbox, snoozed, settled
    var id: Self { self }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self { case .inbox: "tray"; case .snoozed: "clock"; case .settled: "checkmark.circle" }
    }
}

struct MailAccount: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var address: String
    static let demo = [
        Self(id: "university", name: "University", address: "morgan@student.example.com"),
        Self(id: "icloud", name: "Personal", address: "morgan@personal.example.com"),
        Self(id: "proton", name: "Private", address: "morgan@private.example.com"),
        Self(id: "gmail", name: "Gmail", address: "morgan@mail.example.com")
    ]
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
}

struct Conversation: Codable, Identifiable, Equatable {
    var id = UUID()
    var accountID: String
    var subject: String
    var workflow: Workflow = .inbox
    var unread = true
    var pinned = false
    var snoozedUntil: Date?
    var messages: [MailMessage]
    var latest: MailMessage { messages[messages.count - 1] }
    var correspondent: MailMessage { messages.last(where: { !$0.outgoing }) ?? latest }
    var account: MailAccount { MailAccount.demo.first(where: { $0.id == accountID }) ?? MailAccount.demo[0] }

    mutating func move(to status: Workflow, until: Date? = nil) {
        workflow = status
        snoozedUntil = status == .snoozed ? until : nil
    }
    mutating func receive(_ message: MailMessage) {
        messages.append(message)
        guard !message.outgoing else { return }
        move(to: .inbox)
        unread = true
    }
}
