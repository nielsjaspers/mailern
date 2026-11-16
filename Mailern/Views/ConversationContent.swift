import SwiftUI

struct ConversationContent: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let conversation: Conversation
    var isPreview = false
    var drafts: [ComposerDraft] = []
    var editDraft: (UUID) -> Void = { _ in }
    var discardDraft: (UUID) -> Void = { _ in }
    var deletingDraft = false
    /// Starts a reply or forward that targets one message. Nil hides the reply controls.
    var compose: ((ComposeMode, UUID) -> Void)?
    // Only the latest message starts open. This set holds the messages the reader flipped.
    @State private var toggled: Set<UUID> = []
    private var workflow: Workflow { conversation.workflow }
    private var latest: MailMessage { conversation.latest }
    private var earlier: [MailMessage] { Array(conversation.messages.dropLast()) }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(conversation.subject).font(.title2.bold()).textSelection(.enabled)
                        HStack {
                            Label(workflow.title, systemImage: workflow.symbol)
                            Text("· \(conversation.account.name)")
                            if conversation.messages.count > 1 {
                                Text("· \(conversation.messages.count) messages")
                            }
                        }.font(.caption).foregroundStyle(.secondary)
                        if workflow == .snoozed, let date = conversation.snoozedUntil {
                            Label(
                                "Returns \(date.formatted(date: .abbreviated, time: .shortened))",
                                systemImage: "clock"
                            ).font(.caption).foregroundStyle(.orange)
                        }
                    }
                    .padding(.horizontal, isPreview ? 0 : 4)
                    if isPreview { preview } else { thread }
                    ForEach(drafts) { draft in
                        DraftCard(draft: draft, edit: { editDraft(draft.id) }, discard: { discardDraft(draft.id) }, deleting: deletingDraft)
                            .id(draft.id)
                    }
                }.padding(isPreview ? 18 : 16)
            }
            .background(Color(uiColor: isPreview ? .secondarySystemGroupedBackground : .systemGroupedBackground))
            .onAppear { if let id = drafts.last?.id { proxy.scrollTo(id, anchor: .bottom) } }
            // A new message opens and the one it replaces folds, whatever the reader did to it.
            .onChange(of: latest.id) { old, _ in toggled.remove(old) }
            .onChange(of: drafts.map(\.id)) { _, ids in if let id = ids.last { proxy.scrollTo(id, anchor: .bottom) } }
        }
    }

    // One surface for the whole conversation: earlier messages fold to a single line each.
    private var thread: some View {
        VStack(spacing: 0) {
            ForEach(conversation.messages) { message in
                if message.id != conversation.messages.first?.id { Divider().padding(.leading, 16) }
                MessageSection(
                    message: message, conversationID: conversation.id, threadSubject: conversation.subject,
                    expanded: (message.id == latest.id) != toggled.contains(message.id),
                    toggle: earlier.isEmpty ? nil : {
                        withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) { _ = toggled.formSymmetricDifference([message.id]) }
                    },
                    compose: compose.map { compose in { compose($0, message.id) } }
                )
                .padding(.horizontal, 16)
                .id(message.id)
            }
        }
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    // A peek opens the conversation on any tap, so it cannot unfold messages or offer
    // per-message actions. It shows the newest message and sums up the rest.
    @ViewBuilder private var preview: some View {
        if !earlier.isEmpty {
            HStack(spacing: 10) {
                HStack(spacing: -8) {
                    ForEach(earlier.suffix(3)) {
                        SenderAvatar(name: $0.sender, tint: $0.outgoing ? .teal : nil, size: 24).padding(1.5)
                            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                }
                Text(earlier.count == 1 ? "1 earlier message" : "\(earlier.count) earlier messages")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        Divider()
        MessageSection(message: latest, conversationID: conversation.id, threadSubject: conversation.subject, expanded: true)
    }
}

private struct MessageSection: View {
    let message: MailMessage
    let conversationID: UUID
    let threadSubject: String
    let expanded: Bool
    /// Nil when the message cannot fold: a single-message thread or a peek.
    var toggle: (() -> Void)?
    /// Nil hides the reply controls.
    var compose: ((ComposeMode) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Group {
                if let toggle {
                    Button(action: toggle) { header }
                        .buttonStyle(.plain)
                        .accessibilityHint(expanded ? "Collapses the message" : "Expands the message")
                } else { header }
            }
            .overlay(alignment: .bottomTrailing) {
                if expanded { controls }
            }
            if expanded {
                if let subject = message.subject,
                   subject != threadSubject, subject.caseInsensitiveCompare("Re: \(threadSubject)") != .orderedSame {
                    Text("Subject: \(subject)").font(.subheadline).fontWeight(.semibold)
                }
                Group {
                    if let richText = message.richText {
                        RichMessageText(text: RichText.decode(richText, fallback: message.body))
                    } else { Text(.init(message.body)) }
                }.font(.body).lineSpacing(5).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let attachments = message.attachments, !attachments.isEmpty {
                    AttachmentList(attachments: attachments)
                }
            }
        }
        .padding(.vertical, 14)
    }

    // The time tells apart two open messages from one sender.
    @ViewBuilder private var controls: some View {
        if let compose {
            let id = conversationID
            let time = message.date.formatted(date: .omitted, time: .shortened)
            HStack(spacing: 8) {
                Button { compose(.reply(id)) } label: { Image(systemName: "arrowshape.turn.up.left") }
                    .accessibilityLabel("Reply to \(message.sender), \(time)")
                Menu {
                    Button("Reply", systemImage: "arrowshape.turn.up.left") { compose(.reply(id)) }
                    Button("Reply All", systemImage: "arrowshape.turn.up.left.2") { compose(.replyAll(id)) }
                    Button("Forward", systemImage: "arrowshape.turn.up.right") { compose(.forward(id)) }
                } label: { Image(systemName: "ellipsis").frame(height: 16) }
                    .accessibilityLabel("Message actions, \(message.sender), \(time)")
            }
            .buttonStyle(.bordered).buttonBorderShape(.circle).tint(.secondary)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            SenderAvatar(name: message.sender, tint: message.outgoing ? .teal : nil, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(message.sender).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(expanded
                         ? message.date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
                         : message.date.mailboxStamp).fixedSize()
                }
                if expanded {
                    HStack(alignment: .bottom) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(message.address).lineLimit(1)
                            Text("To: \(message.to.joined(separator: ", "))")
                            if !message.cc.isEmpty { Text("Cc: \(message.cc.joined(separator: ", "))") }
                        }
                        Spacer(minLength: 8)
                        // A hidden copy reserves the space of the reply controls at any text size.
                        // The live controls sit outside the fold button.
                        controls.hidden().accessibilityHidden(true)
                    }
                } else {
                    Text(message.body.snippet).font(.footnote).lineLimit(1)
                }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }
}
