import Foundation

/// Attachments are immutable files; JSON contains their identity and display metadata.
enum AttachmentJSON {
    private static let contextKey = CodingUserInfoKey(rawValue: "attachmentContext")!
    private static let locks = FileLocks()

    static func load<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
        try locked(url) {
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return try decoder(for: url).decode(type, from: Data(contentsOf: url))
        }
    }
    static func save<T: Codable>(_ value: T, to url: URL,
                                   write: @Sendable (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) throws {
        try locked(url) {
            defer { cleanIfReadable(url, as: T.self) }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try write(encoder(for: url).encode(value), url)
        }
    }
    static func encoder(for url: URL) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.userInfo[contextKey] = PayloadContext(directory: directory(for: url))
        return encoder
    }
    static func decoder(for url: URL) -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.userInfo[contextKey] = PayloadContext(directory: directory(for: url))
        return decoder
    }
    static func directory(for url: URL) -> URL { url.deletingPathExtension().appendingPathExtension("attachments") }
    static func payloadURL(_ id: UUID, context: [CodingUserInfoKey: Any]) throws -> URL {
        guard let payloads = context[contextKey] as? PayloadContext else { throw StorageError.missingContext }
        payloads.referenced.insert(id)
        return payloads.directory.appending(path: id.uuidString)
    }
    static func writePayload(_ data: Data, id: UUID, context: [CodingUserInfoKey: Any]) throws {
        let url = try payloadURL(id, context: context)
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
    static func removeUnusedPayloads<T: Decodable>(for url: URL, as type: T.Type) {
        locked(url) { cleanIfReadable(url, as: type) }
    }
    private static func cleanIfReadable<T: Decodable>(_ url: URL, as type: T.Type) {
        var retained = Set<UUID>()
        if FileManager.default.fileExists(atPath: url.path) {
            let decoder = decoder(for: url)
            guard let data = try? Data(contentsOf: url), (try? decoder.decode(type, from: data)) != nil,
                  let context = decoder.userInfo[contextKey] as? PayloadContext else { return }
            retained = context.referenced
        }
        removePayloads(for: url, keeping: retained)
    }
    /// Removes attachment files that no stored message refers to.
    static func removePayloads(for url: URL, keeping retained: Set<UUID>) {
        let folder = directory(for: url)
        guard FileManager.default.fileExists(atPath: folder.path),
              let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
        for file in files {
            if let id = UUID(uuidString: file.lastPathComponent), !retained.contains(id) {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
    private final class PayloadContext {
        let directory: URL
        var referenced = Set<UUID>()
        init(directory: URL) { self.directory = directory }
    }
    private static func locked<T>(_ url: URL, _ operation: () throws -> T) rethrows -> T {
        let lock = locks.forFile(url)
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
    private enum StorageError: Error { case missingContext }
    // A reader must finish mapping the old payloads before a write can remove them.
    private final class FileLocks: @unchecked Sendable {
        private let registry = NSLock()
        private var files: [URL: NSLock] = [:]
        func forFile(_ url: URL) -> NSLock {
            registry.lock()
            defer { registry.unlock() }
            let key = url.standardizedFileURL
            if let existing = files[key] { return existing }
            let lock = NSLock()
            files[key] = lock
            return lock
        }
    }
}
