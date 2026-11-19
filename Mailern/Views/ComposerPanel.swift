import SwiftUI

/// The composer surface. It rises over the screen like a sheet. A pull settles it at the dock, behind the tab bar or
/// the reader toolbar, and a tap or an upward drag on the dock brings it back. One view makes the whole trip, so its
/// top edge follows the finger both ways and the docked draft never shows twice.
@MainActor @Observable final class ComposerPanel {
    struct Request: Identifiable {
        let id = UUID()
        let mode: ComposeMode
        var messageID: UUID?
        var inboxAccountID: String?
    }
    /// The open composer. Nil while no composer shows, also when a draft rests in the dock.
    private(set) var request: Request?
    /// True while the panel covers the screen. The tab bar steps aside, and comes back as soon as the panel heads for
    /// the dock or away.
    private(set) var covering = false
    /// True while the panel is on screen. The reader's toolbar is drawn under the navigation stack's overlay, so
    /// it would show through the panel's edges. It stays hidden until the panel is gone, then slides in.
    private(set) var hidesToolbar = false
    /// True while the panel is open and still. The composer gives the keyboard back then, not while the panel moves.
    private(set) var settled = false
    /// True while a pull holds the panel.
    private(set) var pulling = false
    /// Counts pulls that ended far enough down. The composer then saves its draft and calls `dockReady`.
    private(set) var minimizeRequests = 0
    /// Set by the composer: false while its draft cannot leave, such as during an import or a send.
    var canPull = false
    /// Set by the composer: the height of its navigation bar, with the large title while it shows. A pull starts
    /// there, as on a sheet, and a scroll below it stays a scroll.
    var pullZone: CGFloat = 0
    /// The dock's text for the draft in the panel, shown on the panel's top as it reaches the dock.
    var summary = DockSummary(title: "", recipients: "")
    /// The height of the dock's header. The dock and the panel both measure it, so a text size change applies at once.
    var headerHeight: CGFloat = 64
    /// Where the dock ends, in screen coordinates: the top of the tab bar or toolbar. A change while the panel heads
    /// for the dock, such as a rotation or the toolbar's place, moves the panel's target with it.
    var dockBottom: CGFloat? {
        didSet { if docking, !arrived, dockBottom != oldValue { moveToDock(velocity: 0) } }
    }

    /// Distance of the panel's top edge below its open position. Only the host reads it, so a drag redraws the host
    /// and not the composer.
    fileprivate(set) var offset: CGFloat = 0
    /// True when the panel travels between the dock and the open position, so its top turns into the dock's header.
    fileprivate(set) var morphing = false
    fileprivate var openTop: CGFloat = 0
    fileprivate var height: CGFloat = 1000
    fileprivate var dockOffset: CGFloat { max(0, (dockBottom ?? openTop + height) - headerHeight - openTop) }
    private var pullStart: CGFloat = 0
    private var generation = 0
    private var docking = false
    private var arrived = false
    private var ready = false

    func present(_ mode: ComposeMode, messageID: UUID? = nil, inboxAccountID: String? = nil) {
        guard request == nil else { return }
        start(Request(mode: mode, messageID: messageID, inboxAccountID: inboxAccountID), at: height, morphing: false)
        // Move on the next turn of the run loop, once the panel is drawn at its start.
        DispatchQueue.main.async { self.open() }
    }
    /// Opens the docked draft from the dock.
    func resume(_ id: UUID, summary: DockSummary) {
        guard request == nil else { return }
        self.summary = summary
        start(Request(mode: .draft(id)), at: dockOffset, morphing: true)
        DispatchQueue.main.async { self.open() }
    }
    /// An upward drag on the dock: the panel takes the dock's place and follows the finger.
    func beginResume(_ id: UUID, summary: DockSummary) {
        guard request == nil else { return }
        self.summary = summary
        start(Request(mode: .draft(id)), at: dockOffset, morphing: true)
    }
    func followDock(_ translation: CGFloat) {
        guard request != nil, !settled else { return }
        offset = max(0, dockOffset + translation)
    }
    /// Ends a drag on the dock. A drag the system canceled goes back to the dock.
    func endDockDrag(translation: CGFloat = 0, predicted: CGFloat = 0, velocity: CGFloat = 0) {
        guard request != nil, !settled, !docking else { return }
        if predicted < -80 || translation < -dockOffset / 3 { open(velocity: velocity) }
        else { dock(velocity: velocity); dockReady() }
    }
    /// Moves the panel to the dock. It leaves once the composer has saved and called `dockReady`.
    func dock(velocity: CGFloat = 0) {
        docking = true
        arrived = false
        ready = false
        settled = false
        morphing = true
        withAnimation(.smooth(duration: 0.3)) { covering = false }
        moveToDock(velocity: velocity)
    }
    func dockReady() {
        ready = true
        finishDocking()
    }
    /// Brings the panel up, when it first appears, after a canceled pull, or after a save failed on its way down.
    func open(velocity: CGFloat = 0) {
        guard request != nil else { return }
        docking = false
        withAnimation(.smooth(duration: 0.3)) { covering = true }
        move(to: 0, velocity: velocity) { [weak self] in self?.settled = true }
    }
    /// Slides the panel off the screen, after a send, a discard, or Save Draft.
    func close() {
        guard request != nil else { return }
        docking = false
        settled = false
        withAnimation(.smooth(duration: 0.3)) { covering = false }
        move(to: height) { [weak self] in self?.leave() }
    }

