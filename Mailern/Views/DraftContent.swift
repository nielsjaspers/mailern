import SwiftUI

struct DraftRow: View {
    @Environment(MailStore.self) private var store
    let draft: ComposerDraft
    var body: some View {
        MailboxRow(
            avatar: SenderAvatar(name: draft.to, symbol: "square.and.pencil", tint: .orange, label: "Draft"),
            title: draft.to.isEmpty ? "No recipients" : draft.to, date: draft.updatedAt,
            subject: draft.title, snippet: draft.text.snippet, account: store.account(draft.accountID),
            pinned: draft.pinned == true, snoozedUntil: draft.snoozedUntil
        )
    }
}

struct DraftCard: View {
    @Environment(MailStore.self) private var store
    let draft: ComposerDraft
    let edit: () -> Void
    let discard: () -> Void
    var deleting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Draft", systemImage: "square.and.pencil").foregroundStyle(.orange)
                Spacer()
                Text(draft.updatedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .font(.caption).foregroundStyle(.secondary)
            }.font(.subheadline.weight(.semibold))
            DraftDetails(draft: draft)
            HStack {
                Button("Edit draft", systemImage: "square.and.pencil", action: edit)
                    .buttonStyle(.bordered).tint(.orange)
                Spacer()
                Button("Discard draft", systemImage: "trash", role: .destructive, action: discard)
                    .labelStyle(.iconOnly)
            }.disabled(deleting)
        }
        .padding(18)
        .background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 18))
        .accessibilityIdentifier("draft-card-\(draft.id)")
    }
}

/// The addresses, subject, body, and attachments of a draft or scheduled message.
struct DraftDetails: View {
    @Environment(MailStore.self) private var store
    let draft: ComposerDraft

    var body: some View {
        Text("From: \(store.account(draft.accountID).address)").font(.caption).foregroundStyle(.secondary)
        Text(draft.to.isEmpty ? "No recipients" : "To: \(draft.to)").font(.caption).foregroundStyle(.secondary)
        if !draft.cc.isEmpty { Text("Cc: \(draft.cc)").font(.caption).foregroundStyle(.secondary) }
        if !draft.bcc.isEmpty { Text("Bcc: \(draft.bcc)").font(.caption).foregroundStyle(.secondary) }
        Text(draft.title).font(.headline)
        if !draft.text.isEmpty {
            Group {
                if let richText = draft.richText {
                    RichMessageText(text: RichText.decode(richText, fallback: draft.text))
                } else { Text(draft.text) }
            }.textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
        if !draft.attachments.isEmpty { AttachmentList(attachments: draft.attachments) }
    }
}

struct DraftThreadView: View {
    @Environment(DraftStore.self) private var drafts
    @Environment(ComposerPanel.self) private var panel
    @Environment(\.dismiss) private var dismiss
    let id: UUID
    @State private var deleting = false
    @State private var settling: DraftDiscard?
    @State private var snoozing = false

    var body: some View {
        Group {
            if let draft = drafts.drafts.first(where: { $0.id == id }) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        Text(draft.title).font(.title2.bold()).textSelection(.enabled)
                        DraftCard(draft: draft, edit: { panel.present(.draft(id)) }, discard: {
                            Task {
                                deleting = true
                                defer { deleting = false }
                                await drafts.delete(id)
                            }
                        }, deleting: deleting)
                    }.padding(18)
                }.background(Color(uiColor: .systemGroupedBackground))
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button(draft.pinned == true ? "Unpin" : "Pin", systemImage: "pin") { Task { await drafts.togglePin(id) } }
                            if draft.snoozedUntil != nil {
                                Button("Restore to Inbox", systemImage: "tray") { Task { if await drafts.restore(id) { dismiss() } } }
                            }
                        } label: { Label("More actions", systemImage: "ellipsis.circle") }
                    }
                    ToolbarItemGroup(placement: .bottomBar) {
                        Button("Settle", systemImage: "checkmark") { settling = DraftDiscard(ids: [id], action: .move(.settled)) }
                        Spacer()
                        Button("Snooze", systemImage: "clock") { snoozing = true }
                    }
                }
            } else { ContentUnavailableView("Draft unavailable", systemImage: "square.and.pencil") }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .modifier(DraftStorageAlert(active: true))
        .modifier(DiscardDraftsConfirmation(request: $settling))
        .sheet(isPresented: $snoozing) { SnoozeView(ids: [], draftIDs: [id], onSnooze: { dismiss() }) }
        // Leave once the draft is gone, whether it was discarded here, settled, or sent or deleted from a composer.
        .onChange(of: panel.request == nil && !drafts.drafts.contains { $0.id == id }) { _, gone in if gone { dismiss() } }
    }
}

struct DraftStorageAlert: ViewModifier {
    @Environment(DraftStore.self) private var drafts
    @Environment(ComposerPanel.self) private var panel
    var active: Bool
    func body(content: Content) -> some View {
        content.alert("Draft storage", isPresented: Binding(
            // An open composer shows the error itself.
            get: { active && panel.request == nil && drafts.error != nil },
            set: { if !$0 && active { drafts.error = nil } }
        )) {
            Button("Retry") { Task { await drafts.reload() } }
            Button("OK", role: .cancel) { drafts.error = nil }
        } message: { Text(drafts.error ?? "") }
    }
}

