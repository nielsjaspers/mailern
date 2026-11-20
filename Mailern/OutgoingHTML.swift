import UIKit

/// Turns the composer's rich text into the HTML part of an outgoing message.
enum OutgoingHTML {
    /// Font names such as '.SF UI' are private to Apple's platforms. Other clients would fall back to a serif font.
    static let fontStack = "-apple-system, 'Helvetica Neue', Helvetica, Arial, sans-serif"

    static func make(_ text: NSAttributedString) -> String? {
        let light = UITraitCollection(userInterfaceStyle: .light)
        let prepared = NSMutableAttributedString(attributedString: text)
        let range = NSRange(location: 0, length: prepared.length)
        // Colors resolve in light mode: in dark mode the default text color is white, which would stay white on a
        // recipient's white page. The default color is left out, so each client uses its own and its own dark mode.
        for key in [NSAttributedString.Key.foregroundColor, .backgroundColor] {
            prepared.enumerateAttribute(key, in: range) { value, part, _ in
                guard let color = value as? UIColor else { return }
                // RichText.decode marks default text with the dynamic label color. A chosen black or white stays.
                if key == .foregroundColor && color == .label {
                    prepared.removeAttribute(key, range: part)
                } else {
                    prepared.addAttribute(key, value: color.resolvedColor(with: light), range: part)
                }
            }
        }
        guard let data = try? prepared.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.html]),
              let html = String(data: data, encoding: .utf8) else { return nil }
        // The exporter puts all styles in one stylesheet in the head. Only that part changes, never the message text.
        guard let end = html.range(of: "</style>") else { return html }
        let style = String(html[..<end.lowerBound])
            .replacingOccurrences(of: #"'\.[^']*'|'UICTFont[^']*'"#, with: fontStack, options: .regularExpression)
            // Text without a color still gets black from the exporter. Removing it lets the client choose.
            .replacingOccurrences(of: #"(?<![\w-])color:\s*#000000\s*;?"#, with: "", options: .regularExpression)
        return style + html[end.lowerBound...]
    }
}
