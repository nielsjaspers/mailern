import Foundation
import SQLite3

@main struct WorkflowChecks {
    @MainActor static func main() async throws {
        try await checkUndoExpiry()
        try await mailboxLoadFailurePreservesStoredMail()
        try await checkComposerData()
        try await checkDraftWriteOrdering()
        try await checkInboxDrafts()
        try await checkAttachmentStorage()
        try checkSettledRead()
        try await checkBulkActions()
        checkDeliberatePull()
        try checkInboxOrder()
        try await checkMailboxFiltersAndDraftActions()
        try checkSnoozeSettings()
        try checkTrashAndJunk()
        try checkSenderBlocking()
        try checkSQLiteStorage()
        try checkBenchmarkMailbox()
        try await checkAccounts()
        try checkThreadingHeaders()
        checkMessageLinks()
        checkHTMLDocument()
        checkQuotedText()
        try checkMute()
        try checkFollowUp()
        try await checkOutbox()
        try await checkExistingOutbox()
        try await checkLocalReminders()
        try checkActionHaptics()
        await checkDraftDiscardHaptics()
        checkAllMailSearch()
        checkNextConversation()
        let directory = URL.temporaryDirectory.appending(path: "mailern-check-\(UUID())")
        let disk = SQLitePersistence(url: directory.appending(path: "demo.sqlite"))
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
        store.send(threadID: id, account: store.account(c.accountID), to: [c.correspondent.address], cc: [], subject: c.subject, body: "Thanks, here's the plan.")
        assert(store.conversation(id)!.workflow == .settled && store.conversation(id)!.messages.count == beforeSend + 1)
        assert(store.conversation(id)!.latest.outgoing)
        store.move(id, to: .inbox)
        assert(store.conversation(id)!.workflow == .inbox)
        store.send(threadID: nil, account: store.account(c.accountID), to: ["test@example.com"], cc: [], subject: "New outgoing", body: "Hello")
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

    /// The mailbox plays a haptic when `actionCount` changes, so only moves a person makes may change it.
    @MainActor static func checkActionHaptics() throws {
        let store = MailStore(persistence: SQLitePersistence(url: URL.temporaryDirectory.appending(path: "mailern-haptics-\(UUID()).sqlite")))
        let id = store.list(.inbox).first { $0.unread }!.id
        func changes(_ action: () -> Void) -> Bool {
            let before = store.actionCount
            action()
            return store.actionCount != before
        }
        assert(!changes { store.markRead(id) }, "Opening a conversation must not play a haptic")
        assert(changes { store.setUnread(id, true) })
        assert(changes { store.togglePin(id) })
        assert(changes { store.move(id, to: .snoozed, until: .now.addingTimeInterval(60)) })
        assert(!changes { store.move(id, to: .snoozed, until: .now.addingTimeInterval(-60)) }, "A refused snooze must not play a haptic")
        assert(changes { store.move(id, to: .settled) })
        assert(!changes { store.setUnread(id, true) }, "Settled mail cannot become unread")
        assert(changes { store.apply(ids: [id], action: .remove(.trash)) })
        assert(!changes { store.apply(ids: [id], action: .remove(.trash)) }, "Trashing trashed mail changes nothing")
        assert(changes { store.apply(ids: [id], action: .restoreRemoved) })
        assert(!changes { store.receiveReply(id) }, "Incoming mail is not a move")
        print("PASS: haptics follow moves a person makes, not opening mail, refused moves, or incoming mail")
    }

    @MainActor static func checkDraftDiscardHaptics() async {
        let drafts = DraftStore(url: URL.temporaryDirectory.appending(path: "mailern-draft-haptics-\(UUID()).json"))
        let source = DemoData.conversations()[0]
        let reply = ComposerDraft.make(mode: .reply(source.id), conversation: source, accounts: MailAccount.demo)
        let standalone = ComposerDraft(subject: "Standalone haptic")
        await drafts.save(reply)
        await drafts.save(standalone)
        let before = drafts.actionCount
        let replyDiscarded = await drafts.discardDrafts(for: [source.id])
        assert(replyDiscarded && drafts.actionCount == before, "The conversation's own move plays the haptic")
        let draftDiscarded = await drafts.discardDrafts(for: [standalone.id])
        assert(draftDiscarded && drafts.actionCount == before + 1, "Settling a draft row plays one")
        print("PASS: discarding a standalone draft plays one haptic; reply drafts leave it to their conversation's move")
    }

    static func checkAllMailSearch() {
        let now = Date.now
        var conversations = DemoData.conversations(now: now)
        conversations[1].move(to: .snoozed, until: now.addingTimeInterval(600))
        conversations[2].removal = .trash(since: now)
        let photos = conversations.first { $0.subject == "The photos from our trip" }!
        var draft = ComposerDraft(subject: "Weekend photos draft")
        draft.updatedAt = now.addingTimeInterval(60)
        func all(_ text: String) -> [MailboxItem] {
            MailboxItem.list(conversations: conversations, drafts: [draft], status: nil, search: MailSearch(text: text),
                             filter: MailboxFilter(enabled: true, accountIDs: []))
        }
        assert(MailboxItem.list(conversations: conversations, drafts: [draft], status: .inbox, search: MailSearch(text: "photos")).map(\.id) == [draft.id])
        assert(all("photos").map(\.id) == [draft.id, photos.id], "All mail finds settled mail and drafts, newest first, and ignores filters")
        let everything = all("")
        assert(Set(everything.map(\.workflow)) == [.inbox, .snoozed, .settled])
        assert(everything.count == conversations.count, "All mail leaves out Trash and adds the standalone draft")
        assert(!everything.contains { $0.id == conversations[2].id })
        assert(everything.map(\.workflow) == everything.map(\.workflow).sorted { Workflow.allCases.firstIndex(of: $0)! < Workflow.allCases.firstIndex(of: $1)! },
               "All mail lists its sections in the order the list shows them")
        for status in Workflow.allCases {
            let section = everything.filter { $0.workflow == status }
            assert(zip(section, section.dropFirst()).allSatisfy { $0.date >= $1.date }, "Pins and snooze order belong to one section")
        }
        print("PASS: all-mail search spans Inbox, Snoozed, and Settled with drafts, grouped by section and newest first, without filters, Junk, or Trash")
    }

    static func checkNextConversation() {
        let (a, draft, b, c, d) = (UUID(), UUID(), UUID(), UUID(), UUID())
        let order = [a, draft, b, c]
        func next(_ id: UUID, _ available: Set<UUID>) -> UUID? { MailboxItem.conversation(after: id, in: order, available: available) }
        assert(next(a, [a, b, c]) == b, "Drafts are skipped")
        assert(next(c, [a, b, c]) == b, "The last one goes up")
        // An Unread filter drops the opened conversation once it is read. Its place in the order still counts.
        assert(next(a, [b, c]) == b && next(b, [c]) == c)
        assert(next(b, [a, c]) == c, "Conversations that left the list are skipped")
        assert(next(a, []) == nil, "Nothing left")
        assert(next(d, [a, b, c]) == nil, "Not opened from this list")
        print("PASS: next conversation after Settle goes down, then up, keeps the opened conversation's place, skips drafts and departed mail")
    }

    @MainActor static func checkSQLiteStorage() throws {
        let url = URL.temporaryDirectory.appending(path: "mailern-sqlite-\(UUID())/mail.sqlite")
        let store = MailStore(persistence: SQLitePersistence(url: url))
        let changed = store.list(.inbox)[0].id
        let untouched = store.list(.settled)[0].id
        // Loading writes the seed data in full, so search works before the first change. Later saves write only what changed.
        assert(store.search("Saturday").indexed?.isEmpty == false)
        store.markRead(changed)
        assert(!MailStore(persistence: SQLitePersistence(url: url)).conversation(changed)!.unread)
        // A second connection plants an unreadable row. A save that rewrote every row would replace it.
        var db: OpaquePointer?
        assert(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        func payload(_ id: UUID) -> String? {
            var statement: OpaquePointer?
            sqlite3_prepare_v2(db, "SELECT CAST(payload AS TEXT) FROM conversations WHERE id = '\(id.uuidString)'", -1, &statement, nil)
            defer { sqlite3_finalize(statement) }
            return sqlite3_step(statement) == SQLITE_ROW ? String(cString: sqlite3_column_text(statement, 0)) : nil
        }
        assert(sqlite3_exec(db, "UPDATE conversations SET payload = CAST('planted' AS BLOB) WHERE id = '\(untouched.uuidString)'", nil, nil, nil) == SQLITE_OK)
        assert(sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK)
        store.markRead(changed, unread: true)
        assert(store.error != nil && store.conversation(changed)!.unread)
        assert(sqlite3_exec(db, "ROLLBACK", nil, nil, nil) == SQLITE_OK)
        store.markRead(changed, unread: true)
        assert(payload(changed)?.contains("\"unread\":true") == true)
        store.error = nil
        store.move(changed, to: .settled)
        store.receiveNew()
        assert(store.error == nil && payload(untouched) == "planted" && payload(changed)?.contains("settled") == true)
        assert(sqlite3_exec(db, "DELETE FROM conversations WHERE id = '\(untouched.uuidString)'", nil, nil, nil) == SQLITE_OK)
        store.deletePermanently([untouched])
        let reloaded = MailStore(persistence: SQLitePersistence(url: url))
        assert(reloaded.conversations == store.conversations && reloaded.conversations[0].subject == "Coffee this week?")

        // Trigram search matches any substring of three or more characters, ignoring case.
        let coffee = store.conversations[0].id
        assert(store.search("FFEE THIS").indexed == [coffee] && store.list(.inbox, search: "ffee this").map(\.id) == [coffee])
        assert(store.search("Ri").indexed == nil && store.list(.inbox, search: "Ri").contains { $0.id == coffee })
        assert(store.search("\"quoted\" text").indexed == [])
        // Account names are not in the index. They still match through the in-memory account check.
        assert(store.search("Personal").indexed?.contains(coffee) == false && store.list(.inbox, search: "Personal").contains { $0.id == coffee })
        store.receiveReply(coffee)
        assert(store.search("A quick follow-up").indexed == [coffee])
        // The index folds case and accents like the in-memory search does.
        assert(store.send(threadID: nil, account: store.accounts[0], to: ["café@example.com"], cc: [], subject: "Straße Café", body: "Hi"))
        let sent = store.conversations[0].id
        assert(store.search("STRASSE").indexed?.contains(sent) == true && store.search("Cafe\u{0301}").indexed?.contains(sent) == true)
        print("PASS: SQLite rewrites only changed rows, keeps load order, removes deleted rows, and trigram search with short-query and account-name fallback")
    }

    @MainActor static func checkAccounts() async throws {
        let directory = URL.temporaryDirectory.appending(path: "mailern-accounts-\(UUID())")
        let url = directory.appending(path: "mail.sqlite")
        let store = MailStore(persistence: SQLitePersistence(url: url))
        let drafts = DraftStore(url: directory.appending(path: "drafts.json"))
        var work = MailAccount(id: "work", name: " Work ", address: "morgan@work.example.com ", color: .red, signature: "Morgan\nExample Studio\n")
        assert(store.problem(with: MailAccount(id: "x", name: "", address: "a@b.example", color: .red)) != nil)
        assert(store.problem(with: MailAccount(id: "x", name: "X", address: "not-an-address", color: .red)) != nil)
        assert(store.problem(with: MailAccount(id: "x", name: "X", address: "MORGAN@personal.example.com", color: .red)) != nil)
        assert(store.problem(with: MailAccount.demo[0]) == nil)
        assert(store.saveAccount(work))
        work = store.account("work")
        assert(work.name == "Work" && work.address == "morgan@work.example.com" && work.signature == "Morgan\nExample Studio")
        assert(store.send(threadID: nil, account: work, to: ["client@example.com"], cc: [], subject: "Studio update", body: "Hello"))
        let sent = store.conversations.first { $0.subject == "Studio update" }!
        work.name = "Studio"
        assert(store.saveAccount(work))
        assert(store.list(.settled, search: "Studio").contains { $0.id == sent.id })
        assert(MailStore(persistence: SQLitePersistence(url: url)).accounts == store.accounts)

        // Signatures go into new mail, and above the quote in replies and forwards.
        assert(ComposerDraft.make(mode: .new, conversation: nil, accounts: store.accounts).text == "\n\nMorgan")
        let university = store.conversations.first { $0.accountID == "university" }!
        let reply = ComposerDraft.make(mode: .reply(university.id), conversation: university, accounts: store.accounts)
        assert(reply.signature == "Morgan\nStudent, Example College")
        assert(reply.text.hasPrefix("\n\nMorgan\nStudent, Example College\n\nOn "))
        let forward = ComposerDraft.make(mode: .forward(sent.id), conversation: sent, accounts: store.accounts)
        assert(forward.text.hasPrefix("\n\nMorgan\nExample Studio\n\nBegin forwarded message"))
        let quiet = store.conversations.first { $0.accountID == "proton" }!
        let plain = ComposerDraft.make(mode: .reply(quiet.id), conversation: quiet, accounts: store.accounts)
        assert(plain.signature == "" && plain.text.hasPrefix("\n\nOn "))

        // A sender change swaps an unedited signature, keeps an edited one, and inserts one above the quote.
        func swapped(_ body: String, old: String, new: String, quote: Int? = nil) -> String? {
            let text = NSMutableAttributedString(string: body)
            guard ComposerDraft.swapSignature(in: text, old: old, replacement: NSAttributedString(string: ComposerDraft.signatureBlock(new)), quoteStart: quote) != nil else { return nil }
            return text.string
        }
        assert(swapped("Hi\n\nMorgan M.", old: "Morgan M.", new: "Morgan") == "Hi\n\nMorgan")
        assert(swapped("Hi\n\nMorgan X.", old: "Morgan M.", new: "Morgan") == nil)
        assert(swapped("Hi\n\nMorgan M.", old: "Morgan", new: "Avery") == nil)
        assert(swapped("Hi\n\nMorgan M. and Morgan\n\nOn Monday", old: "Morgan", new: "Avery") == nil)
        assert(swapped("Hi\n\nMorgan\n\nOn Monday", old: "Morgan", new: "Avery", quote: 12) == "Hi\n\nAvery\n\nOn Monday")
        // Only the inserted block at the end counts. Earlier text that looks like it stays untouched.
        assert(swapped("Hi\n\nMorgan\n\nPlease call me.\n\nMorgan", old: "Morgan", new: "Avery") == "Hi\n\nMorgan\n\nPlease call me.\n\nAvery")
        assert(swapped("Participants:\n\nMorgan\nAvery\n\nMorgan (edited)", old: "Morgan", new: "Avery") == nil)
        assert(swapped("Hi\n\nMorgan\n\nP.S. Call me", old: "Morgan", new: "Avery") == nil)
        let formatted = NSMutableAttributedString(string: "Hi\n\nMorgan")
        assert(ComposerDraft.swapSignature(in: formatted, old: "Morgan", replacement: NSAttributedString(string: "\n\nAvery"), quoteStart: nil,
                                           unedited: { _ in false }) == nil && formatted.string == "Hi\n\nMorgan")
        // The quote can contain the old signature's text. An edited signature must not redirect the swap into the quote.
        let forwardBody = "\n\nMorgan (edited)\n\nBegin forwarded message:\n\nThanks\n\nMorgan"
        assert(swapped(forwardBody, old: "Morgan", new: "Avery", quote: 19) == nil)
        assert(swapped("\n\nMorgan\n\nBegin forwarded message:\n\nThanks\n\nMorgan", old: "Morgan", new: "Avery", quote: 10)
               == "\n\nAvery\n\nBegin forwarded message:\n\nThanks\n\nMorgan")
        assert(swapped("Hi\n\nMorgan", old: "Morgan", new: "") == "Hi")
        assert(swapped("Hi", old: "", new: "Morgan") == "Hi\n\nMorgan")
        assert(swapped("Hi\n\nOn Monday, Avery wrote:", old: "", new: "Morgan", quote: 4) == "Hi\n\nMorgan\n\nOn Monday, Avery wrote:")

        var studioDraft = ComposerDraft(subject: "Studio draft")
        studioDraft.accountID = "work"
        let savedDraft = await drafts.save(studioDraft)
        let keptDraft = await drafts.save(ComposerDraft(subject: "Personal draft"))
        assert(savedDraft && keptDraft)
        // A failed draft write keeps the account, its mail, and its drafts, so no draft is left without a sender.
        let failingDrafts = DraftStore(url: directory.appending(path: "drafts.json"), write: { _, _ in throw CocoaError(.fileWriteOutOfSpace) })
        let failure = await store.deleteAccount("work", drafts: failingDrafts)
        assert(failure != nil && store.account("work").name == "Studio" && store.conversation(sent.id) != nil && failingDrafts.drafts.count == 2)
        // A failed database write after the drafts are gone puts the drafts back.
        var lock: OpaquePointer?
        assert(sqlite3_open(url.path, &lock) == SQLITE_OK && sqlite3_exec(lock, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK)
        let locked = await store.deleteAccount("work", drafts: drafts)
        sqlite3_exec(lock, "ROLLBACK", nil, nil, nil)
        sqlite3_close(lock)
        store.error = nil
        assert(locked != nil && store.account("work").name == "Studio" && Set(drafts.drafts.map(\.subject)) == ["Studio draft", "Personal draft"])
        assert(Set(DraftStore(url: directory.appending(path: "drafts.json")).drafts.map(\.subject)) == ["Studio draft", "Personal draft"])
        // An unreadable draft store can still hold the account's drafts, so deletion waits until it loads.
        let unreadableURL = directory.appending(path: "unreadable-drafts.json")
        try Data("not json".utf8).write(to: unreadableURL)
        let unreadable = DraftStore(url: unreadableURL)
        let blocked = await store.deleteAccount("work", drafts: unreadable)
        assert(blocked != nil && store.account("work").name == "Studio")
        let deleted = await store.deleteAccount("work", drafts: drafts)
        assert(deleted == nil && drafts.drafts.map(\.subject) == ["Personal draft"])
        assert(store.conversation(sent.id) == nil && store.account("work").name == "Removed account")
        assert(!store.send(threadID: nil, account: store.account("work"), to: ["client@example.com"], cc: [], subject: "Orphan", body: "No sender"))
        store.error = nil
        let reopened = MailStore(persistence: SQLitePersistence(url: url))
        assert(reopened.accounts == MailAccount.demo && reopened.conversation(sent.id) == nil)
        for account in MailAccount.demo.dropFirst() { assert(reopened.deleteAccount(account.id)) }
        assert(!reopened.deleteAccount(MailAccount.demo[0].id) && reopened.accounts.count == 1)
        reopened.receiveNew()
        reopened.receiveJunk()
        assert(reopened.conversations.allSatisfy { $0.accountID == MailAccount.demo[0].id })
        reopened.reset()
        assert(reopened.accounts == MailAccount.demo && MailStore(persistence: SQLitePersistence(url: url)).accounts == MailAccount.demo)
        print("PASS: account validation, trimming, edit and persistence, renamed-account search, signatures in new/reply/forward, signature swap rules, account deletion with mail and drafts, last account kept, demo mail follows remaining accounts, reset")
    }

    @MainActor static func checkThreadingHeaders() throws {
        let disk = SQLitePersistence(url: URL.temporaryDirectory.appending(path: "mailern-threading-\(UUID())/mail.sqlite"))
        let store = MailStore(persistence: disk)
        let dinner = store.conversations.first { $0.subject == "Dinner on Saturday?" }!
        let (first, answer, followUp) = (dinner.messages[0], dinner.messages[1], dinner.messages[2])
        assert(first.messageID != nil && answer.inReplyTo == first.messageID && followUp.references == [first.threadingID, answer.threadingID])

        let count = store.conversations.count
        store.receiveReply(dinner.id)
        let reply = store.conversation(dinner.id)!.latest
        assert(store.conversations.count == count && reply.inReplyTo == followUp.messageID)
        assert(reply.references == [first.threadingID, answer.threadingID, followUp.threadingID])

        store.send(threadID: dinner.id, replyingTo: first.id, account: store.account(dinner.accountID), to: [first.address], cc: [], subject: "Re: Dinner", body: "Yes")
        let sent = store.conversation(dinner.id)!.latest
        assert(sent.outgoing && sent.messageID!.hasSuffix("@personal.example.com>") && sent.inReplyTo == first.messageID && sent.references == [first.threadingID])
        store.send(threadID: nil, account: store.accounts[0], to: ["a@example.com"], cc: [], subject: "New", body: "Hello")
        assert(store.conversations[0].latest.inReplyTo == nil && store.conversations[0].latest.messageID != nil)

        // A reply joins only a thread in its own account. An unknown parent starts a new conversation.
        var stray = MailMessage(sender: "Casey Rivera", address: "casey@example.com", to: [store.accounts[1].address], date: .now, body: "Hi",
                                subject: "Re: Dinner on Saturday?", messageID: "<other@example.com>")
        stray.answer(followUp)
        store.receive(stray, accountID: store.accounts[1].id)
        assert(store.conversations.count == count + 2 && store.conversations[0].messages.map(\.id) == [stray.id])
        var unknown = stray
        unknown.id = UUID()
        unknown.inReplyTo = "<missing@example.com>"
        unknown.references = ["<missing@example.com>"]
        store.receive(unknown, accountID: dinner.accountID)
        assert(store.conversations.count == count + 3 && store.conversations[0].subject == "Re: Dinner on Saturday?")
        var byReference = unknown
        byReference.id = UUID()
        byReference.inReplyTo = nil
        byReference.references = [first.threadingID]
        store.receive(byReference, accountID: dinner.accountID)
        assert(store.conversation(dinner.id)!.latest.id == byReference.id, "References alone thread a message")

        let reloaded = MailStore(persistence: SQLitePersistence(url: disk.url))
        assert(reloaded.conversation(dinner.id) == store.conversation(dinner.id), "Headers survive a reload")

        // A saved toolbar reply keeps answering the message it quotes after newer mail arrives.
        let project = store.conversations.first { $0.subject == "Course project feedback" }!
        let draft = ComposerDraft.make(mode: .reply(project.id), conversation: project, accounts: store.accounts)
        assert(draft.messageID == nil && draft.answering == project.latest.id)
        store.receiveReply(project.id)
        store.send(threadID: project.id, replyingTo: draft.answering ?? draft.messageID, account: store.account(project.accountID),
                   to: [project.latest.address], cc: [], subject: draft.subject, body: "Thanks")
        assert(store.conversation(project.id)!.latest.inReplyTo == project.latest.messageID)

        // Mail stored before Message-IDs existed still threads, through the local stand-in ID.
        let legacy = SQLitePersistence(url: URL.temporaryDirectory.appending(path: "mailern-legacy-\(UUID())/mail.sqlite"))
        let old = MailMessage(sender: "Avery", address: "avery@example.com", to: [MailAccount.demo[0].address], date: .now, body: "Old")
        let conversation = Conversation(accountID: MailAccount.demo[0].id, subject: "Old thread", messages: [old])
        try legacy.save(MailData(conversations: [conversation]))
        let legacyStore = MailStore(persistence: SQLitePersistence(url: legacy.url))
        legacyStore.receiveReply(conversation.id)
        assert(legacyStore.conversations.count == 1 && legacyStore.conversation(conversation.id)!.latest.inReplyTo == old.threadingID)
        print("PASS: Message-ID headers on demo and sent mail, threading by In-Reply-To and References within one account, legacy mail")
    }

    static func checkQuotedText() {
        let casey = MailMessage(sender: "Casey Rivera", address: "casey@example.com", to: [], date: .now,
                                body: "Hey! Are you free on Saturday? I was thinking we could cook at my place.\n\nCasey")
        func visible(_ body: String, _ answered: MailMessage? = casey) -> String? {
            QuotedText.start(in: body, answering: answered).map { String((body as NSString).substring(to: $0)) }
        }
        // Mailern's composer quotes the answered body under its attribution line, without `>`.
        let attribution = QuotedText.attribution(for: casey)
        let reply = "Sure, 7 works.\n\nMorgan\n\n\(attribution)\n\(casey.body)"
        assert(visible(reply) == "Sure, 7 works.\n\nMorgan\n\n")
        // Text written below the quote, an edited quote, or a different attribution keeps the whole message visible.
        assert(visible(reply + "\n\nP.S. I'll bring wine.") == nil, "Text below a quote never folds")
        assert(visible(reply + "\n") == nil && visible(reply + "\t") == nil, "Even whitespace added below the quote is not proven")
        assert(visible(reply.replacingOccurrences(of: "Saturday", with: "Sunday")) == nil, "An edited quote is not proven")
        assert(visible("Yes.\n\nOn the sign at check-in, Casey Rivera <casey@example.com> wrote:\n\(casey.body)") == nil,
               "Only the composer's own attribution counts")
        assert(visible(reply, nil) == nil, "A message that answers nothing quotes nothing")
        assert(visible(reply, MailMessage(sender: "Casey Rivera", address: "casey@example.com", to: [], date: casey.date, body: " ")) == nil,
               "An empty answered body proves nothing")
        // Quotes from other clients are not recognized yet, so `>` lines always show.
        let marked = "> Hey! Are you free on Saturday? I was thinking we could cook at my place.\n>\n> Casey"
        assert(visible("Yes.\n\nOn Monday, Casey <casey@example.com> wrote:\n" + marked) == nil)
        assert(visible("Set the cutoff to\n> 0", MailMessage(sender: "Avery", address: "avery@example.com", to: [], date: .now, body: "0")) == nil)
        assert(visible("\n\n\(attribution)\n\(casey.body)") == nil, "A message never folds to nothing")
        assert(visible(reply.replacingOccurrences(of: "\nHey!", with: "\n  Hey!")) == nil, "Changed indentation is not proven")
        // A quote that only looks the same, here a decomposed é, is not proven and cannot shift the fold.
        let cafe = MailMessage(sender: "Casey Rivera", address: "casey@example.com", to: [], date: casey.date, body: "Caf\u{E9}?")
        assert(visible("Yes.\n\n\(QuotedText.attribution(for: cafe))\nCafe\u{301}?", cafe) == nil)
        assert(visible("Yes.\n\n\(QuotedText.attribution(for: cafe))\nCaf\u{E9}?", cafe) == "Yes.\n\n")
        // Forwarded mail is the point of a forward and does not fold.
        assert(visible("FYI\n\nBegin forwarded message:\n\nFrom: Casey Rivera <casey@example.com>\n\n\(casey.body)") == nil)

        // In a conversation, In-Reply-To names the answered message, and the composer writes the quote this check expects.
        var thread = DemoData.conversations().first { $0.subject == "Dinner on Saturday?" }!
        let first = thread.messages[0]
        let draft = ComposerDraft.make(mode: .reply(thread.id), conversation: thread, message: first.id, accounts: MailAccount.demo)
        var answer = MailMessage(sender: "Morgan", address: "morgan@personal.example.com", to: ["casey@example.com"], date: .now,
                                 body: "Sure." + draft.text, outgoing: true)
        answer.answer(first)
        thread.messages.append(answer)
        assert(thread.quoteStart(of: answer) != nil && thread.quoteStart(of: first) == nil)
        answer.answer(thread.messages[2])
        thread.messages[thread.messages.count - 1] = answer
        assert(thread.quoteStart(of: answer) == nil, "A quote of another message than the answered one stays visible")
    }

    static func checkHTMLDocument() {
        func dark(_ html: String) -> Bool { HTMLDocument(html, remoteContent: false).adaptsToDarkMode }
        assert(dark("<style>@media (prefers-color-scheme: dark) { body { color: #fff } }</style>"))
        assert(dark(#"<meta name="color-scheme" content="light dark">"#) && dark(":root { color-scheme: dark; }"))
        assert(!dark(":root { color-scheme: only light; }") && !dark("<p>Plain</p>"), "Light-only mail keeps its white page")

        func remote(_ html: String) -> Bool { HTMLDocument(html, remoteContent: false).hasRemoteContent }
        assert(remote(#"<img src="https://example.com/a.png">"#) && remote("<div style=\"background:url('//cdn.example.com/b.png')\">"))
        assert(remote(#"<style>@import "https://example.com/mail.css";</style>"#) && remote(#"<link rel="stylesheet" href="https://example.com/s.css">"#))
        assert(remote(#"<td style="background-image:url(&quot;https://example.com/h.jpg&quot;)">"#), "Entity-quoted CSS URLs count")
        assert(!remote(#"<img src="data:image/png;base64,AAAA"><a href="https://example.com">Link</a>"#), "Links and data: images need no Load images")

        let hints = #"<link title="a > b" rel="preconnect" href="https://t.example.com"><LINK\#nhref="https://t.example.com" REL=dns-prefetch/><a rel="nofollow" href="x">&lt;link&gt;</a>"#
        let blocked = HTMLDocument(hints, remoteContent: false).html
        assert(!blocked.lowercased().contains("<link ") && !blocked.lowercased().contains("<link\n"), "No link element survives while blocked")
        assert(blocked.contains(#"<x-link title="a > b" rel="preconnect""#) && blocked.contains("<x-link\nhref"))
        assert(blocked.contains(#"<a rel="nofollow" href="x">&lt;link&gt;</a>"#), "Other elements and escaped text stay")
        assert(HTMLDocument(hints, remoteContent: true).html.hasSuffix(hints), "Loaded remote content keeps the message as sent")
        print("PASS: HTML dark-mode opt-in, remote content detection incl. @import, connection hints disabled while blocked")
    }

    static func checkMessageLinks() {
        let link = MailtoLink(URL(string: "mailto:a@example.com,b@example.com?cc=c@example.com&bcc=d@example.com&subject=Hello%20there&body=Line%201%0ALine+2")!)!
        assert(link.to == ["a@example.com", "b@example.com"] && link.cc == ["c@example.com"] && link.bcc == ["d@example.com"])
        assert(link.subject == "Hello there" && link.body == "Line 1\nLine+2", "RFC 6068 keeps + as written")
        assert(MailtoLink(URL(string: "mailto:?to=x@example.com")!)!.to == ["x@example.com"])
        assert(MailtoLink(URL(string: "https://example.com")!) == nil)

        let accounts = MailAccount.demo
        let draft = ComposerDraft.make(mode: .mailto(link), conversation: nil, accounts: accounts)
        assert(draft.mode == .new && draft.to == "a@example.com, b@example.com" && draft.cc == "c@example.com" && draft.bcc == "d@example.com")
        assert(draft.subject == "Hello there" && draft.text == "Line 1\nLine+2\n\nMorgan", "The body goes above the signature")

        let text = MessageLinks.linked("Read *this* at https://example.com/a, write to help@example.com, or call +1 (555) 010-0199.")
        let links = text.runs.compactMap { run in run.link.map { (String(text[run.range].characters), $0.absoluteString) } }
        assert(links.map(\.1) == ["https://example.com/a", "mailto:help@example.com", "tel:+15550100199"], "\(links)")
        assert(String(text.characters).contains("*this*"), "Plain text is not read as Markdown")
        assert(MessageLinks.linked("Tuesday, 10:00–11:00\nOrder #10428").runs.allSatisfy { $0.link == nil })
        print("PASS: mailto parsing and drafts, web/email/phone links in plain text, no Markdown in plain text")
    }

    @MainActor static func checkMute() throws {
        let directory = URL.temporaryDirectory.appending(path: "mailern-mute-\(UUID())")
        let disk = SQLitePersistence(url: directory.appending(path: "mute.sqlite"))
        let store = MailStore(persistence: disk)
        let settled = store.list(.settled)[0].id
        let snoozed = store.list(.snoozed)[0]
        store.toggleMute(settled)
        store.toggleMute(snoozed.id)
        let trashed = store.list(.inbox)[0].id
        store.toggleMute(trashed)
        store.apply(ids: [trashed], action: .remove(.trash))
        store.receiveReply(settled)
        store.receiveReply(snoozed.id)
        store.receiveReply(trashed)
        assert(store.conversation(trashed)!.removal?.mailbox == .trash)
        // A reply joins a muted thread but leaves it where it was, read, and still snoozed.
        let quiet = store.conversation(settled)!
        assert(quiet.workflow == .settled && !quiet.unread && quiet.latest.body.contains("follow-up"))
        assert(store.conversation(snoozed.id)!.workflow == .snoozed && store.conversation(snoozed.id)!.snoozedUntil == snoozed.snoozedUntil)
        assert(MailStore(persistence: SQLitePersistence(url: disk.url)).conversation(settled)!.muted == true)
        // A reply to a muted thread that waits for one ends the reminder and settles it, so it never returns.
        let inbox = store.list(.inbox).first { $0.id != trashed && $0.messages.contains { !$0.outgoing } }!
        store.toggleMute(inbox.id)
        assert(store.send(threadID: inbox.id, account: store.account(inbox.accountID), to: [inbox.correspondent.address], cc: [],
                          subject: inbox.subject, body: "Any news?", followUp: .now.addingTimeInterval(100)))
        store.receiveReply(inbox.id)
        store.wakeDue(now: .now.addingTimeInterval(101))
        assert(store.conversation(inbox.id)!.workflow == .settled && store.conversation(inbox.id)!.followUp == nil && !store.conversation(inbox.id)!.unread)
        store.toggleMute(settled)
        store.receiveReply(settled)
        assert(store.conversation(settled)!.workflow == .inbox && store.conversation(settled)!.unread)
        print("PASS: muted threads keep replies without moving or turning unread, mute persists, unmute restores delivery")
    }

    @MainActor static func checkFollowUp() throws {
        let directory = URL.temporaryDirectory.appending(path: "mailern-follow-up-\(UUID())")
        let disk = SQLitePersistence(url: directory.appending(path: "follow-up.sqlite"))
        let store = MailStore(persistence: disk)
        let account = store.accounts[0]
        let due = Date.now.addingTimeInterval(100)
        // New mail with a reminder waits in Snoozed, and the reminder survives a reload.
        assert(store.send(threadID: nil, account: account, to: ["sam@example.com"], cc: [], subject: "Quote", body: "Any news?", followUp: due))
        let sent = store.conversations[0].id
        assert(store.conversation(sent)!.workflow == .snoozed && store.conversation(sent)!.snoozedUntil == due)
        let reloaded = MailStore(persistence: SQLitePersistence(url: disk.url))
        assert(reloaded.conversation(sent)!.followUp == .waiting)
        // Nobody replied: it returns to Inbox marked. Settling it clears the mark.
        store.wakeDue(now: due.addingTimeInterval(1))
        assert(store.conversation(sent)!.workflow == .inbox && store.conversation(sent)!.followUp == .noReply)
        store.move(sent, to: .settled)
        assert(store.conversation(sent)!.followUp == nil)
        store.undo()
        assert(store.conversation(sent)!.followUp == .noReply)
        // A reply cancels the reminder and returns the thread as usual.
        let thread = store.list(.inbox).first { $0.id != sent && $0.messages.contains { !$0.outgoing } }!
        assert(store.send(threadID: thread.id, account: store.account(thread.accountID), to: [thread.correspondent.address], cc: [],
                          subject: thread.subject, body: "Following up.", followUp: due))
        assert(store.conversation(thread.id)!.workflow == .snoozed && store.conversation(thread.id)!.followUp == .waiting)
        store.receiveReply(thread.id)
        assert(store.conversation(thread.id)!.workflow == .inbox && store.conversation(thread.id)!.unread && store.conversation(thread.id)!.followUp == nil)
        // Snoozing a waiting thread by hand ends the reminder, so it returns unmarked.
        assert(store.send(threadID: thread.id, account: store.account(thread.accountID), to: [thread.correspondent.address], cc: [],
                          subject: thread.subject, body: "Again.", followUp: due))
        store.move(thread.id, to: .snoozed, until: due.addingTimeInterval(50))
        store.wakeDue(now: due.addingTimeInterval(51))
        assert(store.conversation(thread.id)!.workflow == .inbox && store.conversation(thread.id)!.followUp == nil)
        // Trash and Junk are manual moves too. Undo brings the reminder back.
        for mailbox in RemovedMailbox.allCases {
            assert(store.send(threadID: thread.id, account: store.account(thread.accountID), to: [thread.correspondent.address], cc: [],
                              subject: thread.subject, body: "Moving on.", followUp: due))
            store.apply(ids: [thread.id], action: .remove(mailbox))
            assert(store.conversation(thread.id)!.workflow == .settled && store.conversation(thread.id)!.followUp == nil)
            store.undo()
            assert(store.conversation(thread.id)!.workflow == .snoozed && store.conversation(thread.id)!.followUp == .waiting
                   && store.conversation(thread.id)!.removal == nil)
            store.apply(ids: [thread.id], action: .remove(mailbox))
            store.apply(ids: [thread.id], action: .restoreRemoved)
            store.wakeDue(now: due.addingTimeInterval(1))
            assert(store.conversation(thread.id)!.workflow == .settled && store.conversation(thread.id)!.followUp == nil)
        }
        // A reminder time that already passed settles the mail like a plain send.
        assert(store.send(threadID: nil, account: account, to: ["sam@example.com"], cc: [], subject: "Late", body: "x", followUp: .now.addingTimeInterval(-1)))
        assert(store.conversations[0].workflow == .settled && store.conversations[0].followUp == nil)
        print("PASS: follow-up reminders wait in Snoozed, return marked without a reply, end on reply or a manual move, undo, persistence")
    }

    @MainActor static func checkLocalReminders() async throws {
        let directory = URL.temporaryDirectory.appending(path: "mailern-reminders-\(UUID())")
        let disk = SQLitePersistence(url: directory.appending(path: "mail.sqlite"))
        let mail = MailStore(persistence: disk)
        let url = directory.appending(path: "drafts.json")
        let drafts = DraftStore(url: url)
        let start = Date.now
        let due = start.addingTimeInterval(600)
        let thread = mail.list(.inbox).first { $0.messages.contains { !$0.outgoing } }!
        func reminder() -> MailReminder? {
            MailReminder.plan(mail: mail, drafts: drafts, now: start).first { $0.conversationID == thread.id }
        }
        assert(mail.move(thread.id, to: .snoozed, until: due))
        let original = reminder()!
        let delayed = due.addingTimeInterval(120)
        assert(mail.move(thread.id, to: .snoozed, until: delayed))
        let replacement = reminder()!
        assert(original.id == replacement.id && original.token != replacement.token)
        assert(!MailReminder.act(id: original.id, token: original.token, action: "settle", mail: mail, now: delayed))
        assert(!MailReminder.act(id: replacement.id, token: replacement.token, action: "settle", mail: mail, now: start))
        mail.wakeDue(now: delayed)
        let reopened = MailStore(persistence: disk)
        assert(MailReminder.isActionable(id: replacement.id, token: replacement.token, mail: reopened, now: delayed))
        assert(MailReminder.act(id: replacement.id, token: replacement.token, action: "snooze", mail: mail, now: delayed))
        assert(mail.conversation(thread.id)!.snoozedUntil == delayed.addingTimeInterval(3600))
        assert(!MailReminder.act(id: replacement.id, token: replacement.token, action: "settle", mail: mail, now: delayed))
        let repeated = reminder()!
        mail.receiveReply(thread.id)
        assert(reminder() == nil)
        assert(!MailReminder.act(id: repeated.id, token: repeated.token, action: "settle", mail: mail, now: repeated.date))

        assert(mail.send(threadID: thread.id, account: mail.account(thread.accountID), to: [thread.correspondent.address],
                         cc: [], subject: thread.subject, body: "Following up", followUp: due))
        let followUp = reminder()!
        assert(followUp.title == "No reply yet" && followUp.conversationID == thread.id)
        mail.wakeDue(now: due)
        assert(MailReminder.act(id: followUp.id, token: followUp.token, action: "settle", mail: mail, now: due))
        assert(mail.conversation(thread.id)!.workflow == .settled)
        assert(!MailReminder.isActionable(id: followUp.id, token: followUp.token, mail: mail, now: due))

        let scheduled = ComposerDraft(subject: "File report")
        let undoSend = ComposerDraft(subject: "Already sending")
        let snoozed = ComposerDraft(subject: "Edit later", snoozedUntil: due)
        let savedScheduled = await drafts.schedule(scheduled, at: due)
        let savedUndo = await drafts.schedule(undoSend, at: due, holdingForUndo: true)
        let savedSnooze = await drafts.save(snoozed)
        assert(savedScheduled && savedUndo && savedSnooze)
        let draftPlan = MailReminder.plan(mail: mail, drafts: DraftStore(url: url), now: start)
        assert(draftPlan.contains { $0.id == "scheduled.\(scheduled.id)" && $0.conversationID == nil })
        assert(draftPlan.contains { $0.id == "draft.\(snoozed.id)" && $0.date == due })
        assert(!draftPlan.contains { $0.id == "scheduled.\(undoSend.id)" })
        // A failed reload can leave an old draft snapshot in memory. Mail reminders must still update.
        let badDraftURL = directory.appending(path: "unreadable-drafts.json")
        try FileManager.default.copyItem(at: url, to: badDraftURL)
        let unreadableDrafts = DraftStore(url: badDraftURL)
        try Data("unreadable".utf8).write(to: badDraftURL)
        await unreadableDrafts.reload()
        assert(unreadableDrafts.needsReload && !unreadableDrafts.all.isEmpty)
        await unreadableDrafts.sendDue(through: mail, now: delayed)
        assert(!mail.conversations.contains { $0.messages.contains { $0.id == scheduled.id || $0.id == undoSend.id } })
        assert(mail.move(thread.id, to: .snoozed, until: due))
        let mailOnly = MailReminder.plan(mail: mail, drafts: unreadableDrafts, now: start)
        assert(mailOnly.contains { $0.conversationID == thread.id } && mailOnly.allSatisfy { $0.conversationID != nil })
        let missingMail = SQLitePersistence(url: directory.appending(path: "missing.sqlite"), requiresSeed: true)
        assert(MailReminder.plan(mail: MailStore(persistence: missingMail), drafts: drafts, now: start).isEmpty)
        let rescheduled = await drafts.schedule(scheduled, at: delayed)
        assert(rescheduled)
        assert(MailReminder.plan(mail: mail, drafts: drafts, now: start).first { $0.id == "scheduled.\(scheduled.id)" }?.date == delayed)
        let canceled = await drafts.unschedule(scheduled.id)
        assert(canceled)
        assert(!MailReminder.plan(mail: mail, drafts: drafts, now: start).contains { $0.id == "scheduled.\(scheduled.id)" })
        let many = (0..<150).map { n in
            Conversation(accountID: thread.accountID, subject: "Reminder \(n)", workflow: .snoozed,
                         snoozedUntil: due.addingTimeInterval(Double((149 - n) / 3)), messages: [thread.latest])
        }
        try disk.save(MailData(conversations: many))
        let largeMailbox = MailStore(persistence: disk)
        let limited = MailReminder.plan(mail: largeMailbox, drafts: DraftStore(url: directory.appending(path: "empty.json")), now: start)
        let expected = many.sorted { left, right in
            left.snoozedUntil == right.snoozedUntil ? left.id.uuidString < right.id.uuidString : left.snoozedUntil! < right.snoozedUntil!
        }
        assert(limited.compactMap(\.conversationID) == Array(expected.prefix(64)).map(\.id))
        let badges = MailReminder.badges(for: limited, mail: largeMailbox)
        assert(badges[limited[0].id] == 3 && badges[limited[2].id] == 3)
        assert(badges[limited[63].id] == 66)
        print("PASS: local reminders replace or cancel on mail changes, survive expiry and reload, reject stale actions, and exclude Undo Send")
    }

    @MainActor static func checkOutbox() async throws {
        let directory = URL.temporaryDirectory.appending(path: "mailern-outbox-\(UUID())")
        let mailURL = directory.appending(path: "outbox.sqlite")
        var store = MailStore(persistence: SQLitePersistence(url: mailURL))
        let url = directory.appending(path: "drafts.json")
        var drafts = DraftStore(url: url, mail: store)
        let thread = store.list(.inbox).first { $0.messages.contains { !$0.outgoing } }!
        let start = Date.now
        var later = ComposerDraft.make(mode: .new, conversation: nil, accounts: store.accounts)
        later.to = "sam@example.com"
        later.subject = "Later"
        later.followUp = start.addingTimeInterval(500)
        let scheduledLater = await drafts.schedule(later, at: start.addingTimeInterval(100))
        assert(scheduledLater)
        var reply = ComposerDraft.make(mode: .reply(thread.id), conversation: thread, accounts: store.accounts)
        reply.text = "On my way"
        let scheduledReply = await drafts.schedule(reply, at: start.addingTimeInterval(200))
        assert(scheduledReply)
        // Scheduled mail leaves the draft list, persists, and survives Settle's draft discard.
        assert(drafts.drafts.isEmpty && drafts.outbox.map(\.id) == [later.id, reply.id])
        assert(DraftStore(url: url).outbox.count == 2)
        let discarded = await drafts.discardDrafts(for: [thread.id])
        assert(discarded && drafts.outbox.count == 2)
        await drafts.sendDue(through: store, now: start.addingTimeInterval(99))
        assert(drafts.outbox.count == 2 && !store.conversations.contains { $0.subject == "Later" })
        // Reject the receipt write after SQLite has staged the sent message.
        var db: OpaquePointer?
        assert(sqlite3_open(mailURL.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        let abortReceipt = "CREATE TRIGGER reject_receipt BEFORE INSERT ON settings WHEN NEW.key = 'discardedDraftIDs' BEGIN SELECT RAISE(ABORT, 'receipt unavailable'); END"
        assert(sqlite3_exec(db, abortReceipt, nil, nil, nil) == SQLITE_OK)
        let failing = DraftStore(url: url, mail: store, write: { _, _ in throw CocoaError(.fileWriteOutOfSpace) })
        let rejected = await failing.sendNow(later.id, through: store)
        assert(!rejected && store.discardedDraftIDs.isEmpty && failing.outbox.count == 2)
        let rolledBack = MailStore(persistence: SQLitePersistence(url: mailURL))
        assert(rolledBack.discardedDraftIDs.isEmpty && !rolledBack.conversations.contains { $0.subject == later.subject })
        assert(sqlite3_exec(db, "DROP TRIGGER reject_receipt", nil, nil, nil) == SQLITE_OK)

        // Send Now commits, but the draft manifest still contains the scheduled copy.
        let cleanupFailed = await failing.sendNow(later.id, through: store)
        assert(!cleanupFailed && failing.outbox.map(\.id) == [reply.id])
        assert(store.discardedDraftIDs == [later.id] && DraftStore(url: url).outbox.count == 2)
        let sent = store.conversations.first { $0.subject == later.subject }!
        assert(sent.messages.map(\.id) == [later.id] && sent.workflow == .snoozed && sent.followUp == .waiting)
        let remindersAfterSend = MailReminder.plan(mail: store, drafts: failing, now: start)
        assert(!remindersAfterSend.contains { $0.id == "scheduled.\(later.id)" })
        assert(remindersAfterSend.contains { $0.id == "scheduled.\(reply.id)" })
        assert(store.apply(ids: [sent.id], action: .remove(.trash)))
        assert(store.deletePermanently([sent.id], from: .trash))
        store = MailStore(persistence: SQLitePersistence(url: mailURL))
        assert(store.discardedDraftIDs == [later.id])
        drafts = DraftStore(url: url, mail: store)
        assert(drafts.outbox.map(\.id) == [reply.id])
        await drafts.sendDue(through: store, now: start.addingTimeInterval(101))
        await drafts.recoverAfterMailLoad()
        assert(store.discardedDraftIDs.isEmpty && DraftStore(url: url).outbox.map(\.id) == [reply.id])
        assert(!store.conversations.contains { $0.messages.contains { $0.id == later.id } })
        let recovered = MailStore(persistence: SQLitePersistence(url: mailURL))
        assert(recovered.discardedDraftIDs.isEmpty && recovered.conversations == store.conversations)
        // Send Now skips the wait. Taking back mail that already went out fails.
        let sentNow = await drafts.sendNow(reply.id, through: store)
        assert(sentNow)
        assert(drafts.outbox.isEmpty && store.conversation(thread.id)!.latest.id == reply.id && store.conversation(thread.id)!.workflow == .settled)
        let tookBackSent = await drafts.unschedule(reply.id)
        assert(tookBackSent == false)
        // Unschedule returns mail to Drafts. Edit also asks for the composer.
        var undo = later
        undo.id = UUID()
        let scheduledUndo = await drafts.schedule(undo, at: .now.addingTimeInterval(10))
        assert(scheduledUndo)
        drafts.undoable = undo.id
        await drafts.edit(undo.id)
        assert(drafts.reopening == undo.id && drafts.undoable == nil && drafts.drafts.map(\.id) == [undo.id])
        // Mail the store refuses goes back to Drafts with an explanation.
        var orphan = reply
        orphan.id = UUID()
        orphan.mode = .reply(UUID())
        let scheduledOrphan = await drafts.schedule(orphan, at: start)
        assert(scheduledOrphan)
        await drafts.sendDue(through: store)
        assert(drafts.outbox.isEmpty && drafts.drafts.contains { $0.id == orphan.id } && store.error?.contains("back in Drafts") == true)
        store.error = nil
        // Deleting a conversation discards its scheduled replies too.
        var pending = reply
        pending.id = UUID()
        let scheduledPending = await drafts.schedule(pending, at: start.addingTimeInterval(900))
        assert(scheduledPending)
        let discardedWithThread = await drafts.discardDrafts(for: [thread.id], scheduled: true)
        assert(discardedWithThread && drafts.outbox.isEmpty)
        print("PASS: outbox scheduling, persistence, due delivery, no duplicate after a failed draft write, reminders on send, send now, edit/unschedule, refused mail back in Drafts, discard with deleted conversation")
    }

    @MainActor static func checkExistingOutbox() async throws {
        let directory = URL.temporaryDirectory.appending(path: "mailern-existing-outbox-\(UUID())")
        let mailURL = directory.appending(path: "mail.sqlite")
        let draftURL = directory.appending(path: "drafts.json")
        let deadline = Date.now.addingTimeInterval(600)
        let expired = ComposerDraft(subject: "Sent copy expired", sendAt: deadline)
        let kept = ComposerDraft(subject: "Sent copy still present", sendAt: deadline)
        let pending = ComposerDraft(subject: "Waiting for its first send", sendAt: deadline)
        func sentCopy(_ draft: ComposerDraft, removal: Removal? = nil) -> Conversation {
            let message = MailMessage(id: draft.id, sender: "Morgan", address: MailAccount.demo[0].address,
                                      to: ["casey@example.com"], date: .now, body: draft.subject, outgoing: true)
            return Conversation(accountID: draft.accountID, subject: draft.subject, workflow: .settled,
                                unread: false, removal: removal, messages: [message])
        }
        let expiredCopy = sentCopy(expired, removal: .trash(since: deadline.addingTimeInterval(-2 * MailStore.trashRetention)))
        let keptCopy = sentCopy(kept)
        let unrelated = sentCopy(ComposerDraft(subject: "Ordinary old sent mail"))
        // The old version could leave the JSON outbox and the sent messages on disk with no receipts.
        try SQLitePersistence(url: mailURL).save(MailData(conversations: [expiredCopy, keptCopy, unrelated]))
        try AttachmentJSON.save([expired, kept, pending], to: draftURL)
        let first = MailStore(persistence: SQLitePersistence(url: mailURL))
        assert(first.conversation(expiredCopy.id) == nil && first.discardedDraftIDs == [expired.id])
        let drafts = DraftStore(url: draftURL, mail: first)
        assert(drafts.outbox.map(\.id) == [pending.id])
        assert(first.discardedDraftIDs == [expired.id, kept.id])
        assert(first.deletePermanently([keptCopy.id, unrelated.id]))
        assert(first.discardedDraftIDs == [expired.id, kept.id])

        let reopened = MailStore(persistence: SQLitePersistence(url: mailURL))
        let outbox = DraftStore(url: draftURL, mail: reopened)
        await outbox.sendDue(through: reopened, now: deadline)
        assert(reopened.conversations.flatMap(\.messages).map(\.id) == [pending.id])
        assert(reopened.discardedDraftIDs.isEmpty && DraftStore(url: draftURL).outbox.isEmpty)

        try AttachmentJSON.save([pending], to: draftURL)
        await outbox.reload()
        assert(outbox.outbox.isEmpty && DraftStore(url: draftURL).outbox.isEmpty)
        let retryURL = directory.appending(path: "retry.sqlite")
        try SQLitePersistence(url: retryURL).save(MailData(conversations: [keptCopy]))
        try AttachmentJSON.save([kept, pending], to: draftURL)
        let retryMail = MailStore(persistence: SQLitePersistence(url: retryURL))
        var db: OpaquePointer?
        assert(sqlite3_open(retryURL.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        let reject = "CREATE TRIGGER reject_receipt BEFORE INSERT ON settings WHEN NEW.key = 'discardedDraftIDs' BEGIN SELECT RAISE(ABORT, 'busy'); END"
        assert(sqlite3_exec(db, reject, nil, nil, nil) == SQLITE_OK)
        let retryDrafts = DraftStore(url: draftURL, mail: retryMail)
        assert(!retryDrafts.hasReadableManifest)
        await retryDrafts.recoverAfterMailLoad(now: deadline)
        assert(sqlite3_exec(db, "DROP TRIGGER reject_receipt", nil, nil, nil) == SQLITE_OK)
        await retryDrafts.recoverAfterMailLoad(now: deadline.addingTimeInterval(1))
        assert(!retryDrafts.hasReadableManifest)
        assert(retryDrafts.error != nil)
        retryDrafts.error = nil
        let manifest = try Data(contentsOf: draftURL)
        try Data("unreadable manifest".utf8).write(to: draftURL)
        await retryDrafts.recoverAfterMailLoad(now: deadline.addingTimeInterval(30))
        assert(!retryDrafts.hasReadableManifest && retryDrafts.error == nil && retryMail.error == nil)
        try manifest.write(to: draftURL)
        await retryDrafts.recoverAfterMailLoad(now: deadline.addingTimeInterval(31))
        assert(!retryDrafts.hasReadableManifest)
        await retryDrafts.recoverAfterMailLoad(now: deadline.addingTimeInterval(60))
        assert(retryDrafts.outbox.map(\.id) == [pending.id])
        await retryDrafts.sendDue(through: retryMail, now: deadline.addingTimeInterval(60))
        assert(retryMail.conversations.flatMap(\.messages).map(\.id).sorted { $0.uuidString < $1.uuidString } == [kept.id, pending.id].sorted { $0.uuidString < $1.uuidString })
        assert(retryDrafts.outbox.isEmpty)
        try Data("unreadable at startup".utf8).write(to: draftURL)
        let cold = DraftStore(url: draftURL, mail: retryMail)
        assert(!cold.hasReadableManifest && cold.error != nil)
        cold.error = nil
        await cold.recoverAfterMailLoad(now: deadline)
        var another = pending
        another.id = UUID()
        try AttachmentJSON.save([another], to: draftURL)
        await cold.recoverAfterMailLoad(now: deadline.addingTimeInterval(1))
        assert(!cold.hasReadableManifest && cold.error == nil)
        await cold.recoverAfterMailLoad(now: deadline.addingTimeInterval(30))
        await cold.sendDue(through: retryMail, now: deadline.addingTimeInterval(30))
        assert(cold.hasReadableManifest && cold.outbox.isEmpty)
        assert(retryMail.conversations.flatMap(\.messages).filter { $0.id == another.id }.count == 1)
        try AttachmentJSON.save([another], to: draftURL)
        let blockedCleanup = DraftStore(url: draftURL, mail: retryMail) { _, _ in throw CocoaError(.fileWriteOutOfSpace) }
        await blockedCleanup.recoverAfterMailLoad(now: deadline)
        assert(blockedCleanup.error != nil)
        blockedCleanup.error = nil
        await blockedCleanup.recoverAfterMailLoad(now: deadline.addingTimeInterval(30))
        assert(blockedCleanup.error == nil && blockedCleanup.outbox.isEmpty && retryMail.discardedDraftIDs == [another.id])
        print("PASS: existing outbox reconciles before sent mail deletion and survives startup Trash expiry without redelivery")
    }

    @MainActor static func checkTrashAndJunk() throws {
        let disk = SQLitePersistence(url: URL.temporaryDirectory.appending(path: "mailern-trash-\(UUID())/mail.sqlite"))
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
        store.apply(ids: [settled], action: .remove(.trash))
        store.apply(ids: [settled], action: .restoreRemoved)
        store.clearWorkflowUndo(involving: [settled])
        store.undo()
        assert(store.conversation(settled)!.removal == nil, "A reply draft saved after Restore cancels its Undo")
        store.apply(ids: [settled], action: .remove(.trash))
        store.receiveReply(settled)
        let rescued = store.conversation(settled)!
        assert(rescued.removal == nil && rescued.workflow == .inbox && rescued.unread)

        let spam = store.list(.inbox)[0]
        store.apply(ids: [spam.id], action: .remove(.junk))
        assert(store.blockedSenders.isEmpty && store.list(.junk).map(\.id) == [spam.id])
        store.undo()
        assert(store.blockedSenders.isEmpty && store.conversation(spam.id)!.removal == nil)
        store.apply(ids: [spam.id], action: .remove(.junk))
        store.receiveReply(spam.id)
        assert(store.conversation(spam.id)!.removal == .junk && store.conversation(spam.id)!.unread)
        store.apply(ids: [spam.id], action: .restoreRemoved)
        assert(store.blockedSenders.isEmpty && store.list(.inbox).contains { $0.id == spam.id })

        store.deletePermanently([spam.id])
        assert(store.conversation(spam.id) == nil)
        let reloaded = MailStore(persistence: disk)
        reloaded.receiveJunk()
        assert(reloaded.blockedSenders.isEmpty && reloaded.list(.junk).contains { $0.subject == "You have been selected" })

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
        print("PASS: Trash and Junk lists, restore to original workflow, Undo, draft cancels Restore Undo, reply rescues Trash, 30-day purge, permanent deletion, reset")
    }

    static func checkBenchmarkMailbox() throws {
        for size in BenchmarkMailbox.allCases {
            let mail = size.makeMail(now: .distantPast)
            let conversations = mail.conversations
            assert(conversations.count == size.rawValue)
            assert(Set(conversations.map(\.id)).count == size.rawValue)
            assert(Set(conversations.map(\.accountID)) == Set(mail.accounts.map(\.id)))
            assert(conversations.contains { $0.workflow == .inbox && $0.messages.count == 16 && $0.latest.html != nil })
            assert(conversations.contains { $0.workflow == .settled && $0.messages.count == 16 && $0.latest.html != nil })
            for length in [1, 3, 6, 16] {
                let paragraphCounts = Set(conversations.lazy.filter { $0.messages.count == length }.flatMap(\.messages)
                    .filter { $0.html != nil }.map { $0.body.components(separatedBy: "\n\n").count })
                assert(Set(2...5).isSubset(of: paragraphCounts))
            }
            assert(conversations.filter { $0.workflow == .inbox }.count == size.rawValue - size.rawValue / 7)
            assert(conversations.filter { $0.searchText.contains("larchdelta") }.count == 1)
            let bodyHits = conversations.filter { $0.searchText.contains("handover notes") }.count
            assert(bodyHits > size.rawValue / 5 && bodyHits < size.rawValue)
            assert(conversations.first?.subject == "Weekly report · Sample 1")
        }

        let directory = URL.temporaryDirectory.appending(path: "mailern-benchmark-\(UUID())")
        let benchmark = SQLitePersistence(url: directory.appending(path: "Benchmark/mail.sqlite"), requiresSeed: true)
        let baseline = MailData(conversations: DemoData.conversations())
        let normal = SQLitePersistence(url: directory.appending(path: "mail.sqlite"))
        try normal.save(baseline)
        // Opening an empty SQLite file before the seed simulates an interrupted first write.
        let empty = try benchmark.search("sample")
        assert(empty == [])
        do {
            _ = try benchmark.load()
            assertionFailure("A selected benchmark without a committed fixture must not load as ordinary demo mail")
        } catch {}
        var fixture = MailData(conversations: Array(baseline.conversations.prefix(1)))
        try benchmark.seedIfNeeded { fixture }
        fixture.conversations = []
        try benchmark.seedIfNeeded { fixture }
        let loaded = try benchmark.load()
        let untouched = try normal.load()
        assert(loaded?.conversations == Array(baseline.conversations.prefix(1)))
        assert(untouched == baseline)
        var db: OpaquePointer?
        assert(sqlite3_open(benchmark.url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        assert(sqlite3_exec(db, "DELETE FROM settings WHERE key = 'accounts'", nil, nil, nil) == SQLITE_OK)
        do {
            try benchmark.seedIfNeeded { fixture }
            assertionFailure("A fixture missing its accounts must not overwrite the mail it already contains")
        } catch {}
        let retained = try benchmark.search("Course project feedback")
        assert(retained == [baseline.conversations[0].id])
        print("PASS: both benchmark sizes, thread and HTML mix, distinct search match counts, seed recovery, and isolated SQLite storage")
    }

    @MainActor static func checkSenderBlocking() throws {
        let url = URL.temporaryDirectory.appending(path: "mailern-blocked-\(UUID())/mail.sqlite")
        let disk = SQLitePersistence(url: url)
        let account = MailAccount.demo[0]
        let first = MailMessage(sender: "Alex", address: "alex@example.com", to: [account.address],
                                date: .distantPast, body: "First", subject: "Project update")
        var second = MailMessage(sender: "Casey", address: "casey@example.com", to: [account.address],
                                 date: .now, body: "Second", subject: first.subject)
        second.answer(first)
        try disk.save(MailData(conversations: [Conversation(accountID: account.id, subject: first.subject!, messages: [first, second])]))
        let store = MailStore(persistence: disk)
        let thread = store.conversations[0].id
        store.apply(ids: [thread], action: .remove(.junk))
        assert(store.blockedSenders.isEmpty, "Moving a group thread to Junk must not block either sender")
        store.setSenderBlocked(true, address: "ALEX@example.com")
        store.undo()
        assert(store.conversation(thread)?.removal == nil && store.blockedSenders == [first.address])
        store.apply(ids: [thread], action: .remove(.junk))
        store.apply(ids: [thread], action: .restoreRemoved)
        assert(store.isSenderBlocked(first.address), "Not Junk must not unblock a sender")

        var blockedReply = first
        blockedReply.id = UUID()
        blockedReply.date = .now
        blockedReply.answer(second)
        store.receive(blockedReply, accountID: account.id)
        let junk = store.list(.junk)
        assert(junk.map(\.messages) == [[blockedReply]], "Only the blocked reply goes to Junk")
        assert(store.conversation(thread)?.messages == [first, second])

        let loaded = store.reload()
        assert(loaded)
        let splitID = junk[0].id
        var anotherBlockedReply = blockedReply
        anotherBlockedReply.id = UUID()
        anotherBlockedReply.date = blockedReply.date.addingTimeInterval(30)
        store.apply(ids: [thread], action: .remove(.junk))
        store.receive(anotherBlockedReply, accountID: account.id)
        assert(store.conversation(splitID)?.messages == [blockedReply, anotherBlockedReply],
               "Blocked replies reuse the split after reload and after the original moves to Junk")
        store.apply(ids: [thread], action: .restoreRemoved)

        var otherReply = second
        otherReply.id = UUID()
        otherReply.date = .now.addingTimeInterval(60)
        otherReply.answer(blockedReply)
        otherReply.references = nil
        store.receive(otherReply, accountID: account.id)
        assert(store.conversation(thread)?.messages == [first, second, otherReply])

        let sent = MailMessage(sender: account.name, address: account.address, to: [first.address.uppercased()],
                               date: otherReply.date.addingTimeInterval(60), body: "Outgoing", outgoing: true, subject: "Sent to Alex")
        store.receive(sent, accountID: account.id)
        assert(store.conversations(with: first.address.uppercased()).map(\.subject) == ["Sent to Alex", "Project update", "Project update"])
        assert(store.conversations(with: second.address).map(\.id) == [thread])

        store.apply(ids: [splitID], action: .restoreRemoved)
        store.undo()
        assert(store.conversation(splitID)?.blockedReplySourceID == thread, "Undo restores the Junk split's link to its source")
        store.apply(ids: [splitID], action: .restoreRemoved)
        store.apply(ids: [thread], action: .remove(.trash))
        var directReply = otherReply
        directReply.id = UUID()
        directReply.answer(otherReply)
        directReply.references = [blockedReply.threadingID, otherReply.threadingID]
        store.receive(directReply, accountID: account.id)
        assert(store.conversation(thread)?.latest == directReply && store.conversation(thread)?.removal == nil,
               "A restored split must not take replies addressed to the original conversation")
        assert(store.conversation(splitID)?.messages == [blockedReply, anotherBlockedReply])

        store.apply(ids: [thread], action: .remove(.trash))
        var referencesOnly = directReply
        referencesOnly.id = UUID()
        referencesOnly.inReplyTo = nil
        store.receive(referencesOnly, accountID: account.id)
        assert(store.conversation(thread)?.latest == referencesOnly && store.conversation(thread)?.removal == nil,
               "A reply without In-Reply-To follows its newest known reference")

        store.apply(ids: [splitID], action: .remove(.junk))
        var replyToJunk = otherReply
        replyToJunk.id = UUID()
        replyToJunk.answer(anotherBlockedReply)
        store.receive(replyToJunk, accountID: account.id)
        assert(store.conversation(splitID)?.latest == replyToJunk && store.conversation(splitID)?.removal == .junk,
               "A restored split that was manually moved to Junk keeps its replies")

        store.deletePermanently([splitID])
        let reopened = MailStore(persistence: disk)
        assert(reopened.isSenderBlocked(first.address), "A block must survive deleting its Junk and relaunching")
        var lock: OpaquePointer?
        assert(sqlite3_open(url.path, &lock) == SQLITE_OK && sqlite3_exec(lock, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK)
        let failedUnblock = !reopened.setSenderBlocked(false, address: first.address)
        sqlite3_exec(lock, "ROLLBACK", nil, nil, nil)
        sqlite3_close(lock)
        assert(failedUnblock && reopened.isSenderBlocked(first.address) && reopened.error != nil)
        assert(MailStore(persistence: disk).isSenderBlocked(first.address))
        let saved = reopened.setSenderBlocked(false, address: first.address.uppercased())
        assert(saved)
        let unblocked = MailStore(persistence: disk)
        unblocked.receive(blockedReply, accountID: account.id)
        assert(unblocked.blockedSenders.isEmpty && unblocked.list(.junk).isEmpty)
        assert(unblocked.conversation(thread)?.latest == blockedReply)

        unblocked.setSenderBlocked(true, address: first.address)
        unblocked.receive(anotherBlockedReply, accountID: account.id)
        let survivingSplit = unblocked.list(.junk)[0].id
        unblocked.deletePermanently([thread])
        unblocked.receive(replyToJunk, accountID: account.id)
        assert(unblocked.conversation(survivingSplit)?.latest == replyToJunk, "Replies keep their parent if the original was deleted")
        print("PASS: Junk and Undo are independent of blocks, blocked replies share a split, unblocked replies keep their thread through restore, sender history includes sent mail, and blocks persist through write failure")
    }

    @MainActor static func checkUndoExpiry() async throws {
        let disk = SQLitePersistence(url: URL.temporaryDirectory.appending(path: "mailern-undo-\(UUID())/mail.sqlite"))
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
        let disk = SQLitePersistence(url: URL.temporaryDirectory.appending(path: "mailern-settled-\(UUID())/mail.sqlite"))
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
        assert(store.send(threadID: first, account: store.account(source.accountID), to: [source.correspondent.address], cc: [], subject: source.subject, body: "Reply"))
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
        let disk = SQLitePersistence(url: directory.appending(path: "mail.sqlite"))
        let mail = MailStore(persistence: disk)
        let draftsURL = directory.appending(path: "drafts.json")
        let drafts = DraftStore(url: draftsURL)
        let source = mail.list(.inbox).first { !$0.pinned }!
        mail.move(source.id, to: .snoozed, until: .now.addingTimeInterval(3600))
        var reply = ComposerDraft.make(mode: .replyAll(source.id), conversation: source, accounts: MailAccount.demo)
        reply.text = "Unsent reply search proof"
        reply.updatedAt = .now.addingTimeInterval(10)
        let new = ComposerDraft(to: "new@example.com", subject: "Standalone draft", text: "New message")
        let forward = ComposerDraft.make(mode: .forward(source.id), conversation: source, accounts: MailAccount.demo)
        let orphan = ComposerDraft(mode: .reply(UUID()), subject: "Missing source")
        for draft in [reply, new, forward, orphan] { let saved = await drafts.save(draft); assert(saved) }
        func items(_ status: Workflow, search: String = "") -> [MailboxItem] {
            MailboxItem.list(conversations: mail.conversations, drafts: DraftStore(url: draftsURL).drafts, status: status, search: mail.search(search))
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
        assert(mail.send(threadID: source.id, account: mail.account(source.accountID), to: [reply.to], cc: [], subject: reply.subject, body: reply.text))
        let sent = await drafts.delete(reply.id)
        assert(sent && !items(.inbox).contains { $0.id == source.id } && items(.settled).contains { $0.id == source.id && !$0.hasDraft })
        assert(mail.send(threadID: nil, account: mail.account(new.accountID), to: [new.to], cc: [], subject: new.subject, body: new.text))
        let newSent = await drafts.delete(new.id)
        assert(newSent && !items(.inbox).contains { $0.id == new.id })
        assert(items(.settled).contains { $0.conversation?.subject == new.subject && !$0.hasDraft })
        assert(MailStore(persistence: disk).conversations == mail.conversations)
        print("PASS: persisted drafts stay with their conversation, standalone new/forward/orphan drafts, draft search, discard preserves section, and sent drafts settle")
    }

    @MainActor static func mailboxLoadFailurePreservesStoredMail() async throws {
        let directory = URL.temporaryDirectory.appending(path: "mail-load-failure-\(UUID())")
        let url = directory.appending(path: "mail.sqlite")
        let file = MailAttachment(name: "Keep.txt", data: Data("Keep this attachment".utf8), contentType: "public.plain-text")
        var original = DemoData.conversations()
        original[0].messages[0].attachments = [file]
        try SQLitePersistence(url: url).save(MailData(conversations: original))
        let payload = AttachmentJSON.directory(for: url).appending(path: file.id.uuidString)
        let withheld = directory.appending(path: "withheld-payload")
        try FileManager.default.moveItem(at: payload, to: withheld)
        let draftURL = directory.appending(path: "drafts.json")
        let queued = ComposerDraft(text: "Saved during a previous session")
        try AttachmentJSON.save([queued], to: draftURL)
        let store = MailStore(persistence: SQLitePersistence(url: url))
        let drafts = DraftStore(url: draftURL, mail: store)
        await drafts.recoverAfterMailLoad()
        assert(drafts.needsReload && drafts.all.isEmpty)
        assert(store.error != nil && store.conversations.isEmpty)
        store.error = nil
        assert(!store.send(threadID: nil, account: MailAccount.demo[0], to: ["recipient@example.com"], cc: [], subject: "New", body: "New"))
        store.receiveNew()
        assert(!store.deleteAccount(MailAccount.demo[1].id) && !store.saveAccount(MailAccount.demo[1]))
        assert(store.conversations.isEmpty)
        assert(!store.reload())
        try FileManager.default.moveItem(at: withheld, to: payload)
        // An exact match proves that none of the blocked actions wrote to the database.
        assert(store.reload() && store.conversations == original && store.accounts == MailAccount.demo)
        await drafts.recoverAfterMailLoad()
        assert(!drafts.needsReload && drafts.all == [queued])
        assert(store.send(threadID: nil, account: MailAccount.demo[0], to: ["recipient@example.com"], cc: [], subject: "Recovered", body: "Recovered"))
        assert(Set(original.map(\.id)).isSubset(of: Set(MailStore(persistence: SQLitePersistence(url: url)).conversations.map(\.id))))
        print("PASS: failed mailbox load preserves metadata and attachments despite new-mail actions")
    }
    @MainActor static func checkComposerData() async throws {
        let dir = URL.temporaryDirectory.appending(path: "mailern-composer-\(UUID())")
        let disk = SQLitePersistence(url: dir.appending(path: "mail.sqlite"))
        let store = MailStore(persistence: disk)
        let source = store.list(.inbox).first { $0.subject == "Course project feedback" }!
        let reply = ComposerDraft.make(mode: .replyAll(source.id), conversation: source, accounts: MailAccount.demo)
        assert(reply.to == source.correspondent.address)
        assert(ComposerDraft.addresses(reply.cc) == ["coordinator@college.example.com"])
        assert(reply.subject == "Re: \(source.subject)" && reply.text.contains(source.latest.body))
        let revised = MailStore(persistence: SQLitePersistence(url: dir.appending(path: "revised-recipients.sqlite")))
        let revisedID = revised.list(.inbox).first { $0.subject == source.subject }!.id
        assert(revised.send(threadID: revisedID, account: revised.account(source.accountID), to: ["revised@example.com"],
                            cc: ["team@example.com", revised.account(source.accountID).address, "REVISED@example.com"],
                            subject: source.subject, body: "Revised recipient group"))
        let revisedSource = revised.conversation(revisedID)!
        let revisedReply = ComposerDraft.make(mode: .replyAll(revisedID), conversation: revisedSource, accounts: MailAccount.demo)
        assert(revisedReply.to == "revised@example.com" && revisedReply.cc == "team@example.com")
        assert(revisedReply.text.contains("Revised recipient group") && !revisedReply.text.contains(source.latest.body))
        // A reply or forward can target an earlier message instead of the latest.
        let first = revisedSource.messages[0]
        let earlierReply = ComposerDraft.make(mode: .replyAll(revisedID), conversation: revisedSource, message: first.id, accounts: MailAccount.demo)
        assert(earlierReply.to == first.address && ComposerDraft.addresses(earlierReply.cc) == ["coordinator@college.example.com"])
        assert(earlierReply.text.contains(first.body) && !earlierReply.text.contains("Revised recipient group"))
        assert(earlierReply.messageID == first.id && revisedReply.messageID == nil)
        let earlierForward = ComposerDraft.make(mode: .forward(revisedID), conversation: revisedSource, message: first.id, accounts: MailAccount.demo)
        assert(earlierForward.text.contains(first.body) && !earlierForward.text.contains("Revised recipient group"))
        assert(ComposerDraft.make(mode: .reply(revisedID), conversation: revisedSource, message: UUID(), accounts: MailAccount.demo).text.contains("Revised recipient group"))
        assert(revisedSource.participants == "Dr. Jordan Lee, Me" && revisedSource.avatarName == "Dr. Jordan Lee")
        revised.send(threadID: nil, account: revised.account(source.accountID), to: ["new@example.com", "other@example.com"], cc: [], subject: "Sent only", body: "Hello")
        var namesakes = revisedSource
        namesakes.receive(MailMessage(sender: "Dr. Jordan Lee", address: "other@example.com", to: [], date: .now, body: "A namesake"))
        namesakes.receive(MailMessage(sender: "Jordan", address: "JORDAN@college.example.com", to: [], date: .now, body: "A new display name"))
        assert(namesakes.participants == "Dr. Jordan Lee, Me, Dr. Jordan Lee")
        let sentOnly = revised.conversations.first { $0.subject == "Sent only" }!
        assert(sentOnly.participants == "To: new@example.com, other@example.com" && sentOnly.avatarName == "new@example.com")
        let singleReply = ComposerDraft.make(mode: .reply(revisedID), conversation: revisedSource, accounts: MailAccount.demo)
        assert(singleReply.to == "revised@example.com" && singleReply.cc.isEmpty)
        var draft = ComposerDraft.make(mode: .new, conversation: nil, accounts: MailAccount.demo)
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
        assert(store.send(threadID: source.id, account: store.account(source.accountID), to: [reply.to], cc: ComposerDraft.addresses(reply.cc),
                          subject: "Updated project scope", body: draft.text, bcc: ComposerDraft.addresses(draft.bcc), richText: draft.richText, attachments: draft.attachments))
        let sent = store.conversation(source.id)!
        assert(sent.workflow == .settled && sent.latest.outgoing)
        assert(sent.subject == source.subject && sent.latest.subject == "Updated project scope")
        assert(store.list(.settled, search: "Updated project scope").contains { $0.id == source.id })
        assert(sent.latest.bcc == ["hidden@example.com"] && sent.latest.richText == draft.richText && sent.latest.attachments == draft.attachments)
        let forward = ComposerDraft.make(mode: .forward(source.id), conversation: sent, accounts: MailAccount.demo)
        // Forwarding an earlier message takes that message's attachments, not the latest ones.
        assert(ComposerDraft.make(mode: .forward(source.id), conversation: sent, message: sent.messages[0].id, accounts: MailAccount.demo).attachments.isEmpty)
        assert(forward.mode.replyID == nil && forward.attachments == draft.attachments && forward.to.isEmpty)
        assert(MailStore(persistence: disk).conversation(source.id) == sent)
        store.receiveReply(source.id)
        let reactivated = store.conversation(source.id)!
        assert(reactivated.latest.subject == "Updated project scope")
        assert(ComposerDraft.make(mode: .reply(source.id), conversation: reactivated, accounts: MailAccount.demo).subject == "Re: Updated project scope")
        assert(ComposerDraft.make(mode: .forward(source.id), conversation: reactivated, accounts: MailAccount.demo).subject == "Fwd: Updated project scope")
        // An earlier message keeps the subject it was written under.
        let original = reactivated.messages[0].id
        assert(ComposerDraft.make(mode: .forward(source.id), conversation: reactivated, message: original, accounts: MailAccount.demo).subject == "Fwd: \(source.subject)")
        assert(ComposerDraft.make(mode: .reply(source.id), conversation: reactivated, message: original, accounts: MailAccount.demo).subject == "Re: \(source.subject)")
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
        assert(!failing.send(threadID: nil, account: failing.account(source.accountID), to: ["test@example.com"], cc: [], subject: "Failure", body: "Retain draft"))
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
        assert(!recoverable.send(threadID: nil, account: recoverable.account(source.accountID), to: ["test@example.com"], cc: [], subject: "Failure", body: "Keep Undo"))
        assert(recoverable.notice == notice)
        controlled.fail = false
        recoverable.undo()
        assert(recoverable.conversation(recoveryID)!.workflow == .inbox)
        recoverable.move(recoveryID, to: .settled)
        assert(recoverable.send(threadID: nil, account: recoverable.account(source.accountID), to: ["test@example.com"], cc: [], subject: "Success", body: "Invalidate Undo"))
        recoverable.undo()
        assert(recoverable.notice == nil && recoverable.conversation(recoveryID)!.workflow == .settled)
        assert(!store.send(threadID: UUID(), account: store.account(source.accountID), to: ["test@example.com"], cc: [], subject: "Missing source", body: "Retain draft"))
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
        let mail = MailStore(persistence: SQLitePersistence(url: url.deletingLastPathComponent().appending(path: "mail.sqlite")))
        var due = ComposerDraft(subject: "Queued foreground send")
        due.to = "sam@example.com"
        let deadline = Date.now.addingTimeInterval(60)
        let scheduled = await DraftStore(url: url).schedule(due, at: deadline)
        assert(scheduled)
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
        var active = true
        var startedSending = false
        let automatic = Task {
            startedSending = true
            await store.sendDue(through: mail, now: deadline, whileActive: { active })
        }
        while !startedSending { await Task.yield() }
        active = false
        let savingSecond = Task { await store.save(second) }
        savingFirst.cancel()
        var deleteStarted = false
        let deletingFirst = Task {
            deleteStarted = true
            return await store.delete(first.id)
        }
        while !deleteStarted { await Task.yield() }
        var drainStarted = false
        var drainFinished = false
        let drained = Task {
            drainStarted = true
            await store.finishPendingWrites()
            drainFinished = true
            return DraftStore(url: url).drafts.map(\.id)
        }
        while !drainStarted { await Task.yield() }
        assert(!drainFinished, "A new store must wait for the outgoing writer")
        gate.release.signal()
        let reopened = await drained.value
        let firstSaved = await savingFirst.value
        let secondSaved = await savingSecond.value
        let deleted = await deletingFirst.value
        assert(firstSaved && secondSaved && deleted)
        assert(store.drafts.map(\.id) == [second.id])
        assert(reopened == [second.id] && DraftStore(url: url).drafts.map(\.id) == [second.id])
        await automatic.value
        assert(store.outbox.map(\.id) == [due.id] && !mail.conversations.contains { $0.subject == due.subject })
        active = true
        await store.sendDue(through: mail, now: deadline, whileActive: { active })
        assert(store.outbox.isEmpty && mail.conversations.filter { $0.subject == due.subject }.count == 1)
        print("PASS: background writes, cancelled-save completion, cross-draft ordering, deletion, and reopening after a drain")
    }

    @MainActor static func checkAttachmentStorage() async throws {
        let directory = URL.temporaryDirectory.appending(path: "mailern-attachment-files-\(UUID())")
        let draftURL = directory.appending(path: "drafts.json")
        let mailURL = directory.appending(path: "mail.sqlite")
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
        let mail = MailStore(persistence: SQLitePersistence(url: mailURL))
        assert(mail.send(threadID: nil, account: MailAccount.demo[0], to: ["recipient@example.com"], cc: [],
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
        // The 1 MB payload stays in its own file; the database holds only metadata.
        let databaseSize = try ["", "-wal"].reduce(0) { total, suffix in
            let file = URL(fileURLWithPath: mailURL.path + suffix)
            return total + (FileManager.default.fileExists(atPath: file.path) ? try Data(contentsOf: file).count : 0)
        }
        let savedDate = try mailFile.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        assert(databaseSize < 512 * 1024 && savedDate == originalDate)
        assert(MailStore(persistence: SQLitePersistence(url: mailURL)).conversation(sent)!.latest.attachments![0].data == payload)

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

    @MainActor static func checkBulkActions() async throws {
        let url = URL.temporaryDirectory.appending(path: "mailern-bulk-\(UUID())/mail.sqlite")
        let disk = SQLitePersistence(url: url)
        let store = MailStore(persistence: disk)
        let ids = Set(store.list(.inbox).prefix(2).map(\.id))
        let first = ids.first!
        store.markRead(first)
        let before = store.conversations.filter { ids.contains($0.id) }
        var db: OpaquePointer?
        assert(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        let rejectSecond = """
            CREATE TRIGGER reject_second BEFORE UPDATE ON conversations WHEN OLD.id = '\(before[1].id.uuidString)'
            BEGIN SELECT RAISE(ABORT, 'injected failure'); END
            """
        assert(sqlite3_exec(db, rejectSecond, nil, nil, nil) == SQLITE_OK)
        store.apply(ids: ids, action: .move(.settled))
        let afterFailure = MailStore(persistence: SQLitePersistence(url: url))
        assert(store.error != nil && afterFailure.conversations.filter { ids.contains($0.id) } == before)
        assert(sqlite3_exec(db, "DROP TRIGGER reject_second", nil, nil, nil) == SQLITE_OK)
        assert(afterFailure.conversations == store.conversations && store.notice == nil)
        // Reject any UPDATE to an already-pinned row in a mixed batch, including Undo.
        let pinnedID = before[1].id
        store.apply(ids: [pinnedID], action: .pin(true))
        store.apply(ids: [before[0].id], action: .pin(false))
        assert(sqlite3_exec(db, rejectSecond, nil, nil, nil) == SQLITE_OK)
        store.error = nil
        store.apply(ids: ids, action: .pin(true))
        store.undo()
        assert(store.error == nil)
        assert(sqlite3_exec(db, "DROP TRIGGER reject_second", nil, nil, nil) == SQLITE_OK)
        store.apply(ids: ids, action: .move(.settled))
        assert(sqlite3_exec(db, rejectSecond, nil, nil, nil) == SQLITE_OK)
        store.undo()
        assert(store.error != nil && store.notice != nil && ids.allSatisfy { store.conversation($0)?.workflow == .settled })
        assert(MailStore(persistence: SQLitePersistence(url: url)).conversations == store.conversations)
        assert(sqlite3_exec(db, "DROP TRIGGER reject_second", nil, nil, nil) == SQLITE_OK)
        store.undo()
        assert(store.notice == nil && MailStore(persistence: SQLitePersistence(url: url)).conversations == store.conversations)
        for original in before { store.apply(ids: [original.id], action: .pin(original.pinned)) }
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
        let draftURL = url.deletingLastPathComponent().appending(path: "drafts.json")
        let drafts = DraftStore(url: draftURL, mail: store)
        var reply = ComposerDraft.make(mode: .reply(first), conversation: store.conversation(first), accounts: store.accounts)
        let bytes = Data("Draft attachment".utf8)
        reply.attachments = [MailAttachment(name: "sample.txt", data: bytes, contentType: "public.plain-text")]
        let saved = await drafts.save(reply)
        var later = reply
        later.id = UUID()
        let scheduled = await drafts.schedule(later, at: .now.addingTimeInterval(3600))
        assert(saved && scheduled)
        store.apply(ids: ids, action: .remove(.trash))
        store.apply(ids: [first], action: .restoreRemoved)
        let stale = await drafts.discardDrafts(for: ids, scheduled: true) { store.deletePermanently(ids, from: .trash, discarding: $0) }
        assert(!stale && drafts.all.count == 2 && ids.allSatisfy { store.conversation($0) != nil })
        store.apply(ids: [first], action: .remove(.trash))
        assert(sqlite3_exec(db, "CREATE TRIGGER reject_delete BEFORE DELETE ON conversations BEGIN SELECT RAISE(ABORT, 'injected failure'); END", nil, nil, nil) == SQLITE_OK)
        let refused = await drafts.discardDrafts(for: ids, scheduled: true) { store.deletePermanently(ids, from: .trash, discarding: $0) }
        let reopenedDrafts = DraftStore(url: draftURL)
        assert(!refused && reopenedDrafts.all == drafts.all && reopenedDrafts.outbox.count == 1)
        assert(reopenedDrafts.drafts.first?.attachments.first?.data == bytes)
        assert(ids.allSatisfy { store.conversation($0) != nil })
        assert(MailStore(persistence: SQLitePersistence(url: url)).conversations == store.conversations)
        assert(sqlite3_exec(db, "DROP TRIGGER reject_delete", nil, nil, nil) == SQLITE_OK)
        let fullDisk = DraftStore(url: draftURL, mail: store, write: { _, _ in throw CocoaError(.fileWriteOutOfSpace) })
        let refusedDraftWrite = await fullDisk.discardDrafts(for: ids, scheduled: true) { store.deletePermanently(ids, from: .trash, discarding: $0) }
        assert(!refusedDraftWrite && fullDisk.all.count == 2 && store.discardedDraftIDs.isEmpty)
        let held = draftURL.appendingPathExtension("held")
        let deleted = await drafts.discardDrafts(for: ids, scheduled: true) { removed in
            guard store.deletePermanently(ids, from: .trash, discarding: removed) else { return false }
            // Temporarily put a directory at the destination so the final file rename fails.
            try! FileManager.default.moveItem(at: draftURL, to: held)
            try! FileManager.default.createDirectory(at: draftURL, withIntermediateDirectories: false)
            return true
        }
        assert(deleted && drafts.all.isEmpty && drafts.error != nil)
        try FileManager.default.removeItem(at: draftURL)
        try FileManager.default.moveItem(at: held, to: draftURL)
        assert(DraftStore(url: draftURL).all.count == 2 && store.discardedDraftIDs == [reply.id, later.id])
        let reopenedMail = MailStore(persistence: SQLitePersistence(url: url))
        let recovered = DraftStore(url: draftURL, mail: reopenedMail)
        assert(recovered.all.isEmpty && recovered.outbox.isEmpty)
        await recovered.recoverAfterMailLoad()
        assert(reopenedMail.discardedDraftIDs.isEmpty && DraftStore(url: draftURL).all.isEmpty)
        assert(ids.allSatisfy { store.conversation($0) == nil })
        assert(MailStore(persistence: SQLitePersistence(url: url)).conversations == store.conversations)
        print("PASS: batch move/read/pin/snooze/restore, whole-batch field-specific Undo, incoming precedence and persistence")
    }

    @MainActor static func checkInboxOrder() throws {
        final class FixturePersistence: ConversationPersistence {
            let items: [Conversation]
            var failNextSearch = false
            var searches = 0
            init(items: [Conversation]) { self.items = items }
            func search(_ text: String) throws -> Set<UUID>? {
                searches += 1
                if failNextSearch { failNextSearch = false; throw CocoaError(.fileReadUnknown) }
                return nil
            }
            func load() throws -> MailData? { MailData(conversations: items) }
            func save(_ data: MailData) throws {}
        }
        let now = Date.now
        func item(_ subject: String, minutes: Double, unread: Bool, pinned: Bool = false, workflow: Workflow = .inbox) -> Conversation {
            Conversation(accountID: "icloud", subject: subject, workflow: workflow, unread: unread, pinned: pinned,
                         messages: [MailMessage(sender: "Sender", address: "sender@example.com", to: ["reader@example.com"], date: now.addingTimeInterval(-minutes * 60), body: "Example message")])
        }
        let disk = FixturePersistence(items: [
            item("Read newest", minutes: 1, unread: false),
            item("Unread older", minutes: 20, unread: true),
            item("Read pinned", minutes: 30, unread: false, pinned: true),
            item("Unread newer", minutes: 10, unread: true),
            item("Settled read", minutes: 1, unread: false, workflow: .settled),
            item("Settled unread", minutes: 20, unread: true, workflow: .settled)
        ])
        let store = MailStore(persistence: disk)
        assert(store.list(.inbox).map(\.subject) == ["Read pinned", "Read newest", "Unread newer", "Unread older"])
        assert(store.list(.inbox, search: "older").map(\.subject) == ["Unread older"])
        let newer = store.list(.inbox).first { $0.subject == "Unread newer" }!
        func inbox(_ query: String = "", drafts: [ComposerDraft] = [], filter: MailboxFilter = MailboxFilter()) -> MailboxProjections.Entry {
            store.mailbox(drafts: drafts, status: .inbox, query: query, filter: filter)
        }
        disk.failNextSearch = true
        let searches = disk.searches
        for _ in 0..<3 { assert(inbox("older").items.count == 1) }
        assert(disk.searches == searches + 2)
        let unread = MailboxFilter(enabled: true, readStatus: .unread)
        assert(inbox(filter: unread).unread == 2 && store.inboxUnreadCount == 2)
        assert(inbox("older").items.map(\.id) == [store.list(.inbox, search: "older")[0].id])
        let draft = ComposerDraft(subject: "Unfinished message")
        assert(inbox("unfinished", drafts: [draft]).items.map(\.id) == [draft.id])
        assert(inbox("unfinished").items.isEmpty)
        store.markRead(newer.id)
        assert(inbox(filter: unread).unread == 1 && store.inboxUnreadCount == 1)
        let revision = store.mailboxRevision
        store.markRead(newer.id)
        assert(store.mailboxRevision == revision)
        assert(store.list(.inbox).map(\.subject) == ["Read pinned", "Read newest", "Unread newer", "Unread older"])
        assert(store.conversation(newer.id)!.workflow == .inbox)
        assert(store.list(.settled).map(\.subject) == ["Settled read", "Settled unread"])
        print("PASS: pinned precedence, arrival order, search, mark-read preserves order, other sections unchanged")
    }

    @MainActor static func checkMailboxFiltersAndDraftActions() async throws {
        let now = Date.now
        var conversations = DemoData.conversations(now: now)
        let source = conversations[0]
        var reply = ComposerDraft.make(mode: .reply(source.id), conversation: source, accounts: MailAccount.demo)
        reply.text = "Filter draft needle"
        var standalone = ComposerDraft(subject: "Standalone filter draft")
        standalone.updatedAt = now.addingTimeInterval(60)
        let drafts = [reply, standalone]
        func list(_ status: Workflow, _ filter: MailboxFilter = MailboxFilter(), search: String = "") -> [MailboxItem] {
            MailboxItem.list(conversations: conversations, drafts: drafts, status: status, search: MailSearch(text: search), filter: filter)
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
        let failedDiscard = await failing.discardDrafts(for: [source.id, standalone.id])
        assert(!failedDiscard)
        assert(failing.drafts.count == 2 && DraftStore(url: url).drafts.count == 2)
        let discarded = await reloaded.discardDrafts(for: [source.id, standalone.id])
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
