import Foundation
import SQLite3

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
        try checkSQLiteStorage()
        try await checkAccounts()
        try checkThreadingHeaders()
        checkMessageLinks()
        checkHTMLDocument()
        try checkMute()
        try checkFollowUp()
        try await checkOutbox()
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

    @MainActor static func checkSQLiteStorage() throws {
        let url = URL.temporaryDirectory.appending(path: "mailern-sqlite-\(UUID())/mail.sqlite")
        let store = MailStore(persistence: SQLitePersistence(url: url))
        let changed = store.list(.inbox)[0].id
        let untouched = store.list(.settled)[0].id
        // Loading writes the seed data in full, so search works before the first change. Later saves write only what changed.
        assert(store.search("Saturday").indexed?.isEmpty == false)
        store.markRead(changed)
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
        // A reminder time that already passed settles the mail like a plain send.
        assert(store.send(threadID: nil, account: account, to: ["sam@example.com"], cc: [], subject: "Late", body: "x", followUp: .now.addingTimeInterval(-1)))
        assert(store.conversations[0].workflow == .settled && store.conversations[0].followUp == nil)
        print("PASS: follow-up reminders wait in Snoozed, return marked without a reply, end on reply or a manual move, undo, persistence")
    }

    @MainActor static func checkOutbox() async throws {
        let directory = URL.temporaryDirectory.appending(path: "mailern-outbox-\(UUID())")
        let store = MailStore(persistence: SQLitePersistence(url: directory.appending(path: "outbox.sqlite")))
        let url = directory.appending(path: "drafts.json")
        let drafts = DraftStore(url: url)
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
        // A failed draft write after sending keeps the mail scheduled, and the retry does not send it twice.
        let failing = DraftStore(url: url, write: { _, _ in throw CocoaError(.fileWriteOutOfSpace) })
        await failing.sendDue(through: store, now: start.addingTimeInterval(101))
        await failing.sendDue(through: store, now: start.addingTimeInterval(102))
        assert(failing.outbox.count == 2 && store.conversations.filter { $0.subject == "Later" }.count == 1)
        await drafts.sendDue(through: store, now: start.addingTimeInterval(103))
        let sent = store.conversations.first { $0.subject == "Later" }!
        assert(drafts.outbox.map(\.id) == [reply.id] && sent.messages.map(\.id) == [later.id])
        // The reminder starts when the mail goes out.
        assert(sent.workflow == .snoozed && sent.followUp == .waiting)
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
        print("PASS: trash/junk lists, restore to original workflow, Undo with block list, draft cancels Restore Undo, reply rescues Trash but not Junk, block survives deletion, 30-day purge, permanent deletion, reset")
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

    @MainActor static func mailboxLoadFailurePreservesStoredMail() throws {
        let directory = URL.temporaryDirectory.appending(path: "mail-load-failure-\(UUID())")
        let url = directory.appending(path: "mail.sqlite")
        let file = MailAttachment(name: "Keep.txt", data: Data("Keep this attachment".utf8), contentType: "public.plain-text")
        var original = DemoData.conversations()
        original[0].messages[0].attachments = [file]
        try SQLitePersistence(url: url).save(MailData(conversations: original))
        let payload = AttachmentJSON.directory(for: url).appending(path: file.id.uuidString)
        let withheld = directory.appending(path: "withheld-payload")
        try FileManager.default.moveItem(at: payload, to: withheld)
        let store = MailStore(persistence: SQLitePersistence(url: url))
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

    @MainActor static func checkBulkActions() throws {
        let disk = SQLitePersistence(url: URL.temporaryDirectory.appending(path: "mailern-bulk-\(UUID())/mail.sqlite"))
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
