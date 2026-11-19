import UIKit

@MainActor
enum NotificationSettleConfirmation {
    static func handle(id: String, token: String, box: ReminderMailbox,
                       isCurrent: @escaping @MainActor () -> Bool = { true }) async {
        await box.drafts.finishPendingWrites()
        guard isCurrent(), MailReminder.isActionable(id: id, token: token, mail: box.mail),
              let uuid = UUID(uuidString: String(id.dropFirst("conversation.".count))) else { return }
        guard !box.mail.needsReload, !box.drafts.needsReload else {
            await explain("Open Mailern and retry loading mail and drafts before settling this conversation.", isCurrent: isCurrent)
            return
        }
        let replies = savedReplies(to: uuid, in: box.drafts)
        guard !replies.isEmpty else {
            if !MailReminder.act(id: id, token: token, action: "settle", mail: box.mail) {
                await explain(box.mail.error ?? "Open the conversation to try again.", isCurrent: isCurrent)
            }
            return
        }

        let alert = UIAlertController(title: "Discard drafts and settle?", message: box.mail.conversation(uuid)?.effectiveSubject,
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Discard drafts and settle", style: .destructive) { _ in
            Task { @MainActor in
                let committed = await box.drafts.discardDrafts(for: [uuid]) { discarded in
                    guard isCurrent(), !box.mail.needsReload,
                          MailReminder.isActionable(id: id, token: token, mail: box.mail),
                          discarded == Set(replies.map(\.id)),
                          savedReplies(to: uuid, in: box.drafts) == replies else { return false }
                    return box.mail.apply(ids: [uuid], action: .move(.settled), discarding: discarded)
                }
                if !committed {
                    await explain(box.drafts.error ?? box.mail.error ?? "The conversation or its drafts changed. Open the conversation to settle it.", isCurrent: isCurrent)
                }
            }
        })
        await present(alert) {
            isCurrent() && MailReminder.isActionable(id: id, token: token, mail: box.mail)
                && savedReplies(to: uuid, in: box.drafts) == replies
        }
    }

    private static func savedReplies(to id: UUID, in drafts: DraftStore) -> [ComposerDraft] {
        drafts.drafts.filter { $0.mode.replyID == id }
    }

    private static func explain(_ message: String, isCurrent: @escaping @MainActor () -> Bool) async {
        let alert = UIAlertController(title: "Couldn’t settle conversation", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        await present(alert, isCurrent: isCurrent)
    }

    private static func present(_ alert: UIAlertController, isCurrent: @escaping @MainActor () -> Bool) async {
        // A foreground notification action can arrive while UIKit is activating the scene or dismissing a sheet.
        let deadline = ContinuousClock.now + .seconds(10)
        while isCurrent(), !Task.isCancelled, ContinuousClock.now < deadline {
            if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }),
               var top = scene.keyWindow?.rootViewController {
                while let presented = top.presentedViewController { top = presented }
                if !top.isBeingDismissed, !top.isBeingPresented, top.viewIfLoaded?.window != nil,
                   !(top is UIAlertController) {
                    top.present(alert, animated: true)
                    return
                }
            }
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
        }
    }
}
