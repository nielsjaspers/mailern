import Foundation
import UniformTypeIdentifiers

enum AttachmentImport {
    enum Failure: LocalizedError {
        case tooLarge
        var errorDescription: String? { "Attachments can total up to 25 MB in this prototype." }
    }

    static func read(_ url: URL, limit: Int) throws -> MailAttachment {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var result: Result<MailAttachment, any Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readable in
            result = Result {
                let info = try readable.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey])
                guard (info.fileSize ?? 0) <= limit else { throw Failure.tooLarge }
                let data = try Data(contentsOf: readable)
                guard data.count <= limit else { throw Failure.tooLarge }
                return MailAttachment(name: readable.lastPathComponent, data: data,
                                      contentType: (info.contentType ?? .data).identifier)
            }
        }
        if let coordinationError { throw coordinationError }
        return try (result ?? .failure(CocoaError(.fileReadUnknown))).get()
    }
}
