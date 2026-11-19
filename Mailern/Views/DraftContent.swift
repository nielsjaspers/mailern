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
    @Environment(\.dismiss) private var dismiss
    let id: UUID
    @State private var mode: ComposeMode?
    @State private var deleting = false
    @State private var settling: DraftDiscard?
    @State private var snoozing = false

    var body: some View {
        Group {
            if let draft = drafts.drafts.first(where: { $0.id == id }) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        Text(draft.title).font(.title2.bold()).textSelection(.enabled)
                        DraftCard(draft: draft, edit: { mode = .draft(id) }, discard: {
                            // The dock must not reopen a draft while it is being discarded.
                            if drafts.docked?.id == id { drafts.docked = nil }
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
        .modifier(DraftStorageAlert(active: mode == nil))
        .modifier(DiscardDraftsConfirmation(request: $settling))
        .sheet(isPresented: $snoozing) { SnoozeView(ids: [], draftIDs: [id], onSnooze: { dismiss() }) }
        .sheet(item: $mode) { ComposerView(mode: $0) }
        // Leave once the draft is gone, whether it was discarded here, settled, or sent or deleted from a composer,
        // including one the dock opened.
        .onChange(of: mode == nil && !drafts.drafts.contains { $0.id == id }) { _, gone in if gone { dismiss() } }
    }
}

struct DraftStorageAlert: ViewModifier {
    @Environment(DraftStore.self) private var drafts
    var active: Bool
    func body(content: Content) -> some View {
        content.alert("Draft storage", isPresented: Binding(
            // Any open composer shows the error itself, including one the dock opened over this screen.
            get: { active && !drafts.composerOpen && drafts.error != nil },
            set: { if !$0 && active { drafts.error = nil } }
        )) {
            Button("Retry") { Task { await drafts.reload() } }
            Button("OK", role: .cancel) { drafts.error = nil }
        } message: { Text(drafts.error ?? "") }
    }
}

/// A minimized draft: the composer sheet resting at the bottom of the screen. Its top edge shows above the tab bar or
/// toolbar, which float over the rest of it. It also sits under an open composer, so pulling that sheet down
/// reveals it in place.
struct DraftDock: View {
    @Environment(DraftStore.self) private var drafts
    let open: (UUID) -> Void
    @GestureState(resetTransaction: Transaction(animation: .snappy)) private var lift: CGFloat = 0
    /// Set when the dock opens the composer: the dock holds this lift while the sheet rises, and its header hides at
    /// once, so the rising sheet's header is the only one.
    @State private var handoff: CGFloat?
    private static let radius: CGFloat = 30
    /// How far a drag lifts the dock. The sheet background runs this far past the bottom of the screen.
    private static let maxLift: CGFloat = 120
    /// The composer sheet's own background, which dark mode lifts above the screen behind it.
    private static let sheet = UIColor { traits in
        UIColor.systemBackground.resolvedColor(with: traits.modifyingTraits { $0.userInterfaceLevel = .elevated })
    }
    var body: some View {
        // The container always exists, so the reset runs even while the keyboard has removed the dock.
        ZStack {
            if let draft = [drafts.preview, drafts.docked?.id].lazy.compactMap({ id in drafts.drafts.first { $0.id == id } }).first,
               !SoftwareKeyboard.shared.visible {
                let id = draft.id
                let summary = recipients(draft)
                Button { resume(id) } label: {
                    VStack(spacing: 0) {
                        Capsule().fill(.tertiary).frame(width: 36, height: 5).padding(.top, 6)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(draft.title).font(.headline).lineLimit(1)
                            Text(summary).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20).padding(.top, 6).padding(.bottom, 10)
                    }
                    .opacity(handoff == nil ? 1 : 0)
                    // The drag's spring back must not fade the header out.
                    .transaction { $0.animation = nil }
                    .background(alignment: .top) {
                        UnevenRoundedRectangle(topLeadingRadius: Self.radius, topTrailingRadius: Self.radius)
                            .fill(Color(uiColor: Self.sheet))
                            .shadow(color: .black.opacity(0.15), radius: 12)
                            .padding(.bottom, -Self.maxLift)
                            .ignoresSafeArea(edges: .bottom)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .offset(y: handoff ?? lift)
                // The sheet follows an upward drag, then opens. A drag never counts as a tap.
                .highPriorityGesture(DragGesture(minimumDistance: 10)
                    .updating($lift) { value, lift, _ in if Self.vertical(value) { lift = Self.lift(value.translation.height) } }
                    .onEnded { value in
                        guard Self.vertical(value), value.translation.height < 0, value.predictedEndTranslation.height < -40 else { return }
                        resume(id, holding: Self.lift(value.translation.height))
                    })
                // Fade out as the composer rises over the dock, and back in as a pull reveals it. Only this fade is
                // animated, so the header hides at once.
                .animation(.easeOut(duration: 0.25)) { $0.opacity(drafts.sheetOverDock ? 0 : 1) }
                .accessibilityLabel("Resume draft, \(draft.title)")
                .accessibilityValue(summary)
            }
        }
        .onChange(of: drafts.sheetOverDock) { _, covered in if !covered { handoff = nil } }
    }
    private static func vertical(_ value: DragGesture.Value) -> Bool { abs(value.translation.height) > abs(value.translation.width) }
    private static func lift(_ translation: CGFloat) -> CGFloat { max(-maxLift, min(0, translation) * 0.5) }
    private func resume(_ id: UUID, holding lift: CGFloat = 0) {
        handoff = lift
        // Present after the dock has drawn without its header, so the rising sheet's header is the only one.
        DispatchQueue.main.async { open(id) }
    }
    private func recipients(_ draft: ComposerDraft) -> String {
        let fields = [("To", draft.to), ("Cc", draft.cc), ("Bcc", draft.bcc)].map { ($0, ComposerDraft.addresses($1)) }
        guard let (label, addresses) = fields.first(where: { !$0.1.isEmpty }) else { return "No recipients" }
        return "\(label): \(addresses.joined(separator: ", "))"
    }
}

/// Whether the keyboard is up, so the dock can step aside instead of riding above it. One shared observer, created at
/// launch by `draftDock`, because a dock created while the keyboard is up would miss the notification.
@MainActor @Observable final class SoftwareKeyboard {
    static let shared = SoftwareKeyboard()
    private(set) var visible = false
    private init() {
        let center = NotificationCenter.default
        center.addObserver(forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { SoftwareKeyboard.shared.visible = true }
        }
        center.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { SoftwareKeyboard.shared.visible = false }
        }
    }
}

extension View {
    /// Places the dock at the bottom. On iOS 26 and later it is a bar, so the scroll edge effect stays behind it
    /// instead of fading its text.
    @ViewBuilder func draftDock(open: @escaping (UUID) -> Void) -> some View {
        let _ = SoftwareKeyboard.shared
        if #available(iOS 26, *) { safeAreaBar(edge: .bottom, spacing: 0) { DraftDock(open: open) } }
        else { safeAreaInset(edge: .bottom, spacing: 0) { DraftDock(open: open) } }
    }
}
