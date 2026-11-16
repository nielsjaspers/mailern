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
            // A long thread opens on its latest message, or on a draft below it.
            .onAppear {
                if let id = drafts.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                else if !isPreview, !earlier.isEmpty { proxy.scrollTo(latest.id, anchor: .top) }
            }
            // A new message opens and the one it replaces folds, whatever the reader did to it.
            .onChange(of: latest.id) { old, new in
                toggled.remove(old)
                if !isPreview { withAnimation(reduceMotion ? nil : .snappy) { proxy.scrollTo(new, anchor: .top) } }
            }
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
                        SenderAvatar(message: $0, size: 24).padding(1.5)
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
    @Environment(\.dynamicTypeSize) private var textSize
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

    @ViewBuilder private var controls: some View {
        if let compose {
            let id = conversationID
            // In the labels, the date and time tell apart two open messages from one sender.
            let time = message.date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
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
            // The hidden copy and the live controls sit in different font environments.
            .font(.body).buttonStyle(.bordered).buttonBorderShape(.circle).tint(.secondary)
        }
    }

    private var sender: some View {
        Text(message.sender).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
    }
    private var date: some View {
        Text(expanded && !Calendar.current.isDateInToday(message.date)
             ? message.date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
             : message.date.mailboxStamp).fixedSize()
    }
    @ViewBuilder private var foldIndicator: some View {
        if toggle != nil {
            Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                .rotationEffect(.degrees(expanded ? 180 : 0))
                .accessibilityHidden(true)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            SenderAvatar(message: message, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                // At large text sizes the date moves below the sender instead of squeezing it.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline) { sender; Spacer(minLength: 8); date; foldIndicator }
                    VStack(alignment: .leading, spacing: 2) {
                        sender
                        HStack(alignment: .firstTextBaseline) { date; Spacer(minLength: 8); foldIndicator }
                    }
                }
                if expanded {
                    // At accessibility sizes the reply controls get their own line, so the
                    // recipients keep the full width.
                    let layout = textSize.isAccessibilitySize
                        ? AnyLayout(VStackLayout(alignment: .trailing, spacing: 8)) : AnyLayout(HStackLayout(alignment: .bottom))
                    layout {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(message.address)
                            Text("To: \(message.to.joined(separator: ", "))")
                            if !message.cc.isEmpty { Text("Cc: \(message.cc.joined(separator: ", "))") }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
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
