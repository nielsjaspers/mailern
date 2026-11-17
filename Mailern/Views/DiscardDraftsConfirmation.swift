import SwiftUI

/// A move that would leave reply drafts behind, such as Settle or Move to Trash. Standalone drafts are discarded.
struct DraftDiscard: Equatable {
    var ids: Set<UUID>
    var action: ConversationAction
}

struct DiscardDraftsConfirmation: ViewModifier {
    @Environment(MailStore.self) private var store
    @Environment(DraftStore.self) private var drafts
    @Binding var request: DraftDiscard?
    var onDone: () -> Void = {}

    func body(content: Content) -> some View {
        let pending = request
        let hasConversations = pending?.ids.contains { store.conversation($0) != nil } ?? false
        let move = switch pending?.action {
        case .remove(let mailbox): "move to \(mailbox.title)"
        default: "settle"
        }
        return content.alert(hasConversations ? "Discard drafts and \(move)?" : "Discard draft?", isPresented: Binding(
            get: { request != nil }, set: { if !$0 { request = nil } }
        )) {
            Button(hasConversations ? "Discard drafts and \(move)" : "Discard draft", role: .destructive) {
                guard let pending else { return }
                Task {
                    guard !hasConversations || !store.needsReload else { store.reload(); return }
                    guard await drafts.discardDrafts(for: pending.ids) else { return }
                    store.apply(ids: pending.ids, action: pending.action)
                    onDone()
                }
            }
            Button("Cancel", role: .cancel) { request = nil }
        }
    }
}
