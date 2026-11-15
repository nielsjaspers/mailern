import SwiftUI

struct DraftsView: View {
    @Environment(DraftStore.self) private var drafts
    @Environment(\.dismiss) private var dismiss
    @State private var composer: ComposeMode?
    var body: some View {
        NavigationStack {
            List {
                ForEach(drafts.drafts) { draft in
                    Button {
                        composer = .draft(draft.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(draft.subject.isEmpty ? "New Message" : draft.subject).font(.headline)
                            Text(draft.to.isEmpty ? "No recipients" : draft.to).font(.subheadline).foregroundStyle(.secondary)
                            Text(draft.text).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                        }.foregroundStyle(.primary).padding(.vertical, 6)
                    }
                    .swipeActions { Button("Delete", role: .destructive) { drafts.delete(draft.id) } }
                }
            }
            .overlay { if drafts.drafts.isEmpty { ContentUnavailableView("No drafts", systemImage: "doc") } }
            .navigationTitle("Drafts")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .sheet(item: $composer) { ComposerView(mode: $0) }
        .alert("Draft storage", isPresented: Binding(get: { drafts.error != nil }, set: { if !$0 { drafts.error = nil } })) {
            Button("OK") { drafts.error = nil }
        } message: { Text(drafts.error ?? "") }
    }
}

struct ComposerTransition: ViewModifier {
    let source: String
    let namespace: Namespace.ID
    func body(content: Content) -> some View {
        if #available(iOS 18, *) { content.navigationTransition(.zoom(sourceID: source, in: namespace)) }
        else { content }
    }
}

struct ComposerSource: ViewModifier {
    let source: String
    let namespace: Namespace.ID
    func body(content: Content) -> some View {
        if #available(iOS 18, *) { content.matchedTransitionSource(id: source, in: namespace) }
        else { content }
    }
}