    fileprivate func pullChanged(start: CGFloat, translation: CGSize) {
        if !pulling {
            guard settled, canPull, start < openTop + pullZone, translation.height > 0,
                  translation.height > abs(translation.width) else { return }
            pulling = true
            settled = false
            morphing = true
            pullStart = translation.height
        }
        let distance = translation.height - pullStart
        // Above the open position the panel resists, like a sheet.
        offset = distance >= 0 ? distance : -sqrt(-distance)
    }
    /// Ends a pull. A pull the system canceled goes back up.
    fileprivate func pullEnded(translation: CGFloat = 0, predicted: CGFloat = 0, velocity: CGFloat = 0) {
        guard pulling else { return }
        pulling = false
        if offset > 120 || (predicted - translation > 160 && offset > 24) {
            dock(velocity: velocity)
            minimizeRequests += 1
        } else { open(velocity: velocity) }
    }

    private func start(_ request: Request, at offset: CGFloat, morphing: Bool) {
        generation += 1
        docking = false
        self.request = request
        self.offset = offset
        self.morphing = morphing
        settled = false
        hidesToolbar = true
        withAnimation(.smooth(duration: 0.3)) { covering = true }
    }
    private func moveToDock(velocity: CGFloat) {
        move(to: dockOffset, velocity: velocity) { [weak self] in
            self?.arrived = true
            self?.finishDocking()
        }
    }
    private func finishDocking() {
        guard docking, arrived, ready else { return }
        leave()
    }
    private func leave() {
        docking = false
        request = nil
        morphing = false
        offset = 0
        withAnimation(.smooth(duration: 0.3)) { hidesToolbar = false }
    }
    private func move(to target: CGFloat, velocity: CGFloat = 0, then done: @escaping () -> Void) {
        generation += 1
        let current = generation
        // Test runs turn animations off. The panel then moves at once, as UIKit views do.
        guard UIView.areAnimationsEnabled else {
            offset = target
            DispatchQueue.main.async { if self.generation == current { done() } }
            return
        }
        let distance = target - offset
        // The spring starts at the finger's speed, as a share of the distance left.
        let relative = abs(distance) > 1 ? velocity / distance : 0
        withAnimation(.interpolatingSpring(duration: 0.4, bounce: 0, initialVelocity: relative), completionCriteria: .logicallyComplete) {
            offset = target
        } completion: { [weak self] in
            guard self?.generation == current else { return }
            done()
        }
    }

    /// The panel's own background, which dark mode lifts above the screen behind it, as for a sheet.
    static let background = Color(uiColor: UIColor { traits in
        UIColor.systemBackground.resolvedColor(with: traits.modifyingTraits { $0.userInterfaceLevel = .elevated })
    })
    static let radius: CGFloat = 30
}

/// The dock's text: the draft's subject and recipients.
struct DockSummary: Equatable {
    var title: String
    var recipients: String
}

extension DockSummary {
    init(_ draft: ComposerDraft) {
        let fields = [("To", draft.to), ("Cc", draft.cc), ("Bcc", draft.bcc)].compactMap { label, field in
            let addresses = ComposerDraft.addresses(field)
            return addresses.isEmpty ? nil : "\(label): \(addresses.joined(separator: ", "))"
        }
        self.init(title: draft.title, recipients: fields.isEmpty ? "No recipients" : fields.joined(separator: "  "))
    }
}

/// The top of the docked panel: the subject and the recipients. The dock and the panel draw it the same way, so the
/// panel turns into the dock without a jump.
struct DockHeader: View {
    let summary: DockSummary
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(summary.title).font(.headline).lineLimit(1)
            Text(summary.recipients).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20).padding(.top, 17).padding(.bottom, 10)
    }
}

struct PanelGrabber: View {
    var body: some View {
        Capsule().fill(.tertiary).frame(width: 36, height: 5).padding(.top, 6)
            .frame(maxWidth: .infinity, alignment: .top)
    }
}

