import Foundation
import SQLite3

/// Stores each conversation in its own row, so a mailbox action rewrites only the conversations it changed.
/// Rows hold the JSON encoding of a conversation; attachment bytes stay in separate files next to the database.
/// A trigram full-text index covers subjects, senders, addresses, and bodies for substring search.
final class SQLitePersistence: ConversationPersistence {
    let url: URL
    private var db: OpaquePointer?
    /// What the database holds after the last successful load or save. Nil means unknown, so the next save rewrites everything.
    private var stored: MailData?
    /// Load order. New conversations go to the front, so inserting one does not renumber the others.
    private var positions: [UUID: Int] = [:]

    init(url: URL) { self.url = url }
    deinit { sqlite3_close(db) }

    static var local: SQLitePersistence {
        SQLitePersistence(url: URL.applicationSupportDirectory.appending(path: "Mailern/mail.sqlite"))
    }

    func load() throws -> MailData? {
        stored = nil
        positions = [:]
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let db = try open()
        let decoder = AttachmentJSON.decoder(for: url)
        // The accounts row is written in the same transaction as the first conversations. Without it, nothing was stored.
        guard let accounts = try setting(db, "accounts") else { return nil }
        var data = MailData(conversations: [], accounts: try decoder.decode([MailAccount].self, from: accounts))
        if let blocked = try setting(db, "blockedSenders") {
            data.blockedSenders = try decoder.decode(Set<String>.self, from: blocked)
        }
        var loaded: [UUID: Int] = [:]
        try query(db, "SELECT position, payload FROM conversations ORDER BY position") { row in
            let conversation = try decoder.decode(Conversation.self, from: Self.blob(row, 1))
            data.conversations.append(conversation)
            loaded[conversation.id] = Int(sqlite3_column_int64(row, 0))
        }
        stored = data
        positions = loaded
        return data
    }

    func save(_ data: MailData) throws {
        let db = try open()
        let encoder = AttachmentJSON.encoder(for: url)
        let previous = stored
        let old = Dictionary(uniqueKeysWithValues: (previous?.conversations ?? []).map { ($0.id, $0) })
        let removed = previous == nil ? [] : Set(old.keys).subtracting(data.conversations.map(\.id))
        var positions = previous == nil ? [:] : self.positions.filter { !removed.contains($0.key) }
        var next = (positions.values.min() ?? 0) - 1
        for conversation in data.conversations.reversed() where positions[conversation.id] == nil {
            positions[conversation.id] = next
            next -= 1
        }
        try exec(db, "BEGIN IMMEDIATE")
        do {
            if previous == nil {
                try exec(db, "DELETE FROM conversations; DELETE FROM search; DELETE FROM settings")
            }
            for id in removed {
                try run(db, "DELETE FROM conversations WHERE id = ?", [.text(id.uuidString)])
                try run(db, "DELETE FROM search WHERE id = ?", [.text(id.uuidString)])
            }
            for conversation in data.conversations where old[conversation.id] != conversation {
                let id = SQLValue.text(conversation.id.uuidString)
                try run(db, """
                    INSERT INTO conversations (id, position, payload) VALUES (?, ?, ?)
                    ON CONFLICT (id) DO UPDATE SET payload = excluded.payload
                    """, [id, .integer(positions[conversation.id]!), .blob(encoder.encode(conversation))])
                try run(db, "DELETE FROM search WHERE id = ?", [id])
                try run(db, "INSERT INTO search (id, content) VALUES (?, ?)", [id, .text(Self.folded(conversation.searchText))])
            }
            if previous?.accounts != data.accounts {
                try run(db, "INSERT OR REPLACE INTO settings (key, payload) VALUES ('accounts', ?)", [.blob(encoder.encode(data.accounts))])
            }
            if previous?.blockedSenders != data.blockedSenders {
                try run(db, "INSERT OR REPLACE INTO settings (key, payload) VALUES ('blockedSenders', ?)", [.blob(encoder.encode(data.blockedSenders))])
            }
            try exec(db, "COMMIT")
        } catch {
            try? exec(db, "ROLLBACK")
            throw error
        }
        stored = data
        self.positions = positions
        if previous == nil || !removed.isEmpty {
            AttachmentJSON.removePayloads(for: url, keeping: Set(data.conversations.flatMap { $0.messages.flatMap { $0.attachments ?? [] } }.map(\.id)))
        }
    }

