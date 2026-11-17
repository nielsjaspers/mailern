import Foundation

@main struct WorkflowChecks {
    @MainActor static func main() async throws {
        try await checkUndoExpiry()
        try mailboxLoadFailurePreservesStoredMail()
        try await checkComposerData()
        try await checkDraftWriteOrdering()
        try await checkInboxDrafts()
        try await checkAttachmentStorage()
        try checkSettledRead()
        try checkBulkActions()
        checkDeliberatePull()
        try checkInboxOrder()
        try await checkMailboxFiltersAndDraftActions()
        try checkSnoozeSettings()
        try checkTrashAndJunk()
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
        assert(!store.conversation(id)!.unread)
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
        print("PASS: settled mail is read, settle/undo, incoming precedence, pin preservation, snooze expiry/reload, outgoing settle, restore, compose, new mail, persistence, search, reset")
    }

    @MainActor static func checkTrashAndJunk() throws {
        let disk = JSONPersistence(url: URL.temporaryDirectory.appending(path: "mailern-trash-\(UUID())/demo.json"))
        let store = MailStore(persistence: disk)
        let settled = store.list(.settled)[0].id
        store.apply(ids: [settled], action: .remove(.trash))
        assert(!store.list(.settled).contains { $0.id == settled } && store.list(.trash).map(\.id) == [settled])
        assert(!MailboxItem.list(conversations: store.conversations, drafts: [], status: .settled).contains { $0.id == settled })
        store.undo()
        assert(store.conversation(settled)!.removal == nil && store.list(.settled).contains { $0.id == settled })
        store.apply(ids: [settled], action: .remove(.trash))
        store.apply(ids: [settled], action: .restoreRemoved)
        assert(store.conversation(settled)!.workflow == .settled && store.list(.trash).isEmpty)
        store.apply(ids: [settled], action: .remove(.trash))
        store.receiveReply(settled)
        let rescued = store.conversation(settled)!
        assert(rescued.removal == nil && rescued.workflow == .inbox && rescued.unread)

        let spam = store.list(.inbox).first { !$0.senderAddresses.isEmpty }!
        let sender = spam.correspondent.address
        store.apply(ids: [spam.id], action: .remove(.junk))
        assert(store.blockedSenders.contains(sender.lowercased()) && store.list(.junk).map(\.id) == [spam.id])
        store.undo()
        assert(store.blockedSenders.isEmpty && store.conversation(spam.id)!.removal == nil)
        store.apply(ids: [spam.id], action: .remove(.junk))
        store.receiveReply(spam.id)
        assert(store.conversation(spam.id)!.removal == .junk && store.conversation(spam.id)!.unread)
        store.apply(ids: [spam.id], action: .restoreRemoved)
        assert(store.blockedSenders.isEmpty && store.list(.inbox).contains { $0.id == spam.id })

        store.apply(ids: [spam.id], action: .remove(.junk))
        store.deletePermanently([spam.id])
        assert(store.conversation(spam.id) == nil)
        let reloaded = MailStore(persistence: disk)
        assert(reloaded.blockedSenders == [sender.lowercased()], "A block must survive deleting its junk")
        reloaded.receiveNew()
        assert(reloaded.conversations[0].removal == nil)
        reloaded.apply(ids: [reloaded.conversations[0].id], action: .remove(.junk))
        reloaded.receiveNew()
        assert(reloaded.conversations[0].subject == "Coffee this week?" && reloaded.conversations[0].removal == .junk, "Mail from a blocked sender goes to Junk")
        reloaded.receiveJunk()
        assert(reloaded.list(.junk).contains { $0.subject == "You have been selected" })

        let old = reloaded.list(.inbox).prefix(2).map(\.id)
        reloaded.apply(ids: Set(old), action: .remove(.trash))
        reloaded.wakeDue(now: .now.addingTimeInterval(MailStore.trashRetention - 60))
        assert(old.allSatisfy { reloaded.conversation($0) != nil }, "Trash keeps mail for 30 days")
        reloaded.wakeDue(now: .now.addingTimeInterval(MailStore.trashRetention + 1))
        assert(old.allSatisfy { reloaded.conversation($0) == nil }, "Trash deletes mail after 30 days")
        reloaded.apply(ids: [reloaded.list(.inbox)[0].id], action: .remove(.trash))
        reloaded.deletePermanently(Set(reloaded.list(.trash).map(\.id)))
        assert(reloaded.list(.trash).isEmpty && MailStore(persistence: disk).conversations == reloaded.conversations)
        reloaded.reset()
        assert(reloaded.blockedSenders.isEmpty && reloaded.list(.junk).isEmpty)
        print("PASS: trash/junk lists, restore to original workflow, Undo with block list, reply rescues Trash but not Junk, block survives deletion, 30-day purge, permanent deletion, reset")
    }

