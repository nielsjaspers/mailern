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

    /// The items of one workflow section. A nil `status` lists all mail in Inbox, Snoozed, and Settled, newest
    /// first. Mailbox filters belong to one section, so all mail ignores `filter`.
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
            if status == .inbox && $0.pinned != $1.pinned { return $0.pinned }
            if status == .snoozed && $0.snoozedUntil != $1.snoozedUntil {
                return ($0.snoozedUntil ?? .distantFuture) < ($1.snoozedUntil ?? .distantFuture)
            }
            if $0.date != $1.date { return $0.date > $1.date }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    /// The conversation to open after `id` leaves `items`: the one below it, or the one above when it was last.
    /// Standalone drafts are skipped, because they cannot be settled with a conversation's Settle.
    static func conversation(after id: UUID, in items: [Self]) -> UUID? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        let below = items[(index + 1)...].first { $0.conversation != nil }
        let above = items[..<index].last { $0.conversation != nil }
        return (below ?? above)?.id
    }
}

extension ComposerDraft {
    var title: String { subject.isEmpty ? "New Message" : subject }
}
