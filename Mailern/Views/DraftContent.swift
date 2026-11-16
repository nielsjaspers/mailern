import SwiftUI

struct DraftRow: View {
    let draft: ComposerDraft
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Color.clear.frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: "square.and.pencil").foregroundStyle(.orange).accessibilityLabel("Draft")
                    Text(draft.to.isEmpty ? "No recipients" : draft.to).font(.subheadline.weight(.medium)).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(draft.updatedAt, format: .dateTime.month(.abbreviated).day()).font(.caption).foregroundStyle(.secondary)
                }
                Text(draft.title).font(.subheadline).lineLimit(1)
                Text(draft.text.replacingOccurrences(of: "\n", with: " ")).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                Text(draft.account.name).font(.caption2).foregroundStyle(.secondary).padding(.top, 2)
            }
        }.padding(.vertical, 1).accessibilityElement(children: .combine)
    }
}

struct DraftCard: View {
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
            Text("From: \(draft.account.address)").font(.caption).foregroundStyle(.secondary)
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

struct DraftThreadView: View {
    @Environment(DraftStore.self) private var drafts
    @Environment(\.dismiss) private var dismiss
    let id: UUID
    @State private var mode: ComposeMode?
    @State private var deleting = false

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
            } else { ContentUnavailableView("Draft unavailable", systemImage: "square.and.pencil") }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .modifier(DraftStorageAlert(active: mode == nil))
        .sheet(item: $mode, onDismiss: {
            if !drafts.drafts.contains(where: { $0.id == id }) { dismiss() }
        }) { ComposerView(mode: $0) }
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
