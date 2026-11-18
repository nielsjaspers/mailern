import Foundation

struct MailReminder: Equatable, Identifiable {
    let id: String
    let date: Date
    let title: String
    let body: String
    let conversationID: UUID?
    let token: String

    static let pendingLimit = 64

    @MainActor static func plan(mail: MailStore, drafts: DraftStore, now: Date = .now) -> [Self] {
        var upcoming: [Self] = []
        func add(_ reminder: Self) {
            upcoming.append(reminder)
            // Keep the planning buffer bounded even when thousands of conversations share a snooze date.
            if upcoming.count == pendingLimit * 2 {
                upcoming.sort(by: precedes)
                upcoming.removeLast(pendingLimit)
            }
        }
        for thread in mail.conversations where thread.removal == nil && thread.workflow == .snoozed {
            guard let date = thread.snoozedUntil, date > now, let latest = thread.messages.last else { continue }
            let waiting = thread.followUp == .waiting
            add(Self(id: "conversation.\(thread.id)", date: date,
                     title: waiting ? "No reply yet" : "Snoozed conversation", body: thread.effectiveSubject,
                     conversationID: thread.id, token: conversationToken(date: date, message: latest.id, waiting: waiting)))
        }
        for draft in drafts.all {
            if let date = draft.sendAt {
                guard date > now, draft.holdingForUndo != true else { continue }
                add(Self(id: "scheduled.\(draft.id)", date: date, title: "Scheduled mail is due",
                         body: "Open Mailern to send “\(draft.title)”.", conversationID: nil, token: dateToken(date)))
            } else if let date = draft.snoozedUntil, date > now {
                add(Self(id: "draft.\(draft.id)", date: date, title: "Snoozed draft", body: draft.title,
                         conversationID: nil, token: dateToken(date)))
            }
        }
        return Array(upcoming.sorted(by: precedes).prefix(pendingLimit))
    }

    private static func precedes(_ left: Self, _ right: Self) -> Bool {
        left.date == right.date ? left.id < right.id : left.date < right.date
    }

    private static func dateToken(_ date: Date) -> String {
        String(date.timeIntervalSinceReferenceDate.bitPattern)
    }

    private static func conversationToken(date: Date, message: UUID, waiting: Bool) -> String {
        "\(message).\(dateToken(date)).\(waiting ? "waiting" : "snoozed")"
    }

    @MainActor private static func target(id: String, token: String, mail: MailStore, now: Date) -> UUID? {
        guard id.hasPrefix("conversation."), let uuid = UUID(uuidString: String(id.dropFirst("conversation.".count))),
              let thread = mail.conversation(uuid), thread.removal == nil, let latest = thread.messages.last else { return nil }
        let date: Date?
        switch thread.workflow {
        case .snoozed: date = thread.snoozedUntil
        case .inbox: date = thread.returnedFromSnoozeAt
        case .settled: return nil
        }
        guard let date, date <= now else { return nil }
        let waiting = thread.followUp == .waiting || thread.followUp == .noReply
        return conversationToken(date: date, message: latest.id, waiting: waiting) == token ? uuid : nil
    }

    @MainActor static func isActionable(id: String, token: String, mail: MailStore, now: Date = .now) -> Bool {
        target(id: id, token: token, mail: mail, now: now) != nil
    }

    @MainActor static func act(id: String, token: String, action: String, mail: MailStore, now: Date = .now) -> Bool {
        guard let uuid = target(id: id, token: token, mail: mail, now: now) else { return false }
        switch action {
        case "settle": return mail.move(uuid, to: .settled)
        case "snooze": return mail.move(uuid, to: .snoozed, until: now.addingTimeInterval(3600))
        default: return false
        }
    }
}
