import SwiftUI
import UserNotifications

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

/// How long sent mail waits in the outbox, so Undo can take it back.
enum UndoSend {
    static let key = "undoSendDelay"
    static let defaultDelay = 10
    static let choices = [0, 5, 10, 20]
}

/// What a thread shows after Settle.
enum AfterSettle: String, CaseIterable, Identifiable {
    case returnToList, openNext
    static let key = "afterSettle"
    var id: Self { self }
    var title: String {
        switch self { case .returnToList: "Return to list"; case .openNext: "Open next conversation" }
    }
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(MailStore.self) private var store
    @AppStorage("defaultComposeAccount") private var defaultAccount = ""
    @Binding var pullAction: InboxPullAction
    @AppStorage(UndoSend.key) private var undoDelay = UndoSend.defaultDelay
    @AppStorage(AfterSettle.key) private var afterSettle = AfterSettle.returnToList

    private var supportsPull: Bool {
        if #available(iOS 18, *) { return true }
        return false
    }
    var body: some View {
        Form {
            Section {
                NavigationLink("Notifications") { MailNotificationSettingsView() }
                NavigationLink("Accounts") { AccountsSettingsView() }
                NavigationLink("Blocked Senders") { BlockedSendersView() }
                NavigationLink("Snooze settings") { SnoozeSettingsView() }
                NavigationLink("Swipe actions") { SwipeSettingsView() }
                Picker("Default From", selection: Binding(get: {
                    store.accounts.first { $0.id == defaultAccount }?.id ?? store.accounts.first?.id ?? ""
                }, set: { defaultAccount = $0 })) {
                    ForEach(store.accounts) { Text($0.address).tag($0.id) }
                }
                Picker("Undo send", selection: $undoDelay) {
                    ForEach(UndoSend.choices, id: \.self) { Text($0 == 0 ? "Off" : "\($0) seconds").tag($0) }
                }
                Picker("After settling", selection: $afterSettle) {
                    ForEach(AfterSettle.allCases) { Text($0.title).tag($0) }
                }
            }
            Section("Labs") {
                Picker("Inbox pull-down", selection: $pullAction) {
                    ForEach(InboxPullAction.allCases) { action in
                        Text(action.title).tag(action)
                    }
                }
                .disabled(!supportsPull)
                if !supportsPull { Text("Pull actions require iOS 18 or later.").font(.footnote).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }
}

private struct MailNotificationSettingsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var settings: UNNotificationSettings?
    @State private var requesting = false
    @State private var permissionError: String?

    var body: some View {
        Form {
            Section {
                if let settings {
                    if settings.authorizationStatus == .notDetermined {
                        Button("Enable notifications") {
                            Task { await requestAuthorization() }
                        }
                        .disabled(requesting)
                    } else {
                        LabeledContent("Alerts", value: settings.alertSetting == .enabled ? "On" : "Off")
                        LabeledContent("App icon badge", value: settings.badgeSetting == .enabled ? "On" : "Off")
                        Button("Open notification settings") {
                            if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
                        }
                    }
                } else {
                    ProgressView("Checking notification settings")
                }
            } footer: {
                Text("Get a reminder when snoozed mail returns, a reply is overdue, or scheduled mail is due. The app icon badge counts unread Inbox conversations across all accounts.")
            }
            if let permissionError {
                Text(permissionError).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: scenePhase) {
            settings = await UNUserNotificationCenter.current().notificationSettings()
        }
    }

    private func requestAuthorization() async {
        guard !requesting else { return }
        requesting = true
        defer { requesting = false }
        permissionError = nil
        let center = UNUserNotificationCenter.current()
        do {
            if try await center.requestAuthorization(options: [.alert, .sound, .badge]) {
                NotificationCenter.default.post(name: Notification.Name("MailernReminderAuthorizationChanged"), object: nil)
            }
        } catch {
            permissionError = error.localizedDescription
        }
        settings = await center.notificationSettings()
    }
}

@MainActor @Observable
final class InboxPullInteraction {
    @ObservationIgnored var stationary = false
    @ObservationIgnored var touchWasTracked = false
    private var gesture = DeliberatePull()
    private let feedback = UIImpactFeedbackGenerator(style: .soft)
    var distance: CGFloat { gesture.distance }
    var armed: Bool { gesture.armed }
    private(set) var armCount = 0

    func begin(offset: CGFloat, stationary: Bool) {
        gesture.begin(offset: offset, stationary: stationary)
        touchWasTracked = true
        if gesture.eligible { feedback.prepare() }
    }
    func move(distance: CGFloat) {
        let wasArmed = armed
        gesture.move(distance: distance)
        if armed && !wasArmed {
            armCount += 1
            feedback.impactOccurred(intensity: 0.45)
            feedback.prepare()
        }
    }
    func end(distance: CGFloat) -> Bool {
        touchWasTracked = false
        return gesture.end(distance: distance)
    }
    func cancel() { gesture = DeliberatePull(); touchWasTracked = false }
}

struct InboxPullModifier: ViewModifier {
    let mode: InboxPullAction
    let interaction: InboxPullInteraction
    func body(content: Content) -> some View {
        if mode != .off {
            if #available(iOS 18, *) {
                content.onScrollPhaseChange { old, new, context in
                    if new == .tracking && !interaction.touchWasTracked {
                        interaction.begin(
                            offset: context.geometry.contentOffset.y + context.geometry.contentInsets.top,
                            stationary: old == .idle)
                    }
                    interaction.stationary = new == .idle
                    if new == .idle { interaction.cancel() }
                }
                .onDisappear { interaction.cancel() }
            } else {
                content.onDisappear { interaction.cancel() }
            }
        } else {
            content
        }
    }
}

struct PullScrollObserver: UIViewRepresentable {
    let interaction: InboxPullInteraction
    let action: () -> Void
    func makeUIView(context: Context) -> ObserverView { ObserverView() }
    func updateUIView(_ view: ObserverView, context: Context) {
        view.interaction = interaction
        view.action = action
        view.connect()
    }
    static func dismantleUIView(_ view: ObserverView, coordinator: ()) { view.disconnect() }

    final class ObserverView: UIView {
        weak var scrollView: UIScrollView?
        var interaction: InboxPullInteraction?
        var action: () -> Void = {}
        override func didMoveToWindow() { super.didMoveToWindow(); connect() }
        override func didMoveToSuperview() { super.didMoveToSuperview(); connect() }
        func connect() {
            DispatchQueue.main.async { [weak self] in
                guard let self, window != nil else { return }
                var ancestor = superview
                while let view = ancestor {
                    if let scroll = view as? UIScrollView {
                        guard scroll !== scrollView else { return }
                        disconnect()
                        scrollView = scroll
                        scroll.panGestureRecognizer.addTarget(self, action: #selector(panChanged))
                        return
                    }
                    ancestor = view.superview
                }
            }
        }
        func disconnect() {
            scrollView?.panGestureRecognizer.removeTarget(self, action: #selector(panChanged))
            scrollView = nil
        }
        @objc private func panChanged(_ pan: UIPanGestureRecognizer) {
            guard let scrollView, let interaction else { return }
            let offset = scrollView.contentOffset.y + scrollView.adjustedContentInset.top
            switch pan.state {
            case .began:
                if !interaction.touchWasTracked {
                    interaction.begin(offset: offset, stationary: interaction.stationary)
                }
                interaction.move(distance: -offset)
            case .changed: interaction.move(distance: -offset)
            case .ended:
                guard interaction.end(distance: -offset) else { return }
                // Finish the native bounce before presenting, rather than waiting for idle.
                scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: -scrollView.adjustedContentInset.top), animated: false)
                DispatchQueue.main.async { [weak self] in self?.action() }
            case .cancelled, .failed: interaction.cancel()
            default: break
            }
        }
    }
}

struct PullActionIndicator: View {
    let mode: InboxPullAction
    let progress: CGFloat
    let armCount: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
        .phaseAnimator([1.0, 1.09, 1.0], trigger: armCount) { content, scale in
            content.scaleEffect(reduceMotion ? 1 : scale)
        } animation: { _ in .easeInOut(duration: 0.1) }
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