    func search(_ text: String) throws -> Set<UUID>? {
        let text = Self.folded(text)
        // Trigrams need at least three characters. Shorter queries are matched in memory.
        guard text.unicodeScalars.count >= 3 else { return nil }
        let db = try open()
        var ids = Set<UUID>()
        // A quoted FTS5 phrase matches the text as one substring. Double quotes inside it are escaped by doubling.
        let phrase = "\"\(text.replacingOccurrences(of: "\"", with: "\"\""))\""
        try query(db, "SELECT id FROM search WHERE search MATCH ?", [.text(phrase)]) { row in
            if let id = UUID(uuidString: String(cString: sqlite3_column_text(row, 0))) { ids.insert(id) }
        }
        return ids
    }

    /// Index and queries share one form, so "STRASSE" finds "Straße" and composed and decomposed accents match,
    /// as they do in the in-memory search.
    private static func folded(_ text: String) -> String {
        text.folding(options: .caseInsensitive, locale: nil).precomposedStringWithCanonicalMapping
    }

    // MARK: SQLite

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    private enum SQLValue {
        case text(String), integer(Int), blob(Data)
    }

    private func open() throws -> OpaquePointer {
        if let db { return db }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "The database could not be opened."
            sqlite3_close(handle)
            throw Failure(message: message)
        }
        do {
            try exec(handle, """
                PRAGMA journal_mode = WAL;
                CREATE TABLE IF NOT EXISTS conversations (id TEXT PRIMARY KEY, position INTEGER NOT NULL, payload BLOB NOT NULL);
                CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, payload BLOB NOT NULL);
                CREATE VIRTUAL TABLE IF NOT EXISTS search USING fts5(id UNINDEXED, content, tokenize = 'trigram case_sensitive 1');
                """)
        } catch {
            sqlite3_close(handle)
            throw error
        }
        db = handle
        return handle
    }
    private func exec(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw Failure(message: String(cString: sqlite3_errmsg(db))) }
    }
    private func run(_ db: OpaquePointer, _ sql: String, _ values: [SQLValue]) throws {
        try query(db, sql, values) { _ in }
    }
    private func query(_ db: OpaquePointer, _ sql: String, _ values: [SQLValue] = [], row: (OpaquePointer) throws -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw Failure(message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        // SQLite copies bound values, so the Swift buffers only need to live for the bind call.
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            switch value {
            case .text(let text): sqlite3_bind_text(statement, position, text, -1, transient)
            case .integer(let number): sqlite3_bind_int64(statement, position, Int64(number))
            case .blob(let data): _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, position, $0.baseAddress, Int32($0.count), transient) }
            }
        }
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: try row(statement)
            case SQLITE_DONE: return
            default: throw Failure(message: String(cString: sqlite3_errmsg(db)))
            }
        }
    }
    private func setting(_ db: OpaquePointer, _ key: String) throws -> Data? {
        var result: Data?
        try query(db, "SELECT payload FROM settings WHERE key = ?", [.text(key)]) { result = Self.blob($0, 0) }
        return result
    }
    private static func blob(_ row: OpaquePointer, _ column: Int32) -> Data {
        guard let bytes = sqlite3_column_blob(row, column) else { return Data() }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(row, column)))
    }
}

extension Conversation {
    /// The text the search index covers. Account names change separately and are matched in memory.
    var searchText: String {
        ([subject] + messages.flatMap { [$0.sender, $0.address, $0.body, $0.subject ?? ""] }).joined(separator: "\n")
    }
}
