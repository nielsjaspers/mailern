import Foundation
import Observation

enum ComposeMode: Codable, Equatable, Identifiable {
    case new, reply(UUID), replyAll(UUID), forward(UUID), draft(UUID)
    var id: String { String(describing: self) }
    var sourceID: UUID? {
        switch self { case .reply(let id), .replyAll(let id), .forward(let id): id; default: nil }
    }
    var replyID: UUID? {
        switch self { case .reply(let id), .replyAll(let id): id; default: nil }
    }
}

struct MailAttachment: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var data: Data
    var contentType: String
}

struct ComposerDraft: Codable, Equatable, Identifiable {
    var id = UUID()
    var mode: ComposeMode = .new
    var accountID = MailAccount.demo[1].id
    var to = ""
    var cc = ""
    var bcc = ""
    var subject = ""
    var text = ""
    var richText: Data?
    var attachments: [MailAttachment] = []
    var updatedAt = Date.now

    static func addresses(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0 == ";" || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
    var canSend: Bool {
        let recipients = Self.addresses(to) + Self.addresses(cc) + Self.addresses(bcc)
        return !recipients.isEmpty && recipients.allSatisfy { address in
            let parts = address.split(separator: "@", omittingEmptySubsequences: false)
            return parts.count == 2 && !parts[0].isEmpty && parts[1].contains(".") && !address.contains(where: \.isWhitespace)
        }
    }
    static func make(mode: ComposeMode, conversation: Conversation?) -> Self {
        var draft = Self(mode: mode)
        guard let c = conversation else { return draft }
        draft.accountID = c.accountID
        switch mode {
        case .reply, .replyAll:
            let target = c.correspondent
            draft.to = target.outgoing ? target.to.joined(separator: ", ") : target.address
            draft.subject = c.subject.lowercased().hasPrefix("re:") ? c.subject : "Re: \(c.subject)"
            if case .replyAll = mode {
                var seen = Set(MailAccount.demo.map { $0.address.lowercased() } + addresses(draft.to).map { $0.lowercased() })
                draft.cc = (target.to + target.cc).filter { seen.insert($0.lowercased()).inserted }.joined(separator: ", ")
            }
            draft.text = "\n\nOn \(c.latest.date.formatted()), \(c.latest.sender) <\(c.latest.address)> wrote:\n\(c.latest.body)"
        case .forward:
            draft.subject = c.subject.lowercased().hasPrefix("fwd:") ? c.subject : "Fwd: \(c.subject)"
            draft.text = "\n\nBegin forwarded message:\n\nFrom: \(c.latest.sender) <\(c.latest.address)>\nDate: \(c.latest.date.formatted())\nSubject: \(c.subject)\nTo: \(c.latest.to.joined(separator: ", "))\n\n\(c.latest.body)"
            draft.attachments = c.latest.attachments ?? []
        default: break
        }
        return draft
    }
}

@MainActor @Observable
final class DraftStore {
    private(set) var drafts: [ComposerDraft] = []
    var error: String?
    private let url: URL
    init(url: URL = URL.applicationSupportDirectory.appending(path: "Mailern/drafts-v1.json")) {
        self.url = url
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                drafts = try JSONDecoder().decode([ComposerDraft].self, from: Data(contentsOf: url))
            }
        } catch { self.error = "Could not load drafts. \(error.localizedDescription)" }
    }
    @discardableResult func save(_ draft: ComposerDraft) -> Bool {
        var updated = drafts.filter { $0.id != draft.id }
        updated.insert(draft, at: 0)
        return persist(updated)
    }
    @discardableResult func delete(_ id: UUID) -> Bool { persist(drafts.filter { $0.id != id }) }
    private func persist(_ updated: [ComposerDraft]) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(updated).write(to: url, options: .atomic)
            drafts = updated
            error = nil
            return true
        } catch { self.error = "Could not save drafts. \(error.localizedDescription)"; return false }
    }
}
