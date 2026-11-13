import Foundation

@main struct WorkflowChecks {
    @MainActor static func main() throws {
        try checkInboxOrder()
        let directory = URL.temporaryDirectory.appending(path: "mailern-check-\(UUID())")
        let disk = JSONPersistence(url: directory.appending(path: "demo.json"))
        let store = MailStore(persistence: disk)
        let c = store.list(.inbox)[0]
        let id = c.id
        store.markRead(id)
        assert(store.conversation(id)!.workflow == .inbox && !store.conversation(id)!.unread)
        store.togglePin(id)
        let pin = store.conversation(id)!.pinned
        store.move(id, to: .settled)
        assert(store.list(.settled).contains { $0.id == id })
        store.undo()
        assert(store.conversation(id)!.workflow == .inbox)
        store.markRead(id, unread: true)
        store.move(id, to: .settled)
        assert(store.conversation(id)!.unread)
        store.receiveReply(id)
        assert(store.conversation(id)!.workflow == .inbox && store.conversation(id)!.unread)
        assert(store.conversation(id)!.pinned == pin)
        store.undo()
        assert(store.conversation(id)!.workflow == .inbox)
        store.move(id, to: .snoozed, until: .now.addingTimeInterval(100))
        store.receiveReply(id)
        assert(store.conversation(id)!.workflow == .inbox && store.conversation(id)!.snoozedUntil == nil)
        store.markRead(id)
        store.move(id, to: .snoozed, until: .now.addingTimeInterval(100))
        store.wakeDue(now: .now.addingTimeInterval(101))
        assert(store.conversation(id)!.workflow == .inbox && !store.conversation(id)!.unread)
        store.move(id, to: .snoozed, until: .now.addingTimeInterval(100))
        let reloaded = MailStore(persistence: disk)
        reloaded.wakeDue(now: .now.addingTimeInterval(101))
        assert(reloaded.conversation(id)!.workflow == .inbox)
        let beforeSend = store.conversation(id)!.messages.count
        store.send(threadID: id, account: c.account, to: [c.correspondent.address], cc: [], subject: c.subject, body: "Thanks, here's the plan.")
        assert(store.conversation(id)!.workflow == .settled && store.conversation(id)!.messages.count == beforeSend + 1)
        assert(store.conversation(id)!.latest.outgoing)
        store.move(id, to: .inbox)
        assert(store.conversation(id)!.workflow == .inbox)
        store.send(threadID: nil, account: c.account, to: ["test@example.com"], cc: [], subject: "New outgoing", body: "Hello")
        assert(store.list(.settled).contains { $0.subject == "New outgoing" && !$0.unread })
        store.receiveNew()
        assert(store.list(.inbox).contains { $0.subject == "Coffee this week?" && $0.unread })
        let saved = MailStore(persistence: disk)
        assert(saved.conversations == store.conversations)
        assert(saved.list(.settled, search: "New outgoing").count == 1)
        store.reset()
        assert(store.conversations.count == 9)
        assert(store.list(.inbox)[0].pinned)
        assert(store.error == nil)
        print("PASS: read/workflow independence, settle/undo, incoming precedence, pin preservation, snooze expiry/reload, outgoing settle, restore, compose, new mail, persistence, search, reset")
    }
    @MainActor static func checkInboxOrder() throws {
        struct FixturePersistence: ConversationPersistence {
            let items: [Conversation]
            func load() throws -> [Conversation]? { items }
            func save(_ conversations: [Conversation]) throws {}
        }
        let now = Date.now
        func item(_ subject: String, minutes: Double, unread: Bool, pinned: Bool = false, workflow: Workflow = .inbox) -> Conversation {
            Conversation(accountID: "icloud", subject: subject, workflow: workflow, unread: unread, pinned: pinned,
                         messages: [MailMessage(sender: "Sender", address: "sender@example.com", to: ["reader@example.com"], date: now.addingTimeInterval(-minutes * 60), body: "Example message")])
        }
        let store = MailStore(persistence: FixturePersistence(items: [
            item("Read newest", minutes: 1, unread: false),
            item("Unread older", minutes: 20, unread: true),
            item("Read pinned", minutes: 30, unread: false, pinned: true),
            item("Unread newer", minutes: 10, unread: true),
            item("Settled read", minutes: 1, unread: false, workflow: .settled),
            item("Settled unread", minutes: 20, unread: true, workflow: .settled)
        ]))
        assert(store.list(.inbox).map(\.subject) == ["Read pinned", "Read newest", "Unread newer", "Unread older"])
        assert(store.list(.inbox, unreadFirst: true).map(\.subject) == ["Read pinned", "Unread newer", "Unread older", "Read newest"])
        assert(store.list(.inbox, search: "older", unreadFirst: true).map(\.subject) == ["Unread older"])
        let newer = store.list(.inbox).first { $0.subject == "Unread newer" }!
        store.markRead(newer.id)
        assert(store.list(.inbox, unreadFirst: true).map(\.subject) == ["Read pinned", "Unread older", "Read newest", "Unread newer"])
        assert(store.conversation(newer.id)!.workflow == .inbox)
        assert(store.list(.settled, unreadFirst: true).map(\.subject) == ["Settled read", "Settled unread"])
        print("PASS: pinned precedence, unread-first ordering, arrival order, search, mark-read reorder, other sections unchanged")
    }

}