    @MainActor static func checkUndoExpiry() async throws {
        let disk = JSONPersistence(url: URL.temporaryDirectory.appending(path: "mailern-undo-\(UUID())/demo.json"))
        let store = MailStore(persistence: disk)
        let ids = store.list(.inbox).prefix(2).map(\.id)
        store.move(ids[0], to: .settled)
        assert(store.notice != nil)
        try await Task.sleep(for: .seconds(3))
        assert(store.notice != nil, "Undo must remain available before five seconds")
        store.move(ids[1], to: .settled)
        try await Task.sleep(for: .seconds(2.5))
        assert(store.notice != nil, "A repeated action must get a fresh five-second window")
        try await Task.sleep(for: .seconds(3))
        assert(store.notice == nil, "Undo notice must expire after five seconds")
        store.undo()
        assert(ids.allSatisfy { store.conversation($0)!.workflow == .settled }, "Expired Undo must not change mail")
        store.move(ids[0], to: .inbox)
        store.undo()
        assert(store.notice == nil && store.conversation(ids[0])!.workflow == .settled)
        print("PASS: five-second Undo expiry, repeated action resets timer, Undo before and after expiry")
    }

    @MainActor static func checkSettledRead() throws {
        let disk = JSONPersistence(url: URL.temporaryDirectory.appending(path: "mailern-settled-\(UUID())/demo.json"))
        var legacy = DemoData.conversations()
        let settledIndex = legacy.firstIndex { $0.workflow == .settled }!
        legacy[settledIndex].unread = true
        try disk.save(MailData(conversations: legacy))
        let store = MailStore(persistence: disk)
        assert(store.list(.settled).allSatisfy { !$0.unread }, "Loaded settled mail must be read")
        let ids = Set(store.list(.inbox).prefix(2).map(\.id))
        let first = ids.first!
        store.markRead(first)
        let before = store.conversations.filter { ids.contains($0.id) }
        store.apply(ids: ids, action: .move(.settled))
        assert(ids.allSatisfy { store.conversation($0)!.workflow == .settled && !store.conversation($0)!.unread })
        store.undo()
        assert(store.conversations.filter { ids.contains($0.id) } == before)
        store.apply(ids: ids, action: .move(.settled))
        store.markRead(first, unread: true)
        assert(!store.conversation(first)!.unread)
        store.apply(ids: ids, action: .read(unread: true))
        assert(ids.allSatisfy { !store.conversation($0)!.unread })
        store.move(first, to: .inbox)
        store.markRead(first, unread: true)
        store.undo()
        assert(store.conversation(first)!.workflow == .settled && !store.conversation(first)!.unread)
        store.move(first, to: .inbox)
        store.markRead(first, unread: true)
        let source = store.conversation(first)!
        assert(store.send(threadID: first, account: source.account, to: [source.correspondent.address], cc: [], subject: source.subject, body: "Reply"))
        assert(!store.conversation(first)!.unread)
        assert(MailStore(persistence: disk).list(.settled).allSatisfy { !$0.unread })
        store.receiveReply(first)
        assert(store.conversation(first)!.workflow == .inbox && store.conversation(first)!.unread)
        store.reset()
        assert(store.list(.settled).allSatisfy { !$0.unread })
        print("PASS: settled load normalization, bulk settle/undo, unread guards, restore/undo, outgoing reply, reload, incoming reply, reset")
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
        let attached = items(.snoozed).first { $0.id == source.id }!
        assert(attached.drafts == [reply] && attached.conversation?.messages == source.messages)
        assert(!inbox.contains { $0.id == source.id })
        assert(!inbox.contains { $0.id == reply.id })
        assert([new, forward, orphan].allSatisfy { draft in inbox.contains { $0.id == draft.id && $0.conversation == nil } })
        assert(items(.snoozed).filter { $0.id == source.id }.count == 1)
        assert(items(.snoozed, search: "Unsent reply search proof").map(\.id) == [source.id])
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
        assert(!mail.conversation(source.id)!.unread)
        assert(saved && !items(.inbox).contains { $0.id == source.id } && items(.settled).contains { $0.id == source.id && $0.hasDraft })
        assert(mail.send(threadID: source.id, account: source.account, to: [reply.to], cc: [], subject: reply.subject, body: reply.text))
        let sent = await drafts.delete(reply.id)
        assert(sent && !items(.inbox).contains { $0.id == source.id } && items(.settled).contains { $0.id == source.id && !$0.hasDraft })
        assert(mail.send(threadID: nil, account: new.account, to: [new.to], cc: [], subject: new.subject, body: new.text))
        let newSent = await drafts.delete(new.id)
        assert(newSent && !items(.inbox).contains { $0.id == new.id })
        assert(items(.settled).contains { $0.conversation?.subject == new.subject && !$0.hasDraft })
        assert(MailStore(persistence: disk).conversations == mail.conversations)
        print("PASS: persisted drafts stay with their conversation, standalone new/forward/orphan drafts, draft search, discard preserves section, and sent drafts settle")
    }

