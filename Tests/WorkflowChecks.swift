import Foundation

@main struct WorkflowChecks {
    @MainActor static func main() throws {
        try checkComposerData()
        try checkBulkActions()
        checkDeliberatePull()
        try checkInboxOrder()
        try checkSnoozeSettings()
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
    @MainActor static func checkComposerData() throws {
        let dir = URL.temporaryDirectory.appending(path: "mailern-composer-\(UUID())")
        let disk = JSONPersistence(url: dir.appending(path: "mail.json"))
        let store = MailStore(persistence: disk)
        let source = store.list(.inbox).first { $0.subject == "Course project feedback" }!
        let reply = ComposerDraft.make(mode: .replyAll(source.id), conversation: source)
        assert(reply.to == source.correspondent.address)
        assert(ComposerDraft.addresses(reply.cc) == ["coordinator@college.example.com"])
        assert(reply.subject == "Re: \(source.subject)" && reply.text.contains(source.latest.body))
        var draft = ComposerDraft.make(mode: .new, conversation: nil)
        assert(!draft.canSend)
        draft.to = "recipient@example.com"
        assert(draft.canSend)
        draft.bcc = "bad address"
        assert(!draft.canSend)
        draft.bcc = "hidden@example.com"
        draft.to = ""
        assert(draft.canSend)
        draft.to = "recipient@example.com"
        draft.text = "A formatted message"
        draft.richText = Data("formatting payload".utf8)
        draft.attachments = [MailAttachment(name: "Example.txt", data: Data("Attachment proof".utf8), contentType: "public.plain-text")]
        let drafts = DraftStore(url: dir.appending(path: "drafts.json"))
        assert(drafts.save(draft))
        let reloaded = DraftStore(url: dir.appending(path: "drafts.json"))
        assert(reloaded.drafts == [draft])
        assert(store.send(threadID: source.id, account: source.account, to: [reply.to], cc: ComposerDraft.addresses(reply.cc),
                          subject: "Updated project scope", body: draft.text, bcc: ComposerDraft.addresses(draft.bcc), richText: draft.richText, attachments: draft.attachments))
        let sent = store.conversation(source.id)!
        assert(sent.workflow == .settled && sent.latest.outgoing)
        assert(sent.subject == source.subject && sent.latest.subject == "Updated project scope")
        assert(store.list(.settled, search: "Updated project scope").contains { $0.id == source.id })
        assert(sent.latest.bcc == ["hidden@example.com"] && sent.latest.richText == draft.richText && sent.latest.attachments == draft.attachments)
        let forward = ComposerDraft.make(mode: .forward(source.id), conversation: sent)
        assert(forward.mode.replyID == nil && forward.attachments == draft.attachments && forward.to.isEmpty)
        assert(MailStore(persistence: disk).conversation(source.id) == sent)
        store.receiveReply(source.id)
        let reactivated = store.conversation(source.id)!
        assert(reactivated.latest.subject == "Updated project scope")
        assert(ComposerDraft.make(mode: .reply(source.id), conversation: reactivated).subject == "Re: Updated project scope")
        assert(ComposerDraft.make(mode: .forward(source.id), conversation: reactivated).subject == "Fwd: Updated project scope")
        assert(drafts.delete(draft.id) && DraftStore(url: dir.appending(path: "drafts.json")).drafts.isEmpty)
        let damagedURL = dir.appending(path: "damaged-drafts.json")
        let damaged = Data("[{trailing damage".utf8)
        try damaged.write(to: damagedURL)
        let protected = DraftStore(url: damagedURL)
        assert(protected.error != nil)
        protected.error = nil
        assert(!protected.save(draft) && !protected.delete(draft.id))
        let retained = try Data(contentsOf: damagedURL)
        assert(retained == damaged)
        try JSONEncoder().encode([draft]).write(to: damagedURL)
        protected.reload()
        assert(protected.error == nil && protected.drafts == [draft])
        assert(protected.delete(draft.id))
        enum Failure: Error { case disk }
        struct FailingDisk: ConversationPersistence {
            func load() throws -> [Conversation]? { DemoData.conversations() }
            func save(_ conversations: [Conversation]) throws { throw Failure.disk }
        }
        let failing = MailStore(persistence: FailingDisk())
        let before = failing.conversations
        assert(!failing.send(threadID: nil, account: source.account, to: ["test@example.com"], cc: [], subject: "Failure", body: "Retain draft"))
        assert(failing.conversations == before)
        assert(!store.send(threadID: UUID(), account: source.account, to: ["test@example.com"], cc: [], subject: "Missing source", body: "Retain draft"))
        print("PASS: reply-all recipient deduplication, editable quotes, draft reload/delete, Bcc/rich text/attachments, forward payload, unreadable draft protection, and send-failure rollback")
    }

    @MainActor static func checkBulkActions() throws {
        let disk = JSONPersistence(url: URL.temporaryDirectory.appending(path: "mailern-bulk-\(UUID())/demo.json"))
        let store = MailStore(persistence: disk)
        let ids = Set(store.list(.inbox).prefix(2).map(\.id))
        let first = ids.first!
        store.markRead(first)
        let before = store.conversations.filter { ids.contains($0.id) }
        store.apply(ids: ids, action: .move(.settled))
        assert(ids.allSatisfy { store.conversation($0)!.workflow == .settled })
        store.undo()
        assert(store.conversations.filter { ids.contains($0.id) } == before)
        store.apply(ids: ids, action: .read(unread: true))
        assert(ids.allSatisfy { store.conversation($0)!.unread })
        store.togglePin(first)
        let pinned = store.conversation(first)!.pinned
        store.undo()
        assert(store.conversation(first)!.pinned == pinned)
        assert(ids.allSatisfy { id in store.conversation(id)!.unread == before.first { $0.id == id }!.unread })
        let pins = store.conversations.filter { ids.contains($0.id) }
        store.apply(ids: ids, action: .pin(true))
        assert(ids.allSatisfy { store.conversation($0)!.pinned })
        store.undo()
        assert(store.conversations.filter { ids.contains($0.id) } == pins)
        let until = Date.now.addingTimeInterval(500)
        store.apply(ids: ids, action: .move(.snoozed, until: until))
        assert(ids.allSatisfy { store.conversation($0)!.snoozedUntil == until })
        store.apply(ids: ids, action: .move(.inbox))
        assert(ids.allSatisfy { store.conversation($0)!.snoozedUntil == nil })
        store.undo()
        assert(ids.allSatisfy { store.conversation($0)!.workflow == .snoozed })
        store.apply(ids: ids, action: .move(.settled))
        store.receiveReply(first)
        store.undo()
        assert(store.conversation(first)!.workflow == .inbox && store.conversation(first)!.unread)
        assert(MailStore(persistence: disk).conversations == store.conversations)
        print("PASS: batch move/read/pin/snooze/restore, whole-batch field-specific Undo, incoming precedence and persistence")
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

    @MainActor static func checkSnoozeSettings() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
        for minutes in [0, 90, 150, 540, 1080, 1439] {
            assert(SnoozeSettings.clockMinutes(date: SnoozeSettings.clockDate(minutes: minutes)) == minutes)
        }
        let settings = SnoozeSettings()
        let now = date("2026-11-13T15:18:00+01:00")
        let options = settings.options(now: now, calendar: calendar)
        assert(options.map(\.id) == [.shortDelay, .evening, .longDelay, .tomorrow, .nextWeek])
        assert(options.first { $0.id == .evening }!.date == date("2026-11-13T18:00:00+01:00"))
        assert(options.first { $0.id == .nextWeek }!.date == date("2026-11-16T09:00:00+01:00"))
        assert(settings.options(now: date("2026-11-13T18:00:00+01:00"), calendar: calendar).allSatisfy { $0.id != .evening })
        let monday = settings.options(now: date("2026-11-16T08:00:00+01:00"), calendar: calendar)
        assert(monday.first { $0.id == .nextWeek }!.date == date("2026-11-23T09:00:00+01:00"))
        let sunday = settings.options(now: date("2026-11-15T23:30:00+01:00"), calendar: calendar)
        assert(sunday.first { $0.id == .nextWeek }!.date == date("2026-11-16T09:00:00+01:00"))
        let spring = settings.options(now: date("2026-03-28T15:00:00+01:00"), calendar: calendar)
        assert(spring.first { $0.id == .tomorrow }!.date == date("2026-03-29T09:00:00+02:00"))
        let fall = settings.options(now: date("2026-10-24T15:00:00+02:00"), calendar: calendar)
        assert(fall.first { $0.id == .tomorrow }!.date == date("2026-10-25T09:00:00+01:00"))
        var custom = settings
        custom.shortDelayMinutes = 240; custom.longDelayMinutes = 30
        custom.eveningMinutes = 17 * 60; custom.tomorrowMinutes = 8 * 60 + 30
        custom.nextWeekday = 4; custom.nextWeekMinutes = 10 * 60
        let changed = custom.options(now: now, calendar: calendar)
        assert(changed.map(\.id) == [.longDelay, .evening, .shortDelay, .tomorrow, .nextWeek])
        assert(changed.first { $0.id == .tomorrow }!.date == date("2026-11-14T08:30:00+01:00"))
        assert(changed.first { $0.id == .nextWeek }!.date == date("2026-11-18T10:00:00+01:00"))
        assert(custom.options(now: now.addingTimeInterval(120), calendar: calendar).first { $0.id == .shortDelay }!.date == now.addingTimeInterval(120 + 240 * 60))
        let suite = "mailern-snooze-check-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = SnoozePreferences(defaults: defaults)
        preferences.settings = custom
        assert(SnoozePreferences(defaults: defaults).settings == custom)
        preferences.settings.shortDelayMinutes = 90
        assert(SnoozePreferences(defaults: defaults).settings.shortDelayMinutes == 90)
        preferences.settings = SnoozeSettings()
        assert(SnoozePreferences(defaults: defaults).settings == settings)
        print("PASS: chronological snoozes, expired evening, Monday/Sunday boundaries, DST, custom settings and persistence")
    }

    static func checkDeliberatePull() {
        var pull = DeliberatePull()
        pull.begin(offset: 500, stationary: true)
        pull.move(distance: 300)
        assert(!pull.armed && pull.distance == 0 && !pull.end(distance: 300))
        pull.begin(offset: 0, stationary: false)
        assert(!pull.end(distance: 300))
        pull.begin(offset: -20, stationary: true)
        assert(!pull.end(distance: 300))
        pull.begin(offset: 0, stationary: true)
        for distance in [121.0, 50, 140, 20, 160] {
            pull.move(distance: distance)
            assert(pull.armed == (distance >= DeliberatePull.threshold))
            assert(pull.distance == distance)
        }
        assert(pull.end(distance: 160))
        assert(!pull.eligible && !pull.armed && pull.distance == 0)
        pull.begin(offset: 0, stationary: true)
        pull.move(distance: 160)
        assert(!pull.end(distance: 40))
        print("PASS: stationary-at-top gating, momentum rejection, rewind/rearm in one gesture, release cancellation")
    }
}
