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
    var pinned: Bool { conversation?.pinned ?? false }
    var workflow: Workflow { hasDraft ? .inbox : conversation?.workflow ?? .inbox }
    var date: Date { max(conversation?.latest.date ?? .distantPast, drafts.map(\.updatedAt).max() ?? .distantPast) }

    static func list(conversations: [Conversation], drafts: [ComposerDraft], status: Workflow,
                     search: String = "", unreadFirst: Bool = false) -> [Self] {
        let conversationIDs = Set(conversations.map(\.id))
        let replies = Dictionary(grouping: drafts.filter { draft in
            draft.mode.replyID.map { conversationIDs.contains($0) } ?? false
        }, by: { $0.mode.replyID! })
        let items = conversations.map { Self.thread($0, (replies[$0.id] ?? []).sorted { $0.updatedAt > $1.updatedAt }) }
            + drafts.filter { draft in
                draft.mode.replyID.map { !conversationIDs.contains($0) } ?? true
            }.map { Self.draft($0) }
        return items.filter { item in
            guard item.workflow == status else { return false }
            var fields = item.drafts.flatMap { [$0.subject, $0.to, $0.cc, $0.bcc, $0.text, $0.account.name] }
            if let c = item.conversation {
                fields += [c.subject, c.account.name] + c.messages.flatMap { [$0.sender, $0.address, $0.body, $0.subject ?? ""] }
            }
            return search.isEmpty || fields.contains { $0.localizedCaseInsensitiveContains(search) }
        }.sorted {
            if status == .inbox && $0.pinned != $1.pinned { return $0.pinned }
            if status == .inbox && unreadFirst && $0.unread != $1.unread { return $0.unread }
            if status == .snoozed { return ($0.conversation?.snoozedUntil ?? .distantFuture) < ($1.conversation?.snoozedUntil ?? .distantFuture) }
            if $0.date != $1.date { return $0.date > $1.date }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
}

extension ComposerDraft {
    var title: String { subject.isEmpty ? "New Message" : subject }
    var account: MailAccount { MailAccount.demo.first { $0.id == accountID } ?? MailAccount.demo[1] }
}
