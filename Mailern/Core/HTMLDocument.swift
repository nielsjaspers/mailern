import Foundation

/// An email's HTML, prepared for the reader.
struct HTMLDocument {
    let html: String
    /// True when the message styles itself for dark mode. Other mail is shown on white.
    let adaptsToDarkMode: Bool
    /// True when the message refers to images or styles on the network.
    let hasRemoteContent: Bool

    init(_ source: String, remoteContent: Bool) {
        let lowered = source.lowercased()
        // A dark style or a color-scheme that includes dark opts in. `color-scheme: only light` does not.
        adaptsToDarkMode = lowered.range(of: #"color-scheme[^;>{]*\bdark"#, options: .regularExpression) != nil
        hasRemoteContent = lowered.range(of: #"(src|srcset|background)\s*=\s*["']?\s*(https?:)?//|url\(\s*["']?\s*(https?:)?//|<link\b|@import\b"#,
                                         options: .regularExpression) != nil
        // Early iOS 18 WebKit opens preconnect and DNS prefetch connections without asking the content blocker.
        // While remote content is blocked, links lose their rel, so they cannot connect. Their stylesheets are blocked anyway.
        let shown = remoteContent ? source : source.replacingOccurrences(
            of: #"(<link\b[^>]*?\s)rel\s*="#, with: "$1data-rel=", options: [.regularExpression, .caseInsensitive])
        // The doctype comes first so every message renders in standards mode. The parser moves the message's own
        // head elements into this head, and the message's styles come later, so they override these defaults.
        html = """
            <!doctype html><meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <meta http-equiv="x-dns-prefetch-control" content="off">
            <meta name="color-scheme" content="\(adaptsToDarkMode ? "light dark" : "light")">
            <style>
            html { -webkit-text-size-adjust: 100%; background: \(adaptsToDarkMode ? "transparent" : "#fff"); }
            body { margin: 0; font: -apple-system-body; overflow-wrap: break-word; }
            img { max-width: 100% !important; height: auto; }
            </style>
            """ + shown
    }
}
