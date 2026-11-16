import SwiftUI

struct SettleDraftConfirmation: ViewModifier {
    @Environment(MailStore.self) private var store
    @Environment(DraftStore.self) private var drafts
    @Binding var ids: Set<UUID>
    var onSettle: () -> Void = {}

    func body(content: Content) -> some View {
        let targets = ids
        let hasConversations = targets.contains { store.conversation($0) != nil }
        return content.alert(hasConversations ? "Discard drafts and settle?" : "Discard draft?", isPresented: Binding(
            get: { !ids.isEmpty }, set: { if !$0 { ids = [] } }
        )) {
            Button(hasConversations ? "Discard drafts and settle" : "Discard draft", role: .destructive) {
                Task {
                    guard !hasConversations || !store.needsReload else { store.reload(); return }
                    guard await drafts.discardForSettling(targets) else { return }
                    store.apply(ids: targets, action: .move(.settled))
                    onSettle()
                }
            }
            Button("Cancel", role: .cancel) { ids = [] }
        }
    }
}
