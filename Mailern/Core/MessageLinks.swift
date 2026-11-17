import Foundation

/// The fields a `mailto:` link fills in a new message, as RFC 6068 defines them.
struct MailtoLink: Codable, Equatable, Sendable {
    var to: [String] = []
    var cc: [String] = []
    var bcc: [String] = []
    var subject = ""
    var body = ""

    init?(_ url: URL) {
        guard url.scheme?.lowercased() == "mailto",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        func addresses(_ text: String) -> [String] { ComposerDraft.addresses(text) }
        to = addresses(components.path)
        for item in components.queryItems ?? [] {
            let value = item.value ?? ""
            switch item.name.lowercased() {
            case "to": to += addresses(value)
            case "cc": cc += addresses(value)
            case "bcc": bcc += addresses(value)
            case "subject": subject = value
            case "body": body = value
            default: break
            }
        }
    }
}

enum MessageLinks {
    private static let detector = try! NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue | NSTextCheckingResult.CheckingType.phoneNumber.rawValue)

    /// Plain message text with web links, email addresses, and phone numbers made tappable.
    /// The text is not read as Markdown: a `*` or `_` in a message shows as written.
    static func linked(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            let phone = match.phoneNumber.map { $0.filter { $0.isNumber || $0 == "+" } }
            guard let url = match.url ?? phone.flatMap({ URL(string: "tel:\($0)") }),
                  let range = Range(match.range, in: result) else { continue }
            result[range].link = url
        }
        return result
    }
}
