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
                            Task {
                                deleting = true
                                defer { deleting = false }
                                if await drafts.delete(id) { dismiss() }
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
        .modifier(DiscardDraftsConfirmation(request: $settling, onDone: { dismiss() }))
        .sheet(isPresented: $snoozing) { SnoozeView(ids: [], draftIDs: [id], onSnooze: { dismiss() }) }
        .sheet(item: $mode, onDismiss: {
            if !drafts.drafts.contains(where: { $0.id == id }) { dismiss() }
        }) { ComposerView(mode: $0) }
        // The dock can resume this draft in another sheet, so leave when it is deleted or sent there too.
        .onChange(of: drafts.drafts.contains { $0.id == id }) { _, exists in if !exists && mode == nil { dismiss() } }
    }
}

struct DraftStorageAlert: ViewModifier {
    @Environment(DraftStore.self) private var drafts
    var active: Bool
    func body(content: Content) -> some View {
        content.alert("Draft storage", isPresented: Binding(
            get: { active && drafts.error != nil },
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
    @GestureState private var lift: CGFloat = 0
    private static let radius: CGFloat = 30
    /// The composer sheet's own background, which dark mode lifts above the screen behind it.
    private static let sheet = UIColor { traits in
        UIColor.systemBackground.resolvedColor(with: traits.modifyingTraits { $0.userInterfaceLevel = .elevated })
    }
    var body: some View {
        if let id = drafts.docked?.id, let draft = drafts.drafts.first(where: { $0.id == id }), !SoftwareKeyboard.shared.visible {
            Button { open(id) } label: {
                VStack(spacing: 0) {
                    Capsule().fill(.tertiary).frame(width: 36, height: 5).padding(.top, 6)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(draft.title).font(.headline).lineLimit(1)
                        Text(recipients(draft)).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20).padding(.top, 6).padding(.bottom, 10)
                }
                .background(alignment: .top) {
                    // The sheet runs past the bottom of the screen, so lifting it never shows a lower edge.
                    UnevenRoundedRectangle(topLeadingRadius: Self.radius, topTrailingRadius: Self.radius)
                        .fill(Color(uiColor: Self.sheet))
                        .shadow(color: .black.opacity(0.15), radius: 12)
                        .padding(.bottom, -200)
                        .ignoresSafeArea(edges: .bottom)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .offset(y: lift)
            // The sheet follows an upward drag, then opens.
            .simultaneousGesture(DragGesture(minimumDistance: 10)
                .updating($lift) { value, lift, _ in lift = min(0, value.translation.height) * 0.5 }
                .onEnded { value in if value.predictedEndTranslation.height < -40 { open(id) } })
            // Fade out as the composer rises over the dock, and back in as a pull reveals it.
            .opacity(drafts.sheetOverDock ? 0 : 1)
            .animation(.easeOut(duration: 0.25), value: drafts.sheetOverDock)
            .accessibilityLabel("Resume draft, \(draft.title)")
        }
    }
    private func recipients(_ draft: ComposerDraft) -> String {
        let fields = [("To", draft.to), ("Cc", draft.cc), ("Bcc", draft.bcc)]
        guard let (label, value) = fields.first(where: { !$0.1.trimmingCharacters(in: .whitespaces).isEmpty }) else { return "No recipients" }
        return "\(label): \(value)"
    }
}

/// Whether the keyboard is up, so the dock can step aside instead of riding above it. One shared observer, because a
/// dock created while the keyboard is up would miss the notification.
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
        if #available(iOS 26, *) { safeAreaBar(edge: .bottom, spacing: 0) { DraftDock(open: open) } }
        else { safeAreaInset(edge: .bottom, spacing: 0) { DraftDock(open: open) } }
    }
}
