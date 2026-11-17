import Foundation

/// Finds the quoted history at the end of a plain-text reply, so the reader can fold it.
/// It only folds text it can prove is a quote of the message the reply answers, so anything else always shows.
enum QuotedText {
    /// The line the composer writes above a quote of `message`.
    static func attribution(for message: MailMessage) -> String {
        "On \(message.date.formatted()), \(message.sender) <\(message.address)> wrote:"
    }

    /// The UTF-16 offset where the quote of `answered` starts, or nil when there is none, or nothing would remain above it.
    /// A quote is the composer's attribution line followed by exactly the answered body, or a trailing run of `>` lines
    /// that holds the answered body, as most other mail clients write it. Line wrapping may differ.
    static func start(in body: String, answering answered: MailMessage?) -> Int? {
        guard let answered else { return nil }
        let quoted = collapsed(answered.body)
        guard !quoted.isEmpty else { return nil }
        let text = body as NSString
        var lines: [NSRange] = []
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: [.byLines, .substringNotRequired]) { _, range, _, _ in
            lines.append(range)
        }
        func line(_ i: Int) -> String { text.substring(with: lines[i]) }
        func isBlank(_ i: Int) -> Bool { line(i).trimmingCharacters(in: .whitespaces).isEmpty }

        var start: Int?
        let attribution = attribution(for: answered)
        if let i = lines.indices.first(where: {
            line($0) == attribution
                && text.substring(from: NSMaxRange(lines[$0])).trimmingCharacters(in: .whitespacesAndNewlines)
                    == answered.body.trimmingCharacters(in: .whitespacesAndNewlines)
        }) {
            start = i
        } else {
            // The trailing run of `>` lines, with blank lines between them. It folds only when it holds the answered body.
            var first = lines.count
            while first > 0, isBlank(first - 1) || line(first - 1).hasPrefix(">") { first -= 1 }
            while first < lines.count, isBlank(first) { first += 1 }
            let unquoted = lines[first...].indices.map { i in
                var content = Substring(line(i))
                if content.hasPrefix(">") { content = content.dropFirst() }
                if content.hasPrefix(" ") { content = content.dropFirst() }
                return String(content)
            }.joined(separator: "\n")
            if first < lines.count, collapsed(unquoted) == quoted { start = first }
        }
        guard let start else { return nil }
        let offset = lines[start].location
        guard !text.substring(to: offset).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return offset
    }

    /// Text with every run of whitespace as one space, so rewrapped lines still compare equal.
    private static func collapsed(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

extension Conversation {
    /// Where the quote of the message that `message` answers starts in its body.
    func quoteStart(of message: MailMessage) -> Int? {
        let answered = message.inReplyTo.flatMap { id in messages.first { $0.threadingID == id && $0.id != message.id } }
        return QuotedText.start(in: message.body, answering: answered)
    }
}
