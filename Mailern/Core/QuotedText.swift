import Foundation

/// Finds the quoted history at the end of a plain-text message, so the reader can fold it.
/// It only folds text it can prove is a quote, so text written below or between quoted lines always shows.
enum QuotedText {
    /// The UTF-16 offset where the trailing quote starts, or nil when there is none, or nothing would remain above it.
    /// A quote is an attribution line ("On …, … wrote:") followed only by the body of a message in `quotable`,
    /// as Mailern's composer writes it, or a trailing run of lines that start with `>`, as most other mail clients write it.
    static func start(in body: String, quotable: [String]) -> Int? {
        let text = body as NSString
        var lines: [NSRange] = []
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: [.byLines, .substringNotRequired]) { _, range, _, _ in
            lines.append(range)
        }
        func line(_ i: Int) -> String { text.substring(with: lines[i]) }
        func isBlank(_ i: Int) -> Bool { line(i).trimmingCharacters(in: .whitespaces).isEmpty }
        func isAttribution(_ i: Int) -> Bool { line(i).range(of: #"^On .+ wrote:\s*$"#, options: .regularExpression) != nil }
        func rest(after i: Int) -> String {
            text.substring(from: NSMaxRange(lines[i])).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let quotable = Set(quotable.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })

        var start: Int?
        if let i = lines.indices.first(where: { isAttribution($0) && quotable.contains(rest(after: $0)) }) {
            start = i
        } else {
            // The trailing run of `>` lines, with blank lines between them, and the attribution line above it if any.
            var first = lines.count
            while first > 0, isBlank(first - 1) || line(first - 1).hasPrefix(">") { first -= 1 }
            while first < lines.count, isBlank(first) { first += 1 }
            if first < lines.count {
                var above = first - 1
                while above >= 0, isBlank(above) { above -= 1 }
                start = above >= 0 && isAttribution(above) ? above : first
            }
        }
        guard let start else { return nil }
        let offset = lines[start].location
        guard !text.substring(to: offset).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return offset
    }
}

extension Conversation {
    /// Where the quoted history in `message` starts. Quotes of Mailern's composer must match an earlier message.
    func quoteStart(of message: MailMessage) -> Int? {
        let index = messages.firstIndex { $0.id == message.id } ?? messages.count
        return QuotedText.start(in: message.body, quotable: messages[..<index].map(\.body))
    }
}
