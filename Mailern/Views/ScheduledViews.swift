import SwiftUI

struct ScheduledRow: View {
    @Environment(MailStore.self) private var store
    let draft: ComposerDraft
    var body: some View {
        MailboxRow(
            avatar: SenderAvatar(name: draft.to, symbol: "paperplane.fill", tint: .blue, label: "Scheduled"),
            title: draft.to, date: draft.updatedAt, subject: draft.title, snippet: draft.text.snippet,
            account: store.account(draft.accountID), snoozedUntil: draft.sendAt
        )
    }
}

/// Mail waiting in the outbox. Edit and Cancel Send take it back into Drafts.
struct ScheduledCard: View {
    @Environment(MailStore.self) private var store
    @Environment(DraftStore.self) private var drafts
    let draft: ComposerDraft
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                if drafts.undoable == draft.id {
                    Label("Sending", systemImage: "paperplane")
                } else {
                    Label("Scheduled", systemImage: "calendar.badge.clock")
                }
                Spacer()
                if let sendAt = draft.sendAt {
                    Text(sendAt, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.font(.subheadline.weight(.semibold)).foregroundStyle(.blue)
            DraftDetails(draft: draft)
            if let followUp = draft.followUp {
                Label("Remind me \(followUp.formatted(.dateTime.weekday(.abbreviated).hour().minute())) if nobody replies", systemImage: "hourglass")
                    .font(.caption).foregroundStyle(.orange)
            }
            // An unconfirmed send may already be out, so it can only be retried, not edited or canceled.
            if store.hasPendingRemoteSend(draft.id) {
                Label("Delivery is unconfirmed", systemImage: "exclamationmark.arrow.circlepath")
                    .font(.caption).foregroundStyle(.orange)
                Button("Retry Send", systemImage: "arrow.clockwise") { run { _ = await drafts.sendNow(draft.id, through: store) } }
                    .buttonStyle(.bordered).tint(.blue).disabled(busy)
            } else {
                HStack {
                    Button("Edit", systemImage: "square.and.pencil") { run { await drafts.edit(draft.id) } }
                        .buttonStyle(.bordered)
                    Button("Send Now", systemImage: "paperplane") { run { _ = await drafts.sendNow(draft.id, through: store) } }
                        .buttonStyle(.bordered)
                    Spacer()
                    // Cancel Send keeps the message as a draft, so it is not destructive.
                    Button("Cancel Send", systemImage: "calendar.badge.minus") { run { _ = await drafts.unschedule(draft.id) } }
                        .labelStyle(.iconOnly)
                }
                .lineLimit(1).tint(.blue).disabled(busy)
            }
        }
        .padding(18)
        .background(Color.blue.opacity(0.07), in: RoundedRectangle(cornerRadius: 18))
        .accessibilityIdentifier("scheduled-card-\(draft.id)")
    }
    private func run(_ action: @escaping () async -> Void) {
        busy = true
        Task {
            await action()
            busy = false
        }
    }
}

/// Mail waiting to be sent, pushed from the Mailboxes menu onto the current tab's stack.
struct ScheduledMailboxView: View {
    @Environment(MailStore.self) private var store
    @Environment(DraftStore.self) private var drafts
    // A message pushed on top shows its own draft storage alert.
    @State private var visible = false

    var body: some View {
        Group {
            if drafts.outbox.isEmpty {
                ContentUnavailableView("No scheduled mail", systemImage: "calendar.badge.clock",
                                       description: Text("Hold Send in a message to send it later."))
            } else {
                List {
                    Section {
                        ForEach(drafts.outbox) { draft in
                            NavigationLink(value: MailboxRoute.scheduledMessage(draft.id)) { ScheduledRow(draft: draft) }
                                .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                                .swipeActions(edge: .trailing) {
                                    // An unconfirmed send may already be out, so it can only be retried.
                                    if store.hasPendingRemoteSend(draft.id) {
                                        Button("Retry Send", systemImage: "arrow.clockwise") { Task { await drafts.sendNow(draft.id, through: store) } }.tint(.blue)
                                    } else {
                                        Button("Cancel Send", systemImage: "xmark") { Task { await drafts.unschedule(draft.id) } }.tint(.orange)
                                        Button("Send Now", systemImage: "paperplane") { Task { await drafts.sendNow(draft.id, through: store) } }.tint(.blue)
                                    }
                                }
                        }
                    } footer: {
                        Text("Scheduled mail is sent while Mailern is open, or the next time it opens.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .listStyle(.plain)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { UndoBanner(sendingOnly: true) }
        .navigationTitle("Scheduled")
        .toolbar(.hidden, for: .tabBar)
        .modifier(DraftStorageAlert(active: visible))
        .onAppear { visible = true }
        .onDisappear { visible = false }
    }
}

/// One scheduled message. It closes once the message goes out or returns to Drafts.
struct ScheduledMessageView: View {
    @Environment(DraftStore.self) private var drafts
    @Environment(\.dismiss) private var dismiss
    let id: UUID

    var body: some View {
        Group {
            if let draft = drafts.outbox.first(where: { $0.id == id }) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        Text(draft.title).font(.title2.bold()).textSelection(.enabled)
                        ScheduledCard(draft: draft)
                    }.padding(18)
                }.background(Color(uiColor: .systemGroupedBackground))
            } else {
                ContentUnavailableView("Message no longer scheduled", systemImage: "calendar.badge.clock")
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .modifier(DraftStorageAlert(active: true))
        .onChange(of: drafts.outbox.contains { $0.id == id }) { _, scheduled in if !scheduled { dismiss() } }
    }
}
