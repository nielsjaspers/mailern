import UIKit

/// Turns the composer's rich text into the HTML part of an outgoing message.
enum OutgoingHTML {
    /// Font names such as '.SF UI' are private to Apple's platforms. Other clients would fall back to a serif font.
    static let fontStack = "-apple-system, 'Helvetica Neue', Helvetica, Arial, sans-serif"

    static func make(_ text: NSAttributedString) -> String? {
        let light = UITraitCollection(userInterfaceStyle: .light)
        // Stored rich text keeps the label color as it looked when written: black, or white in dark mode.
        let defaultColors = [light, UITraitCollection(userInterfaceStyle: .dark)].map { UIColor.label.resolvedColor(with: $0) }
        let prepared = NSMutableAttributedString(attributedString: text)
        let range = NSRange(location: 0, length: prepared.length)
        // Colors resolve in light mode: in dark mode the default text color is white, which would stay white on a
        // recipient's white page. The default color is left out, so each client uses its own and its own dark mode.
        for key in [NSAttributedString.Key.foregroundColor, .backgroundColor] {
            prepared.enumerateAttribute(key, in: range) { value, part, _ in
                guard let color = value as? UIColor else { return }
                let resolved = color.resolvedColor(with: light)
                if key == .foregroundColor && defaultColors.contains(where: { matches($0, resolved) }) {
                    prepared.removeAttribute(key, range: part)
                } else {
                    prepared.addAttribute(key, value: resolved, range: part)
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

    /// Compares color values, since decoded rich text can use another color space than UIKit's own colors.
    private static func matches(_ a: UIColor, _ b: UIColor) -> Bool {
        var (ar, ag, ab, aa, br, bg, bb, ba): (CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0, 0, 0, 0, 0)
        guard a.getRed(&ar, green: &ag, blue: &ab, alpha: &aa), b.getRed(&br, green: &bg, blue: &bb, alpha: &ba) else { return false }
        return abs(ar - br) < 0.02 && abs(ag - bg) < 0.02 && abs(ab - bb) < 0.02 && abs(aa - ba) < 0.02
    }
}