/// A minimized draft: the composer panel resting at the bottom of the screen. Its top shows above the tab bar or
/// toolbar, which float over the rest of it. A tap or an upward drag hands it to `ComposerPanel`, which takes its
/// place and follows the finger.
struct DraftDock: View {
    @Environment(DraftStore.self) private var drafts
    @Environment(ComposerPanel.self) private var panel
    @State private var dragging = false
    @GestureState private var touching = false
    @State private var shown = false
    @State private var bottom: CGFloat?
    var body: some View {
        // The container always exists, so it measures the dock's place even while no draft rests there.
        ZStack {
            // While the panel is up, the dock ignores the keyboard, so keyboard changes never relayout the covered
            // dock. Changing its bar while UIKit lays out the keyboard deadlocked the app once.
            if panel.request != nil || !SoftwareKeyboard.shared.visible,
               let docked = drafts.docked?.id, !drafts.deleting.contains(docked),
               let draft = drafts.drafts.first(where: { $0.id == docked }) {
                let summary = DockSummary(draft)
                Button { if panel.request == nil, !drafts.deleting.contains(draft.id) { panel.resume(draft.id, summary: summary) } } label: {
                    DockHeader(summary: summary)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { panel.headerHeight = $0 }
                        .background(alignment: .top) {
                            UnevenRoundedRectangle(topLeadingRadius: ComposerPanel.radius, topTrailingRadius: ComposerPanel.radius)
                                .fill(ComposerPanel.background)
                                .shadow(color: .black.opacity(0.15), radius: 12)
                                .padding(.bottom, -200)
                                // Full width in landscape too, like the panel it turns into.
                                .ignoresSafeArea(edges: [.horizontal, .bottom])
                        }
                        .overlay(alignment: .top) { PanelGrabber() }
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                // Keep the resting draft behind a closing panel. The sliding panel reveals it as it leaves.
                .opacity(panel.showsDock ? 1 : 0)
                .highPriorityGesture(DragGesture(minimumDistance: 10, coordinateSpace: .global)
                    .updating($touching) { _, state, _ in state = true }
                    .onChanged { value in
                        if !dragging {
                            guard abs(value.translation.height) > abs(value.translation.width), value.translation.height < 0,
                                  panel.request == nil, !drafts.deleting.contains(draft.id) else { return }
                            dragging = true
                            panel.beginResume(draft.id, summary: summary)
                        }
                        panel.followDock(value.translation.height)
                    }
                    .onEnded { value in
                        guard dragging else { return }
                        dragging = false
                        panel.endDockDrag(translation: value.translation.height, predicted: value.predictedEndTranslation.height,
                                          velocity: value.velocity.height)
                    })
                .accessibilityLabel("Resume draft, \(draft.title)")
                .accessibilityValue(summary.recipients)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { bottom = $0; report() }
        .onAppear { shown = true; report() }
        .onDisappear { shown = false }
        // `onEnded` does not run for a drag the system cancels. The panel then goes back to the dock.
        .onChange(of: touching) { _, active in
            guard !active else { return }
            DispatchQueue.main.async {
                guard dragging else { return }
                dragging = false
                panel.endDockDrag()
            }
        }
    }
    /// Tells the panel where to stop. Only the screen on show counts. While the panel covers it, the dock follows
    /// the layout without the tab bar, and the panel retargets once the tab bar comes back.
    private func report() {
        if shown, let bottom { panel.dockBottom = bottom }
    }
}

/// Whether the keyboard is up, so the dock can step aside instead of riding above it. One shared observer, created at
/// launch by `draftDock`, because a dock created while the keyboard is up would miss the notification.
@MainActor @Observable final class SoftwareKeyboard {
    static let shared = SoftwareKeyboard()
    private(set) var visible = false
    private func set(_ visible: Bool) {
        guard visible != self.visible else { return }
        withAnimation(.easeOut(duration: 0.25)) { self.visible = visible }
    }
    private init() {
        let center = NotificationCenter.default
        // The dock fades in step with the keyboard, so its place is not left empty while the keyboard moves.
        center.addObserver(forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { SoftwareKeyboard.shared.set(true) }
        }
        center.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { SoftwareKeyboard.shared.set(false) }
        }
    }
}

extension View {
    /// Places the dock at the bottom. On iOS 26 and later it is a bar, so the scroll edge effect stays behind it
    /// instead of fading its text.
    func draftDock() -> some View { modifier(DraftDockBar()) }
}

private struct DraftDockBar: ViewModifier {
    @Environment(ComposerPanel.self) private var panel
    func body(content: Content) -> some View {
        let _ = SoftwareKeyboard.shared
        Group {
            if #available(iOS 26, *) { content.safeAreaBar(edge: .bottom, spacing: 0) { DraftDock() } }
            else { content.safeAreaInset(edge: .bottom, spacing: 0) { DraftDock() } }
        }
        // A bottom toolbar draws under the navigation stack's overlay, so it would show through the panel's edges.
        // It stays hidden while the panel is on screen and slides in once it is gone.
        .toolbar(panel.hidesToolbar ? .hidden : .automatic, for: .bottomBar)
    }
}
