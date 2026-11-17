import Foundation

/// Finds the quoted history at the end of a plain-text message, so the reader can fold it.
/// It only folds text it can prove is a quote, so text written below, between, or above quoted lines always shows.
enum QuotedText {
    /// The UTF-16 offset where the trailing quote starts, or nil when there is none, or nothing would remain above it.
    /// A quote is Mailern's composer attribution for `answered` followed only by its body, or a trailing run of lines
    /// that start with `>`, as most other mail clients write it.
    static func start(in body: String, answering answered: MailMessage?) -> Int? {
        let text = body as NSString
        var lines: [NSRange] = []
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: [.byLines, .substringNotRequired]) { _, range, _, _ in
            lines.append(range)
        }
        func line(_ i: Int) -> String { text.substring(with: lines[i]) }
        func isBlank(_ i: Int) -> Bool { line(i).trimmingCharacters(in: .whitespaces).isEmpty }
        func rest(after i: Int) -> String {
            text.substring(from: NSMaxRange(lines[i])).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var start: Int?
        if let answered, let i = lines.indices.first(where: {
            // The composer writes "On <date>, <sender> <<address>> wrote:" and then the answered body.
            line($0).hasPrefix("On ") && line($0).hasSuffix(", \(answered.sender) <\(answered.address)> wrote:")
                && rest(after: $0) == answered.body.trimmingCharacters(in: .whitespacesAndNewlines)
        }) {
            start = i
        } else {
            // The trailing run of `>` lines, with blank lines between them. Text above it shows, even an attribution.
            var first = lines.count
            while first > 0, isBlank(first - 1) || line(first - 1).hasPrefix(">") { first -= 1 }
            while first < lines.count, isBlank(first) { first += 1 }
            if first < lines.count { start = first }
        }
        guard let start else { return nil }
        let offset = lines[start].location
        guard !text.substring(to: offset).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return offset
    }
}

extension Conversation {
    /// Where the quoted history in `message` starts. A Mailern quote must match the message it answers.
    func quoteStart(of message: MailMessage) -> Int? {
        let answered = message.inReplyTo.flatMap { id in messages.first { $0.threadingID == id && $0.id != message.id } }
        return QuotedText.start(in: message.body, answering: answered)
    }
}