    @MainActor static func mailboxLoadFailurePreservesStoredMail() throws {
        let directory = URL.temporaryDirectory.appending(path: "mail-load-failure-\(UUID())")
        let url = directory.appending(path: "mail.json")
        let file = MailAttachment(name: "Keep.txt", data: Data("Keep this attachment".utf8), contentType: "public.plain-text")
        var original = DemoData.conversations()
        original[0].messages[0].attachments = [file]
        try AttachmentJSON.save(MailData(conversations: original), to: url)
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
        // A reply or forward can target an earlier message instead of the latest.
        let first = revisedSource.messages[0]
        let earlierReply = ComposerDraft.make(mode: .replyAll(revisedID), conversation: revisedSource, message: first.id)
        assert(earlierReply.to == first.address && ComposerDraft.addresses(earlierReply.cc) == ["coordinator@college.example.com"])
        assert(earlierReply.text.contains(first.body) && !earlierReply.text.contains("Revised recipient group"))
        assert(earlierReply.messageID == first.id && revisedReply.messageID == nil)
        let earlierForward = ComposerDraft.make(mode: .forward(revisedID), conversation: revisedSource, message: first.id)
        assert(earlierForward.text.contains(first.body) && !earlierForward.text.contains("Revised recipient group"))
        assert(ComposerDraft.make(mode: .reply(revisedID), conversation: revisedSource, message: UUID()).text.contains("Revised recipient group"))
        assert(revisedSource.participants == "Dr. Jordan Lee, Me" && revisedSource.avatarName == "Dr. Jordan Lee")
        revised.send(threadID: nil, account: source.account, to: ["new@example.com", "other@example.com"], cc: [], subject: "Sent only", body: "Hello")
        var namesakes = revisedSource
        namesakes.receive(MailMessage(sender: "Dr. Jordan Lee", address: "other@example.com", to: [], date: .now, body: "A namesake"))
        namesakes.receive(MailMessage(sender: "Jordan", address: "JORDAN@college.example.com", to: [], date: .now, body: "A new display name"))
        assert(namesakes.participants == "Dr. Jordan Lee, Me, Dr. Jordan Lee")
        let sentOnly = revised.conversations.first { $0.subject == "Sent only" }!
        assert(sentOnly.participants == "To: new@example.com, other@example.com" && sentOnly.avatarName == "new@example.com")
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
        // The reply target is part of the stored draft.
        draft.messageID = source.messages[0].id
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
        // Forwarding an earlier message takes that message's attachments, not the latest ones.
        assert(ComposerDraft.make(mode: .forward(source.id), conversation: sent, message: sent.messages[0].id).attachments.isEmpty)
        assert(forward.mode.replyID == nil && forward.attachments == draft.attachments && forward.to.isEmpty)
        assert(MailStore(persistence: disk).conversation(source.id) == sent)
        store.receiveReply(source.id)
        let reactivated = store.conversation(source.id)!
        assert(reactivated.latest.subject == "Updated project scope")
        assert(ComposerDraft.make(mode: .reply(source.id), conversation: reactivated).subject == "Re: Updated project scope")
        assert(ComposerDraft.make(mode: .forward(source.id), conversation: reactivated).subject == "Fwd: Updated project scope")
        // An earlier message keeps the subject it was written under.
        let original = reactivated.messages[0].id
        assert(ComposerDraft.make(mode: .forward(source.id), conversation: reactivated, message: original).subject == "Fwd: \(source.subject)")
        assert(ComposerDraft.make(mode: .reply(source.id), conversation: reactivated, message: original).subject == "Re: \(source.subject)")
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
            func load() throws -> MailData? { MailData(conversations: DemoData.conversations()) }
            func save(_ data: MailData) throws { throw Failure.disk }
        }
        let failing = MailStore(persistence: FailingDisk())
        let before = failing.conversations
        assert(!failing.send(threadID: nil, account: source.account, to: ["test@example.com"], cc: [], subject: "Failure", body: "Retain draft"))
        assert(failing.conversations == before)
        final class ControlledDisk: ConversationPersistence {
            var fail = false
            func load() throws -> MailData? { MailData(conversations: DemoData.conversations()) }
            func save(_ data: MailData) throws { if fail { throw Failure.disk } }
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
            func load() throws -> MailData? { MailData(conversations: items) }
            func save(_ data: MailData) throws {}
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
        assert(store.list(.inbox, search: "older").map(\.subject) == ["Unread older"])
        let newer = store.list(.inbox).first { $0.subject == "Unread newer" }!
        store.markRead(newer.id)
        assert(store.list(.inbox).map(\.subject) == ["Read pinned", "Read newest", "Unread newer", "Unread older"])
        assert(store.conversation(newer.id)!.workflow == .inbox)
        assert(store.list(.settled).map(\.subject) == ["Settled read", "Settled unread"])
        print("PASS: pinned precedence, arrival order, search, mark-read preserves order, other sections unchanged")
    }

