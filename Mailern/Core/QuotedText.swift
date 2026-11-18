import Foundation

/// Finds the quote that Mailern's composer adds at the end of a reply, so the reader can fold it.
/// It only folds text it can prove is that quote, unchanged, so anything else always shows. Quotes from other
/// mail clients, such as `>` lines, are not recognized yet.
enum QuotedText {
    /// The line the composer writes above a quote of `message`.
    static func attribution(for message: MailMessage) -> String {
        "On \(message.date.formatted()), \(message.sender) <\(message.address)> wrote:"
    }

    /// The UTF-16 offset where the quote of `answered` starts, or nil when there is none, or nothing would remain above it.
    /// A quote is the composer's attribution line followed by exactly the answered body, with nothing after it.
    static func start(in body: String, answering answered: MailMessage?) -> Int? {
        guard let answered, !answered.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let quote = "\n\n" + attribution(for: answered) + "\n" + answered.body
        let text = body.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
        let expected = quote.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
        // Code units, not characters: text that only looks the same could shift the offset below.
        let units = Array(text.utf16), quoteUnits = Array(expected.utf16)
        guard units.count >= quoteUnits.count, units.suffix(quoteUnits.count).elementsEqual(quoteUnits) else { return nil }
        let offset = units.count - quoteUnits.count + 2
        guard !(body as NSString).substring(to: offset).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return offset
    }
}

extension Conversation {
    /// The message that `message` answers, by its In-Reply-To header.
    func answered(by message: MailMessage) -> MailMessage? {
        message.inReplyTo.flatMap { id in messages.first { $0.threadingID == id && $0.id != message.id } }
    }
    /// Where the quote of the message that `message` answers starts in its body.
    func quoteStart(of message: MailMessage) -> Int? {
        QuotedText.start(in: message.body, answering: answered(by: message))
    }
}
