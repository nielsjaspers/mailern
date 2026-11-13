import SwiftUI

struct ThreadView: View {
    @Environment(MailStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let id: UUID
    @State private var mode: ComposeMode?
    @State private var snooze = false
    var body: some View {
        Group {
            if let c = store.conversation(id) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(c.subject).font(.title2.bold()).textSelection(.enabled)
                            HStack {
                                Label(c.workflow.title, systemImage: c.workflow.symbol)
                                Text("· \(c.account.name) · \(c.messages.count) messages")
                            }.font(.caption).foregroundStyle(.secondary)
                            if let date = c.snoozedUntil { Label("Returns \(date.formatted(date: .abbreviated, time: .shortened))", systemImage: "clock").font(.caption).foregroundStyle(.orange) }
                        }
                        ForEach(c.messages) { message in
                            VStack(alignment: .leading, spacing: 14) {
                                HStack(alignment: .top) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(message.sender).font(.subheadline.bold())
                                        Text(message.address).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(message.date, format: .dateTime.month(.abbreviated).day().hour().minute()).font(.caption).foregroundStyle(.secondary)
                                }
                                Text("To: \(message.to.joined(separator: ", "))" + (message.cc.isEmpty ? "" : "\nCc: \(message.cc.joined(separator: ", "))")).font(.caption).foregroundStyle(.secondary)
                                Text(.init(message.body)).font(.body).lineSpacing(5).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(18)
                            .background(message.outgoing ? Color.teal.opacity(0.07) : Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
                        }
                    }.padding(18)
                }
                .background(Color(uiColor: .systemGroupedBackground))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button(c.pinned ? "Unpin" : "Pin", systemImage: "pin") { store.togglePin(id) }
                            Button("Mark unread", systemImage: "envelope.badge") { store.markRead(id, unread: true); dismiss() }
                            Button("Snooze", systemImage: "clock") { snooze = true }
                            if c.workflow != .inbox { Button("Restore to Inbox", systemImage: "tray") { store.move(id, to: .inbox); dismiss() } }
                            Divider()
                            Button("Simulate incoming reply", systemImage: "arrow.down.message") { store.receiveReply(id) }
                        } label: { Label("More actions", systemImage: "ellipsis.circle") }
                    }
                    ToolbarItemGroup(placement: .bottomBar) {
                        Button(c.workflow == .settled ? "Restore" : "Settle", systemImage: c.workflow == .settled ? "tray" : "checkmark") {
                            store.move(id, to: c.workflow == .settled ? .inbox : .settled)
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            dismiss()
                        }
                        Spacer()
                        Button("Snooze", systemImage: "clock") { snooze = true }
                        Spacer()
                        Menu {
                            Button("Reply") { mode = .reply(id) }
                            Button("Reply All") { mode = .replyAll(id) }
                            Button("Forward") { mode = .forward(id) }
                        } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }
                    }
                }
            } else { ContentUnavailableView("Conversation unavailable", systemImage: "envelope") }
        }
        .toolbar(.hidden, for: .tabBar)
        .onAppear { store.markRead(id) }
        .sheet(item: $mode) { ComposerView(mode: $0) }
        .sheet(isPresented: $snooze) { SnoozeView(id: id, onSnooze: { dismiss() }) }
    }
}
