import Foundation

enum MailReadFilter: String, Codable, CaseIterable, Identifiable {
    case all, unread, read
    var id: Self { self }
    var title: String { rawValue.capitalized }
}

struct MailboxFilter: Codable, Equatable {
    var enabled = false
    var accountIDs: Set<String>?
    var readStatus: MailReadFilter = .all
    var onlyDrafts = false
    var onlySent = false

    static func initial(for status: Workflow) -> Self {
        status == .settled ? Self(onlySent: true) : Self(readStatus: .unread)
    }

    func includes(_ item: MailboxItem, in status: Workflow) -> Bool {
        guard enabled else { return true }
        if let accountIDs, !accountIDs.contains(item.accountID) { return false }
        if status != .settled {
            if readStatus == .unread && !item.unread { return false }
            if readStatus == .read && (item.conversation == nil || item.unread) { return false }
            if onlyDrafts && !item.hasDraft { return false }
        } else if onlySent && !(item.conversation?.messages.contains { $0.outgoing } ?? false) {
            return false
        }
        return true
    }

    func summary(for status: Workflow) -> String {
        var parts: [String] = []
        if status != .settled {
            if readStatus != .all { parts.append(readStatus.title) }
            if onlyDrafts { parts.append("Drafts") }
        } else if onlySent { parts.append("Sent") }
        if let accountIDs {
            let accounts = MailAccount.demo.filter { accountIDs.contains($0.id) }
            parts.append(accounts.count == 1 ? accounts[0].name : "\(accounts.count) accounts")
        }
        return parts.isEmpty ? "All mail" : parts.joined(separator: ", ")
    }
}

struct MailboxFilters: Codable, Equatable {
    var inbox = MailboxFilter.initial(for: .inbox)
    var snoozed = MailboxFilter.initial(for: .snoozed)
    var settled = MailboxFilter.initial(for: .settled)

    subscript(status: Workflow) -> MailboxFilter {
        get {
            switch status { case .inbox: inbox; case .snoozed: snoozed; case .settled: settled }
        }
        set {
            switch status { case .inbox: inbox = newValue; case .snoozed: snoozed = newValue; case .settled: settled = newValue }
        }
    }
}