/// Shows the open composer over one tab's screens and under its tab bar. Only the selected tab hosts it.
struct ComposerPanelHost: View {
    @Environment(ComposerPanel.self) private var panel
    @GestureState private var dragging = false
    var body: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { record(proxy) }
                .onChange(of: proxy.size) { _, _ in record(proxy) }
            if let request = panel.request {
                let openTop = Self.statusBar + 10
                let dockOffset = max(1, panel.dockOffset)
                ZStack(alignment: .top) {
                    PanelDim(offset: panel.offset, dockOffset: dockOffset)
                    PanelMotion(offset: panel.offset, dockOffset: dockOffset, morphing: panel.morphing) {
                        ComposerView(mode: request.mode, messageID: request.messageID, inboxAccountID: request.inboxAccountID)
                            .id(request.id)
                            // The tab bar comes back while the panel heads for the dock. Its inset must not move the
                            // composer's content on the way.
                            .ignoresSafeArea(.container, edges: .bottom)
                    } header: {
                        DockHeader(summary: panel.summary)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { panel.headerHeight = $0 }
                            .allowsHitTesting(false)
                    }
                    .frame(height: proxy.size.height - openTop)
                    .padding(.top, openTop)
                    // A pull starts on the grabber, the buttons, or the title, as on a sheet.
                    .simultaneousGesture(DragGesture(minimumDistance: 8, coordinateSpace: .global)
                        .updating($dragging) { _, state, _ in state = true }
                        .onChanged { value in
                            panel.pullChanged(start: value.startLocation.y, translation: value.translation)
                        }
                        .onEnded { value in
                            panel.pullEnded(translation: value.translation.height, predicted: value.predictedEndTranslation.height,
                                            velocity: value.velocity.height)
                        })
                }
            }
        }
        .ignoresSafeArea(.container)
        .ignoresSafeArea(.keyboard)
        // `onEnded` does not run for a pull the system cancels. It runs first for a pull that ends normally, so this
        // only catches a canceled one, which goes back up.
        .onChange(of: dragging) { _, active in
            if !active { DispatchQueue.main.async { panel.pullEnded() } }
        }
    }
    /// The panel stops below the status bar, as a sheet does. A reader that ignores the safe area reports no insets,
    /// so the window's inset decides.
    private static var statusBar: CGFloat {
        let scene = UIApplication.shared.connectedScenes.lazy.compactMap { $0 as? UIWindowScene }.first
        return scene?.keyWindow?.safeAreaInsets.top ?? 0
    }
    private func record(_ proxy: GeometryProxy) {
        panel.openTop = Self.statusBar + 10
        panel.height = proxy.size.height
    }
}

/// Moves the panel and derives its fades from the offset on every animation frame. Fades computed from the target
/// offset would play side by side, so both headers would show during a spring.
private struct PanelMotion<Content: View, Header: View>: View, Animatable {
    var offset: CGFloat
    let dockOffset: CGFloat
    let morphing: Bool
    @ViewBuilder let content: Content
    @ViewBuilder let header: Header
    var animatableData: CGFloat {
        get { offset }
        set { offset = newValue }
    }
    var body: some View {
        // 0 while open, 1 at the dock. Near the dock the composer fades out, and only then the dock's header fades
        // in, so their text never shows on top of each other.
        let docking = min(1, max(0, offset / dockOffset))
        let shape = UnevenRoundedRectangle(topLeadingRadius: ComposerPanel.radius, topTrailingRadius: ComposerPanel.radius)
        ZStack(alignment: .top) {
            content.opacity(morphing ? 1 - min(1, max(0, (docking - 0.55) / 0.25)) : 1)
            header.opacity(morphing ? min(1, max(0, (docking - 0.8) / 0.2)) : 0)
            PanelGrabber().allowsHitTesting(false)
        }
        .clipShape(shape)
        .background(alignment: .top) {
            shape.fill(ComposerPanel.background)
                .shadow(color: .black.opacity(0.15), radius: 12)
                // Room for the rubber band above the open position.
                .padding(.bottom, -100)
        }
        .offset(y: offset)
    }
}

/// Dims the screen behind the panel, following its offset on every frame like `PanelMotion`. It only takes taps while
/// the panel covers most of the screen, so taps reach the mailbox while the panel heads for the dock.
private struct PanelDim: View, Animatable {
    var offset: CGFloat
    let dockOffset: CGFloat
    var animatableData: CGFloat {
        get { offset }
        set { offset = newValue }
    }
    var body: some View {
        let docking = min(1, max(0, offset / dockOffset))
        Color.black.opacity(0.2 * (1 - docking)).contentShape(.rect)
            .allowsHitTesting(docking < 0.5)
    }
}
