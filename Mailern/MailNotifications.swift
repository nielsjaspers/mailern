import UIKit
import UserNotifications

struct ReminderMailbox {
    let scope: String
    let mail: MailStore
    let drafts: DraftStore
}

@MainActor
final class MailNotifications: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    private static let category = "mailern.conversation"
    private var work: Task<Void, Never>?
    private var dirty = false
    private var cachedSettings: UNNotificationSettings?
    private var backgroundTime: UIBackgroundTaskIdentifier = .invalid
    private var retry: Task<Void, Never>?
    private var mailboxes: [ReminderMailbox] = []
    private var namespace = ""

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        center.delegate = self
        let actions = [UNNotificationAction(identifier: "settle", title: "Settle", options: [.foreground]),
                       UNNotificationAction(identifier: "snooze", title: "Snooze Again", options: [.foreground])]
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.category, actions: actions,
                                                                 intentIdentifiers: [])])
        return true
    }

    func refresh(namespace: String, mailboxes: [ReminderMailbox], checkPermission: Bool = false) {
        if checkPermission { cachedSettings = nil }
        self.namespace = namespace
        self.mailboxes = mailboxes
        if let response = deferredResponse {
            deferredResponse = nil
            Task { await handle(response) }
        }
        dirty = true
        guard work == nil else { return }
        work = Task {
            while dirty {
                dirty = false
                await reconcile()
            }
            work = nil
            endBackgroundTime()
        }
        if UIApplication.shared.applicationState != .active { protectPendingChanges() }
    }

    func finishPendingChanges() async { await work?.value }

    func protectPendingChanges() {
        guard work != nil, backgroundTime == .invalid else { return }
        backgroundTime = UIApplication.shared.beginBackgroundTask(withName: "Save mail reminders") { [weak self] in
            self?.endBackgroundTime()
        }
    }

    private func endBackgroundTime() {
        guard backgroundTime != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTime)
        backgroundTime = .invalid
    }

    private func reconcile() async {
        if cachedSettings == nil {
            let settings = await center.notificationSettings()
            guard !dirty else { return }
            cachedSettings = settings
        }
        guard let settings = cachedSettings else { return }
        if settings.authorizationStatus == .denied {
            let owned = await center.pendingNotificationRequests().filter { $0.identifier.hasPrefix(namespace) }
            guard !dirty else { return }
            center.removePendingNotificationRequests(withIdentifiers: owned.map(\.identifier))
            return
        }
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional ||
                settings.authorizationStatus == .ephemeral else { return }
        let boxes = mailboxes
        let prefix = namespace
        guard let active = boxes.last else { return }
        if settings.badgeSetting == .enabled, !active.mail.needsReload {
            do { try await center.setBadgeCount(active.mail.inboxUnreadCount) } catch { scheduleRetry() }
        }
        let pending = await center.pendingNotificationRequests()
        let delivered = await center.deliveredNotifications()
        guard !dirty else { return }
        func protected(_ identifier: String) -> Bool {
            for box in boxes {
                let base = prefix + box.scope + "/"
                guard identifier.hasPrefix(base) else { continue }
                if box.mail.needsReload { return true }
                return box.drafts.needsReload && !identifier.hasPrefix(base + "conversation.")
            }
            return false
        }
        let reserved = pending.filter { !$0.identifier.hasPrefix(prefix) || protected($0.identifier) }.count
        let now = Date()
        let candidates = boxes.flatMap { box in
            MailReminder.plan(mail: box.mail, drafts: box.drafts, now: now).map { (box.scope, $0) }
        }.sorted { lhs, rhs in
            if lhs.1.date != rhs.1.date { return lhs.1.date < rhs.1.date }
            return (lhs.0, lhs.1.id) < (rhs.0, rhs.1.id)
        }.prefix(max(0, MailReminder.pendingLimit - reserved))
        let activeReminders = candidates.filter { $0.0 == active.scope }.map { $0.1 }
        let badges = MailReminder.badges(for: activeReminders, mail: active.mail)
        let desired = Set(candidates.map { prefix + $0.0 + "/" + $0.1.id })
        let excess = pending.filter { $0.identifier.hasPrefix(prefix) && !protected($0.identifier) && !desired.contains($0.identifier) }
        if !excess.isEmpty { center.removePendingNotificationRequests(withIdentifiers: excess.map(\.identifier)) }
        let stale = delivered.map(\.request).filter { request in
            guard request.identifier.hasPrefix(prefix), !protected(request.identifier) else { return false }
            guard let (box, id, token) = target(request, boxes: boxes, prefix: prefix) else { return true }
            if request.content.categoryIdentifier == Self.category {
                return !MailReminder.isActionable(id: id, token: token, mail: box.mail, now: now)
            }
            // Due mail is sent and snoozed drafts are restored by the foreground processing pass.
            return true
        }
        if !stale.isEmpty { center.removeDeliveredNotifications(withIdentifiers: stale.map(\.identifier)) }
        let existing = Dictionary(uniqueKeysWithValues: pending.map { ($0.identifier, $0.content) })
        for (scope, reminder) in candidates {
            let identifier = prefix + scope + "/" + reminder.id
            if dirty || Task.isCancelled { return }
            let badge = scope == active.scope ? badges[reminder.id].map(NSNumber.init(value:)) : nil
            if let old = existing[identifier], old.userInfo["token"] as? String == reminder.token,
               old.title == reminder.title, old.body == reminder.body, old.badge == badge { continue }
            let content = UNMutableNotificationContent()
            content.title = reminder.title
            content.body = reminder.body
            content.sound = .default
            content.badge = badge
            if reminder.conversationID != nil { content.categoryIdentifier = Self.category }
            content.userInfo = ["scope": scope, "id": reminder.id, "token": reminder.token]
            let interval = reminder.date.timeIntervalSinceNow
            guard interval > 0 else { continue }
            do {
                try await center.add(UNNotificationRequest(identifier: identifier, content: content,
                    trigger: UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)))
            } catch {
                if existing[identifier] != nil { center.removePendingNotificationRequests(withIdentifiers: [identifier]) }
                scheduleRetry()
            }
        }
    }

    private func scheduleRetry() {
        guard retry == nil else { return }
        retry = Task {
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            retry = nil
            refresh(namespace: namespace, mailboxes: mailboxes)
        }
    }

    private func target(_ request: UNNotificationRequest, boxes: [ReminderMailbox], prefix: String)
        -> (ReminderMailbox, String, String)? {
        let info = request.content.userInfo
        guard let scope = info["scope"] as? String, let id = info["id"] as? String,
              let token = info["token"] as? String, request.identifier == prefix + scope + "/" + id,
              let box = boxes.first(where: { $0.scope == scope }) else { return nil }
        return (box, id, token)
    }

    private var deferredResponse: UNNotificationResponse?

    private func handle(_ response: UNNotificationResponse) async {
        guard let (box, id, token) = target(response.notification.request, boxes: mailboxes, prefix: namespace) else { return }
        if response.actionIdentifier == "settle" {
            await NotificationSettleConfirmation.handle(id: id, token: token, box: box) {
                self.mailboxes.contains { $0.mail === box.mail }
            }
        } else {
            _ = MailReminder.act(id: id, token: token, action: response.actionIdentifier, mail: box.mail)
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        if mailboxes.isEmpty { deferredResponse = response } else { await handle(response) }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        let request = notification.request
        guard let (box, id, token) = target(request, boxes: mailboxes, prefix: namespace) else { return [] }
        // Send Later is already being processed when Mailern is open.
        if id.hasPrefix("scheduled.") { return [] }
        if request.content.categoryIdentifier == Self.category,
           !MailReminder.isActionable(id: id, token: token, mail: box.mail) { return [] }
        if id.hasPrefix("draft.") {
            guard let draft = box.drafts.all.first(where: { "draft." + $0.id.uuidString == id }),
                  draft.sendAt == nil, let date = draft.snoozedUntil,
                  String(date.timeIntervalSinceReferenceDate.bitPattern) == token else { return [] }
        }
        return [.banner, .sound]
    }
}
