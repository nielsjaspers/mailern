import SwiftUI
import WebKit

/// Shows an HTML email. The web view runs no scripts and loads nothing from the network until the reader taps
/// Load images. Remote images are blocked by default because senders use them to track when mail is opened.
struct HTMLMessageView: View {
    let html: String
    /// Shown instead when the content blocker cannot be compiled. The message never loads without it.
    let fallback: String
    /// The reader's side margin. The page gets the same margin inside, so a light page spans the full width.
    var margin: CGFloat = 20
    /// A peek takes no touches, so it states that images are hidden without offering to load them.
    var isPreview = false
    @State private var blocker: WKContentRuleList?
    @State private var blockerFailed = false
    @State private var remoteContent = false
    @State private var height: CGFloat = 1
    private var document: HTMLDocument { HTMLDocument(html, remoteContent: remoteContent, margin: margin) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if blockerFailed {
                Text(MessageLinks.linked(fallback)).font(.body).lineSpacing(5).textSelection(.enabled)
                    .padding(.horizontal, margin)
            } else if let blocker {
                if document.hasRemoteContent && !remoteContent {
                    HStack(spacing: 6) {
                        Image(systemName: "eye.slash").accessibilityHidden(true)
                        Text("Remote images are hidden")
                        Spacer(minLength: 8)
                        if !isPreview {
                            Button("Load images") { remoteContent = true }
                                .fontWeight(.semibold).buttonStyle(.borderless)
                        }
                    }
                    .font(.footnote).foregroundStyle(.secondary)
                    .padding(.horizontal, margin)
                }
                // Mail written only for light backgrounds keeps its white page in dark mode, as it would on paper.
                HTMLWebView(html: document.html, blocker: remoteContent ? nil : blocker, height: $height)
                    .frame(height: height)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task {
            do { blocker = try await RemoteContentBlocker.shared.value }
            catch { blockerFailed = true }
        }
    }
}

/// A content rule list that blocks every load with a network or file scheme. `about:` and `data:` URLs stay allowed,
/// so the message itself and its embedded images still show.
enum RemoteContentBlocker {
    @MainActor static let shared = Task {
        guard let list = try await WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "mailern-block-remote-content",
            encodedContentRuleList: #"[{"trigger":{"url-filter":"^[a-z][a-z0-9+.-]*://"},"action":{"type":"block"}}]"#) else {
            throw CocoaError(.featureUnsupported)
        }
        return list
    }
}

private struct HTMLWebView: UIViewRepresentable {
    @Environment(\.openURL) private var openURL
    let html: String
    /// Nil allows remote content.
    let blocker: WKContentRuleList?
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        // No cookies or storage survive the message, so a sender cannot recognize the reader on a later load.
        configuration.websiteDataStore = .nonPersistent()
        if let blocker { configuration.userContentController.add(blocker) }
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        // The thread scrolls. The message grows to its full height inside it.
        view.scrollView.isScrollEnabled = false
        view.allowsLinkPreview = false
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        context.coordinator.observe(view, height: $height)
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.openURL = openURL
        coordinator.height = $height
        let blocked = blocker != nil
        guard coordinator.loaded != html || coordinator.blocked != blocked else { return }
        if !blocked { view.configuration.userContentController.removeAllContentRuleLists() }
        coordinator.loaded = html
        coordinator.blocked = blocked
        view.loadHTMLString(html, baseURL: nil)
    }

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var openURL: OpenURLAction?
        var height: Binding<CGFloat>?
        var loaded: String?
        var blocked = true
        private var observation: NSKeyValueObservation?

        func observe(_ view: WKWebView, height: Binding<CGFloat>) {
            self.height = height
            observation = view.scrollView.observe(\.contentSize, options: [.new]) { [weak self, weak view] scrollView, _ in
                let size = scrollView.contentSize
                Task { @MainActor in
                    guard let self, let view else { return }
                    // Mail laid out for a fixed width, often 600 points, is scaled down to fit, as Mail does.
                    let width = view.bounds.width
                    if width > 0, size.width > width + 1 {
                        view.pageZoom *= width / size.width
                        return
                    }
                    guard size.height > 0, abs((self.height?.wrappedValue ?? 0) - size.height) > 0.5 else { return }
                    self.height?.wrappedValue = size.height
                }
            }
        }
        /// Only the message itself loads in the view. A tapped link goes to `openURL`; anything else is dropped.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            // loadHTMLString without a base URL loads the message as about:blank, and its #anchors stay on that page.
            // Frames, including about:srcdoc, never load.
            guard let url = action.request.url else { return .cancel }
            if url.scheme == "about" && action.targetFrame?.isMainFrame == true { return .allow }
            if action.navigationType == .linkActivated { openURL?(url) }
            return .cancel
        }
        /// Links that ask for a new window, such as `target="_blank"`.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = action.request.url { openURL?(url) }
            return nil
        }
    }
}
