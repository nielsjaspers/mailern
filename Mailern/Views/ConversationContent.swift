import SwiftUI

struct ConversationContent: View {
    @Environment(MailStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let conversation: Conversation
    var isPreview = false
    var drafts: [ComposerDraft] = []
    var scheduled: [ComposerDraft] = []
    var editDraft: (UUID) -> Void = { _ in }
    var discardDraft: (UUID) -> Void = { _ in }
    var deletingDraft = false
    /// Starts a reply or forward that targets one message. Nil hides the reply controls.
    var compose: ((ComposeMode, UUID) -> Void)?
    // Only the latest message starts open. This set holds the messages the reader flipped.
    @State private var toggled: Set<UUID> = []
    @State private var showsMiddle = false
    /// A longer thread shows its first message and its last two, with one row for the messages between.
    private static let foldAfter = 4
    private func isExpanded(_ message: MailMessage) -> Bool { (message.id == latest.id) != toggled.contains(message.id) }
    private var workflow: Workflow { conversation.workflow }
    private var latest: MailMessage { conversation.latest }
    private var earlier: [MailMessage] { Array(conversation.messages.dropLast()) }
    private var margin: CGFloat { isPreview ? 18 : 20 }
    private var ownAddresses: Set<String> { Set(store.accounts.map { $0.address.lowercased() }) }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(conversation.subject).font(.title2.bold()).textSelection(.enabled)
                        HStack {
                            if let mailbox = conversation.removal?.mailbox {
                                Label(mailbox.title, systemImage: mailbox.symbol)
                            } else {
                                Label(workflow.title, systemImage: workflow.symbol)
                            }
                            Text("· \(store.account(conversation.accountID).name)")
                            if conversation.messages.count > 1 {
                                Text("· \(conversation.messages.count) messages")
                            }
                            if conversation.muted == true { Text("· Muted") }
                        }.font(.caption).foregroundStyle(.secondary)
                        if workflow == .snoozed, conversation.removal == nil, let date = conversation.snoozedUntil {
                            Label(
                                conversation.followUp == .waiting
                                    ? "Returns \(date.formatted(date: .abbreviated, time: .shortened)) if nobody replies"
                                    : "Returns \(date.formatted(date: .abbreviated, time: .shortened))",
                                systemImage: "clock"
                            ).font(.caption).foregroundStyle(.orange)
                        }
                        if conversation.followUp == .noReply, conversation.removal == nil {
                            Label("No reply yet", systemImage: "hourglass").font(.caption).foregroundStyle(.orange)
                        }
                    }
                    .padding(.horizontal, margin)
                    if isPreview { preview } else { thread }
                    VStack(spacing: 16) {
                        ForEach(drafts) { draft in
                            DraftCard(draft: draft, edit: { editDraft(draft.id) }, discard: { discardDraft(draft.id) }, deleting: deletingDraft)
                                .id(draft.id)
                        }
                        ForEach(scheduled) { ScheduledCard(draft: $0).id($0.id) }
                    }.padding(.horizontal, 16)
                }.padding(.vertical, isPreview ? 18 : 16)
            }
            .background(Color(uiColor: isPreview ? .secondarySystemGroupedBackground : .systemBackground))
            // A long thread opens on its latest message, or on a draft below it.
            .onAppear {
                if let id = (drafts + scheduled).last?.id { proxy.scrollTo(id, anchor: .bottom) }
                else if !isPreview, !earlier.isEmpty { proxy.scrollTo(latest.id, anchor: .top) }
            }
            // A new message opens and the one it replaces folds, whatever the reader did to it.
            .onChange(of: latest.id) { old, new in
                toggled.remove(old)
                if !isPreview { withAnimation(reduceMotion ? nil : .snappy) { proxy.scrollTo(new, anchor: .top) } }
            }
            .onChange(of: (drafts + scheduled).map(\.id)) { _, ids in if let id = ids.last { proxy.scrollTo(id, anchor: .bottom) } }
        }
    }

    private enum Item: Identifiable {
        case message(MailMessage), middle(count: Int)
        var id: String {
            switch self { case .message(let message): message.id.uuidString; case .middle: "middle" }
        }
    }
    /// Folded messages, and the row for hidden ones, share one grouped surface. An open message sits between
    /// those groups on the page itself, so its HTML can use the full width.
    private enum Segment: Identifiable {
        case folded([Item]), open(MailMessage)
        var id: String {
            switch self { case .folded(let items): "folded-\(items[0].id)"; case .open(let message): message.id.uuidString }
        }
    }
    private var segments: [Segment] {
        let messages = conversation.messages
        let items = showsMiddle || messages.count <= Self.foldAfter
            ? messages.map(Item.message)
            : [.message(messages[0]), .middle(count: messages.count - 3)] + messages.suffix(2).map(Item.message)
        var segments: [Segment] = []
        for item in items {
            if case .message(let message) = item, isExpanded(message) {
                segments.append(.open(message))
            } else if case .folded(let group) = segments.last {
                segments[segments.count - 1] = .folded(group + [item])
            } else {
                segments.append(.folded([item]))
            }
        }
        return segments
    }
    private func toggle(_ message: MailMessage) {
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) { _ = toggled.formSymmetricDifference([message.id]) }
    }

    private var thread: some View {
        let segments = segments
        return VStack(spacing: 12) {
            ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                switch segment {
                case .folded(let items):
                    VStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { row, item in
                            if row > 0 { Divider().padding(.leading, 60) }
                            switch item {
                            case .message(let message):
                                FoldedMessageRow(message: message) { toggle(message) }
                                    .id(message.id)
                            case .middle(let count):
                                Button { withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) { showsMiddle = true } } label: {
                                    Label("\(count) earlier messages", systemImage: "rectangle.stack")
                                        .font(.subheadline.weight(.medium)).foregroundStyle(.tint)
                                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityHint("Shows every message in the conversation")
                            }
                        }
                    }
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .padding(.horizontal, 16)
                case .open(let message):
                    if index > 0, case .open = segments[index - 1] { Divider().padding(.horizontal, margin) }
                    MessageSection(
                        message: message, conversationID: conversation.id, threadSubject: conversation.subject, quoteStart: conversation.quoteStart(of: message),
                        ownAddresses: ownAddresses, margin: margin,
                        fold: conversation.messages.count > 1 ? { toggle(message) } : nil,
                        compose: compose.map { compose in { compose($0, message.id) } }
                    )
                    .id(message.id)
                }
            }
        }
    }

    // A peek opens the conversation on any tap, so it cannot fold messages or offer
    // per-message actions. Every message is open, newest first: the peek opens on the
    // new message, and scrolling down reads back through the thread.
    @ViewBuilder private var preview: some View {
        MessageSection(message: latest, conversationID: conversation.id, threadSubject: conversation.subject, quoteStart: conversation.quoteStart(of: latest),
                       ownAddresses: ownAddresses, margin: margin, isPreview: true)
        if !earlier.isEmpty {
            Text("Earlier messages").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, margin)
            ForEach(earlier.reversed()) { message in
                Divider().padding(.horizontal, margin)
                MessageSection(message: message, conversationID: conversation.id, threadSubject: conversation.subject, quoteStart: conversation.quoteStart(of: message),
                               ownAddresses: ownAddresses, margin: margin, isPreview: true)
            }
        }
    }

}

