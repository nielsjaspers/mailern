import SwiftUI

struct SenderAvatar: View {
    let name: String
    var symbol: String?
    /// Overrides the per-sender color: drafts are orange, your own messages teal.
    var tint: Color?
    /// Read by VoiceOver when the avatar itself carries meaning, as on a draft row.
    var label: String?
    var size: CGFloat = 40
    // Teal and orange are reserved for `tint`. Each color must carry white text.
    private static let palette: [Color] = [.indigo, .purple, .pink, .blue, .red]
    private var color: Color {
        if let tint { return tint }
        // Hashable is seeded per launch; a sender must keep one color across launches.
        let hash = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 1_000_003 }
        return Self.palette[hash % Self.palette.count]
    }

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
            .fill(color.gradient)
            .frame(width: size, height: size)
            .overlay {
                Group {
                    if let symbol { Image(systemName: symbol) }
                    else { Text(name.first.map { String($0).uppercased() } ?? "?") }
                }
                .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
            }
            .accessibilityHidden(label == nil)
            .accessibilityLabel(label ?? "")
    }
}

extension SenderAvatar {
    init(message: MailMessage, size: CGFloat) {
        self.init(name: message.sender, tint: message.outgoing ? .teal : nil, size: size)
    }
}

struct MailboxRow: View {
    let avatar: SenderAvatar
    let title: String
    var count = 1
    let date: Date
    let subject: String
    let snippet: String
    let account: String
    var unread = false
    var draft = false
    var pinned = false
    var snoozedUntil: Date?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            avatar.padding(.top, 3)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(title).fontWeight(unread ? .semibold : .regular).lineLimit(1)
                    if count > 1 {
                        Text("\(count)").font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(.secondary.opacity(0.6)) }
                            .fixedSize()
                            .accessibilityLabel("\(count) messages")
                    }
                    Spacer(minLength: 4)
                    if unread {
                        Circle().fill(.teal).frame(width: 8, height: 8)
                            .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 1 }
                    }
                    Text(date.mailboxStamp).font(.caption).foregroundStyle(.secondary).fixedSize()
                }
                HStack(spacing: 6) {
                    Text(subject).font(.subheadline).fontWeight(unread ? .medium : .regular).lineLimit(1)
                    Spacer(minLength: 4)
                    Group {
                        if draft { Image(systemName: "square.and.pencil").foregroundStyle(.orange).accessibilityLabel("Draft") }
                        if pinned { Image(systemName: "pin.fill").foregroundStyle(.orange).accessibilityLabel("Pinned") }
                        if let snoozedUntil {
                            Image(systemName: "clock")
                            Text(snoozedUntil, format: .dateTime.weekday(.abbreviated).hour().minute()).fixedSize()
                        }
                    }.font(.caption2).foregroundStyle(.secondary)
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(snippet).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(account).font(.caption2).foregroundStyle(.tertiary).fixedSize()
                }
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

struct ConversationRow: View {
    let conversation: Conversation
    var hasDraft = false
    var body: some View {
        MailboxRow(
            avatar: SenderAvatar(name: conversation.avatarName),
            title: conversation.participants, count: conversation.messages.count, date: conversation.latest.date,
            subject: conversation.subject, snippet: conversation.latest.body.snippet, account: conversation.account.name,
            unread: conversation.unread, draft: hasDraft, pinned: conversation.pinned, snoozedUntil: conversation.snoozedUntil
        )
        .accessibilityValue(conversation.unread ? "Unread" : "Read")
    }
}

extension Date {
    var mailboxStamp: String {
        Calendar.current.isDateInToday(self)
            ? formatted(date: .omitted, time: .shortened) : formatted(.dateTime.month(.abbreviated).day())
    }
}

extension String {
    var snippet: String {
        split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }
}
