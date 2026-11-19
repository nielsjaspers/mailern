import Foundation

enum MailboxItem: Identifiable {
    case thread(Conversation, [ComposerDraft])
    case draft(ComposerDraft)

    var conversation: Conversation? {
        if case .thread(let conversation, _) = self { return conversation }
        return nil
    }
    var drafts: [ComposerDraft] {
        switch self { case .thread(_, let drafts): drafts; case .draft(let draft): [draft] }
    }
    var id: UUID {
        switch self { case .thread(let c, _): c.id; case .draft(let draft): draft.id }
    }
    var hasDraft: Bool { !drafts.isEmpty }
    var unread: Bool { conversation?.unread ?? false }
    var pinned: Bool { conversation?.pinned ?? (drafts.first?.pinned == true) }
    var snoozedUntil: Date? { conversation?.snoozedUntil ?? drafts.first?.snoozedUntil }
    var workflow: Workflow { conversation?.workflow ?? (snoozedUntil == nil ? .inbox : .snoozed) }
    var accountID: String { conversation?.accountID ?? drafts[0].accountID }
    var date: Date { max(conversation?.latest.date ?? .distantPast, drafts.map(\.updatedAt).max() ?? .distantPast) }

    /// The items of one workflow section. A nil `status` lists all mail in Inbox, Snoozed, and Settled, grouped in
    /// that order as the list shows it, newest first within each. Mailbox filters belong to one section, so all mail ignores `filter`.
    static func list(conversations: [Conversation], drafts: [ComposerDraft], status: Workflow?,
                     search: MailSearch = MailSearch(), filter: MailboxFilter = MailboxFilter()) -> [Self] {
        let conversationIDs = Set(conversations.map(\.id))
        let replies = Dictionary(grouping: drafts.filter { draft in
            draft.mode.replyID.map { conversationIDs.contains($0) } ?? false
        }, by: { $0.mode.replyID! })
        // Junk and Trash have their own lists. Their reply drafts stay hidden with them.
        let items = conversations.filter { $0.removal == nil }.map { Self.thread($0, (replies[$0.id] ?? []).sorted { $0.updatedAt > $1.updatedAt }) }
            + drafts.filter { draft in
                draft.mode.replyID.map { !conversationIDs.contains($0) } ?? true
            }.map { Self.draft($0) }
        return items.filter { item in
            if let status, item.workflow != status || !filter.includes(item, in: status) { return false }
            return item.conversation.map(search.matches) == true || item.drafts.contains(where: search.matches)
        }.sorted {
            if status == nil && $0.workflow != $1.workflow {
                return Workflow.allCases.firstIndex(of: $0.workflow)! < Workflow.allCases.firstIndex(of: $1.workflow)!
            }
            if status == .inbox && $0.pinned != $1.pinned { return $0.pinned }
            if status == .snoozed && $0.snoozedUntil != $1.snoozedUntil {
                return ($0.snoozedUntil ?? .distantFuture) < ($1.snoozedUntil ?? .distantFuture)
            }
            if $0.date != $1.date { return $0.date > $1.date }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
}

/// A list snapshot keeps its order even when opening a thread marks it read.
struct ReaderList {
    let order: [UUID]
    let query: String
    let scope: Workflow?
    let filter: MailboxFilter

    func neighbors(of id: UUID, available: Set<UUID>) -> (previous: UUID?, next: UUID?) {
        guard let index = order.firstIndex(of: id) else { return (nil, nil) }
        return (order[..<index].last(where: available.contains),
                order[(index + 1)...].first(where: available.contains))
    }
}

struct MessageMatch: Equatable {
    let messageID: UUID
    let field: String
    let range: Range<String.Index>
    let inBody: Bool
    var before: String {
        let left = field.index(range.lowerBound, offsetBy: -28, limitedBy: field.startIndex) ?? field.startIndex
        return (left == field.startIndex ? "" : "…") + field[left..<range.lowerBound]
    }
    var text: String { String(field[range]) }
    var after: String {
        let right = field.index(range.upperBound, offsetBy: 50, limitedBy: field.endIndex) ?? field.endIndex
        return field[range.upperBound..<right] + (right == field.endIndex ? "" : "…")
    }
    var snippet: String { (String(before.suffix(12)) + text + after).split(whereSeparator: \.isWhitespace).joined(separator: " ") }
}

extension Conversation {
    func messageMatches(_ query: String, firstOnly: Bool = false) -> [MessageMatch] {
        guard !query.isEmpty else { return [] }
        let term = query.folding(options: .caseInsensitive, locale: nil).precomposedStringWithCanonicalMapping
        guard !term.isEmpty else { return [] }
        let localized = term.unicodeScalars.count < 3
        var matches: [MessageMatch] = []
        for (index, message) in messages.enumerated() {
            if Task.isCancelled { return [] }
            var fields = [message.body, message.sender, message.address]
            if index == 0 { fields.append(subject) }
            if let changed = message.subject, changed != subject { fields.append(changed) }
            for (fieldIndex, field) in fields.enumerated() {
                // FTS indexes folded text. A single character such as ß can span two indexed letters.
                if localized && !field.localizedCaseInsensitiveContains(query) { continue }
                let searchOriginal = localized || field.utf8.allSatisfy { $0 < 128 }
                let folded = searchOriginal ? field : field.folding(options: .caseInsensitive, locale: nil).precomposedStringWithCanonicalMapping
                var positions: [String.Index] = []
                var previousRange: Range<String.Index>?
                var start = folded.startIndex
                while start < folded.endIndex,
                      let hit = folded.range(of: localized ? query : term, options: searchOriginal ? [.caseInsensitive] : [.literal],
                                             range: start..<folded.endIndex, locale: localized ? .current : nil) {
                    if Task.isCancelled { return [] }
                    let range: Range<String.Index>
                    if searchOriginal { range = hit }
                    else {
                        if positions.isEmpty {
                            for i in field.indices {
                                if Task.isCancelled { return [] }
                                let length = String(field[i]).folding(options: .caseInsensitive, locale: nil)
                                    .precomposedStringWithCanonicalMapping.utf8.count
                                positions.append(contentsOf: repeatElement(i, count: length))
                            }
                        }
                        let lower = folded.utf8.distance(from: folded.startIndex, to: hit.lowerBound)
                        let upper = folded.utf8.distance(from: folded.startIndex, to: hit.upperBound)
                        guard upper > lower, upper <= positions.count else { break }
                        range = positions[lower]..<field.index(after: positions[upper - 1])
                    }
                    start = hit.upperBound
                    if range == previousRange { continue }
                    previousRange = range
                    matches.append(MessageMatch(messageID: message.id, field: field, range: range, inBody: fieldIndex == 0))
                    if firstOnly { return matches }
                }
            }
        }
        return matches
    }
}

extension ComposerDraft {
    var title: String { subject.isEmpty ? "New Message" : subject }
}

/// A tab keeps its latest projection while navigation, search presentation, and scroll geometry change.
@MainActor
final class MailboxProjections {
    struct Selection {
        var eligible = Set<UUID>()
        var unread = Set<UUID>()
        var unpinned = Set<UUID>()
    }

    final class Entry {
        let query: String
        let filter: MailboxFilter
        let items: [MailboxItem]
        let unread: Int
        let order: [UUID]

        init(query: String, filter: MailboxFilter, items: [MailboxItem]) {
            self.query = query
            self.filter = filter
            self.items = items
            unread = items.count(where: \.unread)
            order = items.map(\.id)
        }

        // Native multi-selection can change once per row during a drag.
        lazy var selection = items.reduce(into: Selection()) { result, item in
            guard let conversation = item.conversation else { return }
            result.eligible.insert(conversation.id)
            if conversation.unread { result.unread.insert(conversation.id) }
            if !conversation.pinned { result.unpinned.insert(conversation.id) }
        }
    }

    private var revision: UInt64?
    private var accounts: [MailAccount] = []
    private var drafts: [ComposerDraft] = []
    private var entries: [Workflow?: Entry] = [:]
    private var badge: (revision: UInt64, count: Int)?

    func list(store: MailStore, drafts: [ComposerDraft], status: Workflow?, query: String, filter: MailboxFilter) -> Entry {
        if revision != store.mailboxRevision || accounts != store.accounts || self.drafts != drafts {
            entries.removeAll(keepingCapacity: true)
            revision = store.mailboxRevision
            accounts = store.accounts
            self.drafts = drafts
        }
        if let current = entries[status], current.query == query, current.filter == filter { return current }
        let search = store.search(query)
        let items = MailboxItem.list(conversations: store.conversations, drafts: drafts, status: status,
                                     search: search, filter: filter)
        let entry = Entry(query: query, filter: filter, items: items)
        if search.canCache { entries[status] = entry }
        return entry
    }

    func endAllMailSearch() { entries.removeValue(forKey: nil) }

    func inboxUnread(store: MailStore) -> Int {
        if let badge, badge.revision == store.mailboxRevision { return badge.count }
        let count = store.conversations.count { $0.workflow == .inbox && $0.removal == nil && $0.unread }
        badge = (store.mailboxRevision, count)
        return count
    }
}