/// A folded message: who wrote it, when, and the first line of what they wrote.
private struct FoldedMessageRow: View {
    let message: MailMessage
    let expand: () -> Void
    private var firstLine: String {
        message.body.split(whereSeparator: \.isNewline).lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
    }

    var body: some View {
        Button(action: expand) {
            HStack(alignment: .top, spacing: 12) {
                SenderAvatar(message: message, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    // At large text sizes the date moves below the sender instead of squeezing it.
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .firstTextBaseline) { sender; Spacer(minLength: 8); stamp }
                        VStack(alignment: .leading, spacing: 2) { sender; stamp }
                    }
                    Text(firstLine).font(.footnote).lineLimit(1)
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Expands the message")
    }
    private var sender: some View {
        Text(message.sender).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
    }
    private var stamp: some View {
        HStack(spacing: 4) {
            if message.attachments?.isEmpty == false {
                Image(systemName: "paperclip").accessibilityLabel("Attachments")
            }
            Text(message.date.mailboxStamp)
        }.fixedSize()
    }
}

private struct MessageSection: View {
    @Environment(\.dynamicTypeSize) private var textSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let message: MailMessage
    let conversationID: UUID
    let threadSubject: String
    /// Where the quoted history starts in the plain-text body. It stays folded until the reader shows it.
    let quoteStart: Int?
    let ownAddresses: Set<String>
    let margin: CGFloat
    /// A peek opens the conversation on any tap, so its HTML takes no touches and nothing folds or unfolds.
    var isPreview = false
    /// Nil when the message cannot fold: a single-message thread or a peek.
    var fold: (() -> Void)?
    /// Nil hides the reply controls.
    var compose: ((ComposeMode) -> Void)?
    @State private var showsDetails = false
    @State private var showsQuote = false
    private var richText: NSAttributedString? { message.richText.map { RichText.decode($0, fallback: message.body) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header.padding(.horizontal, margin)
            if showsDetails { details.padding(.horizontal, margin) }
            if let subject = message.subject,
               subject != threadSubject, subject.caseInsensitiveCompare("Re: \(threadSubject)") != .orderedSame {
                Text("Subject: \(subject)").font(.subheadline).fontWeight(.semibold).padding(.horizontal, margin)
            }
            if let html = message.html {
                // HTML uses the full width. Its own page sets the margins.
                HTMLMessageView(html: html, fallback: message.body, margin: margin, isPreview: isPreview).allowsHitTesting(!isPreview)
            } else {
                let rich = richText
                // Rich text folds at the plain body's offsets, so it folds only when it holds exactly the same characters.
                let foldable = quoteStart != nil && (rich.map { $0.string.utf16.elementsEqual(message.body.utf16) } ?? true)
                let length = foldable && !showsQuote ? visibleLength : nil
                Group {
                    if let rich {
                        RichMessageText(text: length.map { rich.attributedSubstring(from: NSRange(location: 0, length: $0)) } ?? rich)
                    } else { Text(MessageLinks.linked(length.map { (message.body as NSString).substring(to: $0) } ?? message.body)) }
                }.font(.body).lineSpacing(5).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, margin)
                if foldable, !isPreview {
                    Button {
                        withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) { showsQuote.toggle() }
                    } label: {
                        Image(systemName: "ellipsis").font(.caption.weight(.bold)).frame(width: 24, height: 12)
                    }
                    .buttonStyle(.bordered).buttonBorderShape(.capsule).tint(.secondary)
                    .accessibilityLabel(showsQuote ? "Hide quoted text" : "Show quoted text")
                    .padding(.horizontal, margin)
                }
            }
            if let attachments = message.attachments, !attachments.isEmpty {
                AttachmentList(attachments: attachments).padding(.horizontal, margin)
            }
        }
        .padding(.vertical, 14)
    }

    /// The UTF-16 length of the text above the quote, without the blank lines that separated them.
    private var visibleLength: Int? {
        guard let quoteStart else { return nil }
        let above = (message.body as NSString).substring(to: quoteStart)
        return above.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression).utf16.count
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
            .font(.subheadline).buttonStyle(.bordered).buttonBorderShape(.circle).tint(.secondary)
        }
    }

    /// Everyone the message went to, with your own addresses as "me".
    private var recipients: String {
        var seen = Set<String>()
        let names = (message.to + message.cc).map { ownAddresses.contains($0.lowercased()) ? "me" : $0 }
            .filter { seen.insert($0.lowercased()).inserted }
        // Mail sent only to Bcc has no visible recipients. The details list them.
        if names.isEmpty { return "Recipient details" }
        guard names.count > 2 else { return "to \(names.joined(separator: ", "))" }
        return "to \(names.prefix(2).joined(separator: ", ")) +\(names.count - 2)"
    }
    private var date: some View {
        Text(Calendar.current.isDateInToday(message.date)
             ? message.date.mailboxStamp
             : message.date.formatted(.dateTime.month(.abbreviated).day().hour().minute())).fixedSize()
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            SenderAvatar(message: message, size: 36)
            VStack(alignment: .leading, spacing: 4) {
                Group {
                    if let fold {
                        Button(action: fold) { nameLine }
                            .buttonStyle(.plain)
                            .accessibilityHint("Collapses the message")
                    } else { nameLine }
                }
                // At accessibility sizes the reply controls get their own line, so the recipients keep the full width.
                let layout = textSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(alignment: .center))
                layout {
                    Group {
                        if isPreview { recipientsLabel } else {
                            Button {
                                withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) { showsDetails.toggle() }
                            } label: { recipientsLabel }
                                .buttonStyle(.plain)
                                .accessibilityLabel(recipients)
                                .accessibilityHint(showsDetails ? "Hides the addresses" : "Shows the addresses")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    controls
                }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }
    private var nameLine: some View {
        // At large text sizes the date moves below the sender instead of squeezing it.
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline) { sender; Spacer(minLength: 8); date; foldIndicator }
            VStack(alignment: .leading, spacing: 2) {
                sender
                HStack(alignment: .firstTextBaseline) { date; Spacer(minLength: 8); foldIndicator }
            }
        }
        .contentShape(Rectangle())
    }
    private var sender: some View {
        Text(message.sender).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
    }
    @ViewBuilder private var foldIndicator: some View {
        if fold != nil {
            Image(systemName: "chevron.up").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
    }
    private var recipientsLabel: some View {
        HStack(spacing: 4) {
            Text(recipients).lineLimit(1)
            if !isPreview {
                Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(showsDetails ? 90 : 0))
            }
        }
        .contentShape(Rectangle())
    }
    private var details: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("From: \(message.sender) <\(message.address)>")
            Text("To: \(message.to.joined(separator: ", "))")
            if !message.cc.isEmpty { Text("Cc: \(message.cc.joined(separator: ", "))") }
            if let bcc = message.bcc, !bcc.isEmpty { Text("Bcc: \(bcc.joined(separator: ", "))") }
            Text(message.date.formatted(date: .complete, time: .shortened))
        }
        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        .padding(.leading, 48)
    }
}