    @MainActor static func checkMailboxFiltersAndDraftActions() async throws {
        let now = Date.now
        var conversations = DemoData.conversations(now: now)
        let source = conversations[0]
        var reply = ComposerDraft.make(mode: .reply(source.id), conversation: source)
        reply.text = "Filter draft needle"
        var standalone = ComposerDraft(subject: "Standalone filter draft")
        standalone.updatedAt = now.addingTimeInterval(60)
        let drafts = [reply, standalone]
        func list(_ status: Workflow, _ filter: MailboxFilter = MailboxFilter(), search: String = "") -> [MailboxItem] {
            MailboxItem.list(conversations: conversations, drafts: drafts, status: status, search: search, filter: filter)
        }
        assert(list(.inbox).first?.id == source.id)
        let unread = MailboxFilter(enabled: true, readStatus: .unread)
        assert(list(.inbox, unread).count == 4 && list(.inbox, unread).allSatisfy(\.unread))
        assert(list(.inbox, MailboxFilter(enabled: true, readStatus: .read)).count == 2)
        assert(list(.inbox, MailboxFilter(enabled: true, accountIDs: ["university", "icloud"])).count == 5)
        assert(list(.inbox, MailboxFilter(enabled: true, accountIDs: [])).isEmpty)
        assert(list(.inbox, MailboxFilter(enabled: false, accountIDs: [], readStatus: .read, onlyDrafts: true)).count == 7)
        let draftFilter = MailboxFilter(enabled: true, onlyDrafts: true)
        assert(Set(list(.inbox, draftFilter).map(\.id)) == [source.id, standalone.id])
        assert(list(.inbox, draftFilter, search: "needle").map(\.id) == [source.id])
        assert(list(.inbox, MailboxFilter(enabled: true, readStatus: .unread, onlyDrafts: true)).map(\.id) == [source.id])
        conversations[0].move(to: .snoozed, until: now.addingTimeInterval(7200))
        assert(list(.snoozed, draftFilter).map(\.id) == [source.id])
        assert(!list(.inbox, draftFilter).contains { $0.id == source.id })
        conversations[0].unread = false
        assert(list(.snoozed, unread).isEmpty)
        assert(list(.snoozed, MailboxFilter(enabled: true, readStatus: .read)).count == 2)
        conversations[2].move(to: .settled)
        assert(list(.settled, MailboxFilter(enabled: true, onlySent: true)).map(\.id) == [conversations[2].id])
        // A sent reply still counts even when the latest message is incoming.
        assert(conversations[2].latest.outgoing == false)
        assert(list(.settled, MailboxFilter(enabled: true, accountIDs: ["proton"], onlySent: true)).isEmpty)
        var settings = MailboxFilters()
        settings[.inbox] = draftFilter
        settings[.snoozed] = unread
        let encoded = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(MailboxFilters.self, from: encoded)
        assert(decoded == settings)

        let url = URL.temporaryDirectory.appending(path: "mailern-draft-actions-\(UUID())/drafts.json")
        let store = DraftStore(url: url)
        let standaloneSaved = await store.save(standalone)
        assert(standaloneSaved)
        await store.togglePin(standalone.id)
        let snoozed = await store.snooze([standalone.id], until: now.addingTimeInterval(3600))
        assert(snoozed)
        let reloaded = DraftStore(url: url)
        let saved = reloaded.drafts[0]
        assert(saved.pinned == true && saved.snoozedUntil != nil)
        assert(MailboxItem.list(conversations: [], drafts: reloaded.drafts, status: .inbox).isEmpty)
        assert(MailboxItem.list(conversations: [], drafts: reloaded.drafts, status: .snoozed, filter: draftFilter).map(\.id) == [standalone.id])
        await reloaded.wakeDue(now: now.addingTimeInterval(3601))
        var staleEditor = saved
        staleEditor.text = "Edited after expiry"
        let edited = await reloaded.save(staleEditor)
        assert(edited)
        assert(reloaded.drafts[0].snoozedUntil == nil && reloaded.drafts[0].pinned == true)
        assert(reloaded.drafts[0].matchesContent(of: staleEditor))
        var newerEditor = staleEditor
        newerEditor.text += " Newer content"
        assert(!reloaded.drafts[0].matchesContent(of: newerEditor))
        newerEditor = staleEditor
        newerEditor.updatedAt = staleEditor.updatedAt.addingTimeInterval(1)
        assert(!reloaded.drafts[0].matchesContent(of: newerEditor))
        assert(MailboxItem.list(conversations: [], drafts: reloaded.drafts, status: .inbox).count == 1)
        let replySaved = await reloaded.save(reply)
        assert(replySaved)
        let failing = DraftStore(url: url, write: { _, _ in throw CocoaError(.fileWriteOutOfSpace) })
        let failedDiscard = await failing.discardForSettling([source.id, standalone.id])
        assert(!failedDiscard)
        assert(failing.drafts.count == 2 && DraftStore(url: url).drafts.count == 2)
        let discarded = await reloaded.discardForSettling([source.id, standalone.id])
        assert(discarded)
        assert(reloaded.drafts.isEmpty && DraftStore(url: url).drafts.isEmpty)
        print("PASS: account/read/draft/sent filter intersections, disabled filters, search, per-mailbox persistence, standalone pin/snooze/expiry, stale editor protection, and atomic discard failure")
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
