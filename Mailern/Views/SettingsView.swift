import SwiftUI

enum InboxPullAction: String, CaseIterable, Identifiable {
    case off, search, compose
    var id: Self { self }
    var title: String {
        switch self {
        case .off: "Off"
        case .search: "Search"
        case .compose: "New email"
        }
    }
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var pullAction: InboxPullAction
    @Binding var bottomCompose: Bool

    var body: some View {
        Form {
            Section {
                NavigationLink("Snooze settings") { SnoozeSettingsView() }
            }
            Section("Labs") {
                Picker("Inbox pull-down", selection: $pullAction) {
                    ForEach(InboxPullAction.allCases) { action in
                        Text(action.title).tag(action)
                    }
                }
                Toggle("Compose at bottom right", isOn: $bottomCompose)
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }
}

struct InboxPullModifier: ViewModifier {
    let mode: InboxPullAction
    @Binding var distance: CGFloat
    let action: @MainActor () -> Void
    @Binding var pending: Bool
    private let threshold: CGFloat = 80

    func body(content: Content) -> some View {
        if mode == .off {
            content
        } else if #available(iOS 18, *) {
            content
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    max(0, -geometry.contentOffset.y - geometry.contentInsets.top)
                } action: { _, value in
                    distance = value
                    if value >= threshold { pending = true }
                }
                .onScrollPhaseChange { _, new in
                    if new == .tracking { pending = false }
                    if new == .idle && pending {
                        pending = false
                        action()
                    }
                }
                .onDisappear { distance = 0 }
        } else {
            content.refreshable { action() }
        }
    }
}

struct PullActionIndicator: View {
    let mode: InboxPullAction
    let progress: CGFloat
    var body: some View {
        ZStack {
            if progress >= 1 {
                Circle().fill(.teal)
                Image(systemName: mode == .search ? "magnifyingglass" : "square.and.pencil")
                    .font(.system(size: 20, weight: .medium)).foregroundStyle(.white)
            } else {
                Circle().stroke(.teal.opacity(0.15), lineWidth: 3)
                Circle().trim(from: 0, to: progress)
                    .stroke(.teal, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .frame(width: 44, height: 44)
    }
}

struct PullPlacementReader: UIViewRepresentable {
    let onPlacement: (CGRect, CGFloat) -> Void
    func makeUIView(context: Context) -> PlacementView { PlacementView() }
    func updateUIView(_ view: PlacementView, context: Context) {
        view.onPlacement = onPlacement
        view.report()
    }

    final class PlacementView: UIView {
        var onPlacement: (CGRect, CGFloat) -> Void = { _, _ in }
        private var lastFrame: CGRect?
        private var lastBottom: CGFloat?
        override func layoutSubviews() { super.layoutSubviews(); report() }
        override func didMoveToWindow() { super.didMoveToWindow(); report() }
        func report() {
            // Navigation bars and tab content have separate SwiftUI coordinate spaces.
            DispatchQueue.main.async { [weak self] in
                guard let self, let window else { return }
                let frame = convert(bounds, to: window)
                let bottom: CGFloat
                if let bar = navigationBar(in: window) {
                    let barFrame = bar.convert(bar.bounds, to: window)
                    // Expanded large titles scroll below the standard 44-point control row.
                    bottom = bar.bounds.height > 100 ? barFrame.minY + 44 : barFrame.maxY
                } else {
                    bottom = window.safeAreaInsets.top + 44
                }
                guard frame != lastFrame || bottom != lastBottom else { return }
                lastFrame = frame
                lastBottom = bottom
                onPlacement(frame, bottom)
            }
        }
        private func navigationBar(in view: UIView) -> UINavigationBar? {
            guard !view.isHidden, view.alpha > 0 else { return nil }
            if let bar = view as? UINavigationBar { return bar }
            for child in view.subviews.reversed() {
                if let bar = navigationBar(in: child) { return bar }
            }
            return nil
        }
    }
}
