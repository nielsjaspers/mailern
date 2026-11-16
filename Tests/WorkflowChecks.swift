import Foundation

@main struct WorkflowChecks {
    @MainActor static func main() async throws {
        try mailboxLoadFailurePreservesStoredMail()
        try await checkComposerData()
        try await checkDraftWriteOrdering()
        try await checkInboxDrafts()
        try await checkAttachmentStorage()
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

    @MainActor static func checkInboxDrafts() async throws {
        let directory = URL.temporaryDirectory.appending(path: "mailern-inbox-drafts-\(UUID())")
        let disk = JSONPersistence(url: directory.appending(path: "mail.json"))
        let mail = MailStore(persistence: disk)
        let draftsURL = directory.appending(path: "drafts.json")
        let drafts = DraftStore(url: draftsURL)
        let source = mail.list(.inbox).first { !$0.pinned }!
        mail.move(source.id, to: .snoozed, until: .now.addingTimeInterval(3600))
        var reply = ComposerDraft.make(mode: .replyAll(source.id), conversation: source)
        reply.text = "Unsent reply search proof"
        reply.updatedAt = .now.addingTimeInterval(10)
        let new = ComposerDraft(to: "new@example.com", subject: "Standalone draft", text: "New message")
        let forward = ComposerDraft.make(mode: .forward(source.id), conversation: source)
        let orphan = ComposerDraft(mode: .reply(UUID()), subject: "Missing source")
        for draft in [reply, new, forward, orphan] { let saved = await drafts.save(draft); assert(saved) }
        func items(_ status: Workflow, search: String = "") -> [MailboxItem] {
            MailboxItem.list(conversations: mail.conversations, drafts: DraftStore(url: draftsURL).drafts, status: status, search: search)
        }
        let inbox = items(.inbox)
        let attached = inbox.first { $0.id == source.id }!
        assert(attached.drafts == [reply] && attached.conversation?.messages == source.messages)
        assert(inbox.filter { $0.id == source.id }.count == 1)
        assert(!inbox.contains { $0.id == reply.id })
        assert([new, forward, orphan].allSatisfy { draft in inbox.contains { $0.id == draft.id && $0.conversation == nil } })
        assert(!items(.snoozed).contains { $0.id == source.id })
        assert(items(.inbox, search: "Unsent reply search proof").map(\.id) == [source.id])
        assert(items(.inbox, search: "new@example.com").map(\.id) == [new.id])
        let deleted = await drafts.delete(reply.id)
        assert(deleted && items(.snoozed).contains { $0.id == source.id })
        mail.move(source.id, to: .settled)
        let saved = await drafts.save(reply)
        mail.clearWorkflowUndo(involving: Set(drafts.drafts.compactMap { $0.mode.replyID }))
        assert(mail.notice == nil)
        mail.undo()
        assert(mail.conversation(source.id)!.workflow == .settled)
        mail.apply(ids: [source.id], action: .pin(true))
        mail.clearWorkflowUndo(involving: [source.id])
        mail.undo()
        assert(!mail.conversation(source.id)!.pinned)
        mail.apply(ids: [source.id], action: .read(unread: false))
        mail.clearWorkflowUndo(involving: [source.id])
        mail.undo()
        assert(mail.conversation(source.id)!.unread == source.unread)
        assert(saved && items(.inbox).contains { $0.id == source.id } && !items(.settled).contains { $0.id == source.id })
        assert(mail.send(threadID: source.id, account: source.account, to: [reply.to], cc: [], subject: reply.subject, body: reply.text))
        let sent = await drafts.delete(reply.id)
        assert(sent && !items(.inbox).contains { $0.id == source.id } && items(.settled).contains { $0.id == source.id && !$0.hasDraft })
        assert(mail.send(threadID: nil, account: new.account, to: [new.to], cc: [], subject: new.subject, body: new.text))
        let newSent = await drafts.delete(new.id)
        assert(newSent && !items(.inbox).contains { $0.id == new.id })
        assert(items(.settled).contains { $0.conversation?.subject == new.subject && !$0.hasDraft })
        assert(MailStore(persistence: disk).conversations == mail.conversations)
        print("PASS: persisted Inbox drafts, attached replies, standalone new/forward/orphan drafts, draft search, discard restores prior section, and sent drafts settle")
    }

    @MainActor static func mailboxLoadFailurePreservesStoredMail() throws {
        let directory = URL.temporaryDirectory.appending(path: "mail-load-failure-\(UUID())")
        let url = directory.appending(path: "mail.json")
        let file = MailAttachment(name: "Keep.txt", data: Data("Keep this attachment".utf8), contentType: "public.plain-text")
        var original = DemoData.conversations()
        original[0].messages[0].attachments = [file]
        try AttachmentJSON.save(original, to: url)
        let payload = AttachmentJSON.directory(for: url).appending(path: file.id.uuidString)
        let withheld = directory.appending(path: "withheld-payload")
        try FileManager.default.moveItem(at: payload, to: withheld)
        let bytes = try Data(contentsOf: url)
        let store = MailStore(persistence: JSONPersistence(url: url))
        assert(store.error != nil && store.conversations.isEmpty)
        store.error = nil
        assert(!store.send(threadID: nil, account: MailAccount.demo[1], to: ["recipient@example.com"], cc: [], subject: "New", body: "New"))
        store.receiveNew()
        let retained = try Data(contentsOf: url)
        assert(store.conversations.isEmpty && retained == bytes)
        assert(!store.reload())
        try FileManager.default.moveItem(at: withheld, to: payload)
        assert(store.reload() && store.conversations == original)
        assert(store.send(threadID: nil, account: MailAccount.demo[1], to: ["recipient@example.com"], cc: [], subject: "Recovered", body: "Recovered"))
        assert(Set(original.map(\.id)).isSubset(of: Set(MailStore(persistence: JSONPersistence(url: url)).conversations.map(\.id))))
        print("PASS: failed mailbox load preserves metadata and attachments despite new-mail actions")
    }
    @MainActor static func checkComposerData() async throws {
        let dir = URL.temporaryDirectory.appending(path: "mailern-composer-\(UUID())")
        let disk = JSONPersistence(url: dir.appending(path: "mail.json"))
        let store = MailStore(persistence: disk)
        let source = store.list(.inbox).first { $0.subject == "Course project feedback" }!
        let reply = ComposerDraft.make(mode: .replyAll(source.id), conversation: source)
        assert(reply.to == source.correspondent.address)
        assert(ComposerDraft.addresses(reply.cc) == ["coordinator@college.example.com"])
        assert(reply.subject == "Re: \(source.subject)" && reply.text.contains(source.latest.body))
        let revised = MailStore(persistence: JSONPersistence(url: dir.appending(path: "revised-recipients.json")))
        let revisedID = revised.list(.inbox).first { $0.subject == source.subject }!.id
        assert(revised.send(threadID: revisedID, account: source.account, to: ["revised@example.com"],
                            cc: ["team@example.com", source.account.address, "REVISED@example.com"],
                            subject: source.subject, body: "Revised recipient group"))
        let revisedSource = revised.conversation(revisedID)!
        let revisedReply = ComposerDraft.make(mode: .replyAll(revisedID), conversation: revisedSource)
        assert(revisedReply.to == "revised@example.com" && revisedReply.cc == "team@example.com")
        assert(revisedReply.text.contains("Revised recipient group") && !revisedReply.text.contains(source.latest.body))
        let singleReply = ComposerDraft.make(mode: .reply(revisedID), conversation: revisedSource)
        assert(singleReply.to == "revised@example.com" && singleReply.cc.isEmpty)
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
        let savedDraft = await drafts.save(draft)
        assert(savedDraft)
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
        let deletedDraft = await drafts.delete(draft.id)
        assert(deletedDraft && DraftStore(url: dir.appending(path: "drafts.json")).drafts.isEmpty)
        let damagedURL = dir.appending(path: "damaged-drafts.json")
        let damaged = Data("[{trailing damage".utf8)
        try damaged.write(to: damagedURL)
        let protected = DraftStore(url: damagedURL)
        assert(protected.error != nil)
        protected.error = nil
        assert(protected.needsReload)
        let protectedSave = await protected.save(draft)
        let protectedDelete = await protected.delete(draft.id)
        assert(!protectedSave && protectedDelete)
        let retained = try Data(contentsOf: damagedURL)
        assert(retained == damaged)
        try AttachmentJSON.save([draft], to: damagedURL)
        await protected.reload()
        assert(protected.error == nil && protected.drafts == [draft])
        let recoveredDelete = await protected.delete(draft.id)
        assert(recoveredDelete)
        enum Failure: Error { case disk }
        struct FailingDisk: ConversationPersistence {
            func load() throws -> [Conversation]? { DemoData.conversations() }
            func save(_ conversations: [Conversation]) throws { throw Failure.disk }
        }
        let failing = MailStore(persistence: FailingDisk())
        let before = failing.conversations
        assert(!failing.send(threadID: nil, account: source.account, to: ["test@example.com"], cc: [], subject: "Failure", body: "Retain draft"))
        assert(failing.conversations == before)
        final class ControlledDisk: ConversationPersistence {
            var fail = false
            func load() throws -> [Conversation]? { DemoData.conversations() }
            func save(_ conversations: [Conversation]) throws { if fail { throw Failure.disk } }
        }
        let controlled = ControlledDisk()
        let recoverable = MailStore(persistence: controlled)
        let recoveryID = recoverable.list(.inbox)[0].id
        recoverable.move(recoveryID, to: .settled)
        let notice = recoverable.notice
        controlled.fail = true
        assert(!recoverable.send(threadID: nil, account: source.account, to: ["test@example.com"], cc: [], subject: "Failure", body: "Keep Undo"))
        assert(recoverable.notice == notice)
        controlled.fail = false
        recoverable.undo()
        assert(recoverable.conversation(recoveryID)!.workflow == .inbox)
        recoverable.move(recoveryID, to: .settled)
        assert(recoverable.send(threadID: nil, account: source.account, to: ["test@example.com"], cc: [], subject: "Success", body: "Invalidate Undo"))
        recoverable.undo()
        assert(recoverable.notice == nil && recoverable.conversation(recoveryID)!.workflow == .settled)
        assert(!store.send(threadID: UUID(), account: source.account, to: ["test@example.com"], cc: [], subject: "Missing source", body: "Retain draft"))
        print("PASS: reply-all recipient deduplication, editable quotes, draft reload/delete, Bcc/rich text/attachments, forward payload, unreadable draft protection, and send-failure rollback")
    }

    @MainActor static func checkDraftWriteOrdering() async throws {
        final class Gate: @unchecked Sendable {
            let release = DispatchSemaphore(value: 0)
            private let lock = NSLock()
            private var first = true
            private var started = false
            var hasStarted: Bool { lock.lock(); defer { lock.unlock() }; return started }
            func write(_ data: Data, to url: URL) throws {
                lock.lock()
                let block = first
                first = false
                if block { started = true }
                lock.unlock()
                if block {
                    guard release.wait(timeout: .now() + 5) == .success else { throw CocoaError(.fileWriteUnknown) }
                }
                try data.write(to: url, options: .atomic)
            }
        }
        let url = URL.temporaryDirectory.appending(path: "mailern-ordered-drafts-\(UUID())/drafts.json")
        let gate = Gate()
        let store = DraftStore(url: url, write: { try gate.write($0, to: $1) })
        let first = ComposerDraft(subject: "First")
        let second = ComposerDraft(subject: "Second")
        let savingFirst = Task { await store.save(first) }
        var entered = false
        for _ in 0..<200 {
            if gate.hasStarted { entered = true; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        assert(entered) // Main-actor work continues while the writer is blocked.
        let savingSecond = Task { await store.save(second) }
        savingFirst.cancel()
        var deleteStarted = false
        let deletingFirst = Task {
            deleteStarted = true
            return await store.delete(first.id)
        }
        while !deleteStarted { await Task.yield() }
        gate.release.signal()
        let firstSaved = await savingFirst.value
        let secondSaved = await savingSecond.value
        let deleted = await deletingFirst.value
        assert(firstSaved && secondSaved && deleted)
        assert(store.drafts.map(\.id) == [second.id])
        assert(DraftStore(url: url).drafts.map(\.id) == [second.id])
        print("PASS: background writes, cancelled-save completion, cross-draft ordering, and ordered deletion")
    }

    @MainActor static func checkAttachmentStorage() async throws {
        let directory = URL.temporaryDirectory.appending(path: "mailern-attachment-files-\(UUID())")
        let draftURL = directory.appending(path: "drafts.json")
        let mailURL = directory.appending(path: "mail.json")
        let payload = Data(repeating: 42, count: 1024 * 1024)
        let file = MailAttachment(name: "Sample.bin", data: payload, contentType: "public.data")
        let draft = ComposerDraft(subject: "File storage", attachments: [file])
        let drafts = DraftStore(url: draftURL)
        let saved = await drafts.save(draft)
        assert(saved)
        let metadata = try Data(contentsOf: draftURL)
        assert(metadata.count < 4096)
        let loaded = DraftStore(url: draftURL).drafts[0].attachments[0]
        assert(loaded.data == payload)
        let mail = MailStore(persistence: JSONPersistence(url: mailURL))
        assert(mail.send(threadID: nil, account: MailAccount.demo[1], to: ["recipient@example.com"], cc: [],
                         subject: draft.subject, body: "Attached", attachments: [loaded]))
        let draftFile = AttachmentJSON.directory(for: draftURL).appending(path: file.id.uuidString)
        let mailFile = AttachmentJSON.directory(for: mailURL).appending(path: file.id.uuidString)
        let originalDate = try mailFile.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let deleted = await drafts.delete(draft.id)
        assert(deleted && !FileManager.default.fileExists(atPath: draftFile.path))
        let sent = mail.conversations.first { $0.subject == draft.subject }!.id
        assert(mail.conversation(sent)!.latest.attachments![0].data == payload)
        mail.markRead(sent)
        mail.togglePin(sent)
        mail.move(sent, to: .inbox)
        mail.undo()
        let mailMetadata = try Data(contentsOf: mailURL)
        let savedDate = try mailFile.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        assert(mailMetadata.count < 32 * 1024 && savedDate == originalDate)
        assert(MailStore(persistence: JSONPersistence(url: mailURL)).conversation(sent)!.latest.attachments![0].data == payload)

        let healthy = await drafts.save(draft)
        assert(healthy)
        let durableMetadata = try Data(contentsOf: draftURL)
        let failing = DraftStore(url: draftURL, write: { _, _ in throw CocoaError(.fileWriteOutOfSpace) })
        let unsavedFile = MailAttachment(name: "Unsaved.bin", data: Data([1, 2, 3]), contentType: "public.data")
        let unsaved = ComposerDraft(subject: "Failed metadata", attachments: [unsavedFile])
        let failed = await failing.save(unsaved)
        let preservedMetadata = try Data(contentsOf: draftURL)
        assert(!failed && preservedMetadata == durableMetadata)
        assert(!FileManager.default.fileExists(atPath: AttachmentJSON.directory(for: draftURL).appending(path: unsavedFile.id.uuidString).path))
        let discarded = await failing.delete(unsaved.id)
        assert(discarded && !FileManager.default.fileExists(atPath: AttachmentJSON.directory(for: draftURL).appending(path: unsavedFile.id.uuidString).path))
        assert(FileManager.default.fileExists(atPath: draftFile.path))
        let damaged = Data("[{}]".utf8)
        try damaged.write(to: draftURL)
        let retainedAfterCorruption = await drafts.delete(UUID())
        assert(retainedAfterCorruption && FileManager.default.fileExists(atPath: draftFile.path))
        let protected = DraftStore(url: draftURL)
        let untouched = await protected.delete(UUID())
        let preservedDamage = try Data(contentsOf: draftURL)
        assert(untouched && preservedDamage == damaged && FileManager.default.fileExists(atPath: draftFile.path))
        print("PASS: small metadata, mapped attachment reload, draft-to-mail transfer, unchanged payloads on workflow saves, cleanup, and failed/corrupt metadata protection")
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
