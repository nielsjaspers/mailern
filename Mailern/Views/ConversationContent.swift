import SwiftUI

struct ConversationContent: View {
    @Environment(MailStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let conversation: Conversation
    var isPreview = false
    var initialQuery = ""
    var finding: Binding<Bool> = .constant(false)
    @State private var query = ""
    @State private var matches: [MessageMatch] = []
    @State private var matchIndex = 0
    @State private var completedFind: FindRequest?
    @State private var openingResult = false
    @FocusState private var findFocused: Bool
    var drafts: [ComposerDraft] = []
    var scheduled: [ComposerDraft] = []
    var editDraft: (UUID) -> Void = { _ in }
    var discardDraft: (UUID) -> Void = { _ in }
    var deletingDraft = false
    /// Starts a reply or forward that targets one message. Nil hides the reply controls.
    var compose: ((ComposeMode, UUID) -> Void)?
    var showSender: ((Sender) -> Void)?
    // Only the latest message starts open. This set holds the messages the reader flipped.
    @State private var toggled: Set<UUID> = []
    @State private var showsMiddle = false
    /// A longer thread shows its first message and its last two, with one row for the messages between.
    private static let foldAfter = 4
    private func isExpanded(_ message: MailMessage) -> Bool { match?.messageID == message.id || ((message.id == latest.id) != toggled.contains(message.id)) }
    private var workflow: Workflow { conversation.workflow }
    private var latest: MailMessage { conversation.latest }
    private var earlier: [MailMessage] { Array(conversation.messages.dropLast()) }
    private var margin: CGFloat { isPreview ? 18 : 20 }
    private var ownAddresses: Set<String> { Set(store.accounts.map { $0.address.lowercased() }) }

    private struct FindRequest: Equatable { let query: String; let latest: UUID }

    var body: some View {
        let request = FindRequest(query: query, latest: latest.id)
        let resultsReady = completedFind == request
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
            .safeAreaInset(edge: .top, spacing: 0) {
                if finding.wrappedValue {
                    HStack {
                        TextField("Find in conversation", text: $query).focused($findFocused)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        if !query.isEmpty {
                            Button("Clear find", systemImage: "xmark.circle.fill") { query = ""; findFocused = true }
                        }
                        if !query.isEmpty {
                            ZStack {
                                Text("No matches").hidden().accessibilityHidden(true)
                                Text(matches.isEmpty ? "No matches" : "\(matchIndex + 1) of \(matches.count)")
                                    .opacity(resultsReady ? 1 : 0).accessibilityHidden(!resultsReady)
                            }.font(.caption).monospacedDigit()
                        }
                        Button("Previous match", systemImage: "chevron.up") { matchIndex -= 1 }.disabled(!resultsReady || matchIndex == 0)
                        Button("Next match", systemImage: "chevron.down") { matchIndex += 1 }.disabled(!resultsReady || matchIndex + 1 >= matches.count)
                        Button("Done") { finishFind(proxy) }.accessibilityIdentifier("Close find")
                    }.labelStyle(.iconOnly).padding(10).background(.bar)
                }
            }
            .onChange(of: finding.wrappedValue) { _, active in findFocused = active }
            .task(id: request) {
                let previous = match
                guard !query.isEmpty else { matches = []; completedFind = nil; matchIndex = 0; return }
                let thread = conversation, term = query
                let worker = Task.detached(priority: .userInitiated) { thread.messageMatches(term) }
                let found = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
                guard !Task.isCancelled, query == term else { return }
                completedFind = request
                matches = found
                matchIndex = previous.flatMap { found.firstIndex(of: $0) } ?? 0
                if openingResult && found.isEmpty { openNormally(proxy) }
                openingResult = false
                revealMatch(proxy)
            }
            .onChange(of: matchIndex) { _, _ in revealMatch(proxy) }
            // A long thread opens on its latest message, or on a draft below it.
            .onAppear {
                if initialQuery.isEmpty { openNormally(proxy) }
                else { openingResult = true; query = initialQuery }
            }
            // A new message opens and the one it replaces folds, whatever the reader did to it.
            .onChange(of: latest.id) { old, new in
                toggled.remove(old)
                if !finding.wrappedValue, !isPreview {
                    query = ""
                    withAnimation(reduceMotion ? nil : .snappy) { proxy.scrollTo(new, anchor: .top) }
                }
            }
            .onChange(of: (drafts + scheduled).map(\.id)) { _, ids in if !finding.wrappedValue, let id = ids.last { query = ""; proxy.scrollTo(id, anchor: .bottom) } }
        }
    }

    private var match: MessageMatch? { matches.indices.contains(matchIndex) ? matches[matchIndex] : nil }
    private func openNormally(_ proxy: ScrollViewProxy) {
        if let id = (drafts + scheduled).last?.id { proxy.scrollTo(id, anchor: .bottom) }
        else if !isPreview, !earlier.isEmpty { proxy.scrollTo(latest.id, anchor: .top) }
    }
    private func finishFind(_ proxy: ScrollViewProxy) {
        let id = match?.messageID
        if let id {
            if conversation.messages.dropFirst().dropLast(2).contains(where: { $0.id == id }) { showsMiddle = true }
            if id == latest.id { toggled.remove(id) } else { toggled.insert(id) }
        }
        finding.wrappedValue = false
        matches = []
        query = ""
        if let id { Task { @MainActor in await Task.yield(); proxy.scrollTo(id, anchor: .top) } }
    }
    private func revealMatch(_ proxy: ScrollViewProxy) {
        guard let match else { return }
        let id = match.messageID
        Task { @MainActor in
            await Task.yield()
            guard self.match == match else { return }
            proxy.scrollTo(id, anchor: .top)
        }
    }

    private static func highlighted(_ match: MessageMatch) -> AttributedString {
        var hit = AttributedString(match.text)
        hit.backgroundColor = .yellow
        hit.foregroundColor = .black
        return AttributedString(match.before) + hit + AttributedString(match.after)
    }

    private enum Item: Identifiable {
        case message(MailMessage), middle(count: Int)
        var id: String {
            switch self { case .message(let message): message.id.uuidString; case .middle: "middle" }
        }
        /// What scrolling targets: a message's own ID, as the thread scrolls to messages by it.
        var anchor: AnyHashable {
            switch self { case .message(let message): message.id; case .middle: "middle" }
        }
    }
    private var items: [Item] {
        let messages = conversation.messages
        let targetsMiddle = match.map { hit in messages.dropFirst().dropLast(2).contains { $0.id == hit.messageID } } ?? false
        return showsMiddle || targetsMiddle || messages.count <= Self.foldAfter
            ? messages.map(Item.message)
            : [.message(messages[0]), .middle(count: messages.count - 3)] + messages.suffix(2).map(Item.message)
    }
    private func toggle(_ message: MailMessage) {
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.3)) { _ = toggled.formSymmetricDifference([message.id]) }
    }

    /// Every message keeps one view, folded or open, so a toggle animates in place. All rows sit on the page itself,
    /// with a hairline between them, so an open message's HTML can use the full width.
    private var thread: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                Group {
                    switch item {
                    case .message(let message):
                        let folded = !isExpanded(message)
                        VStack(alignment: .leading, spacing: 0) {
                            if let match, match.messageID == message.id {
                                Text(Self.highlighted(match)).font(.callout).padding(.horizontal, margin)
                                    .accessibilityIdentifier("matching-passage")
                            }
                            MessageRow(
                                activeMatch: match?.messageID == message.id ? match : nil, message: message, conversationID: conversation.id, threadSubject: conversation.subject,
                                // A folded row shows only its first line, so it needs no quote.
                                quoteStart: folded ? nil : conversation.quoteStart(of: message),
                                answered: folded ? nil : conversation.answered(by: message),
                                ownAddresses: ownAddresses, margin: margin, expanded: !folded,
                                toggle: conversation.messages.count > 1 && match?.messageID != message.id ? { toggle(message) } : nil,
                                compose: compose.map { compose in { compose($0, message.id) } }, showSender: showSender
                            )
                        }
                    case .middle(let count):
                        Button { withAnimation(reduceMotion ? nil : .snappy(duration: 0.3)) { showsMiddle = true } } label: {
                            Label("\(count) earlier messages", systemImage: "rectangle.stack")
                                .font(.subheadline.weight(.medium)).foregroundStyle(.tint)
                                .frame(maxWidth: .infinity).padding(.vertical, 12)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Shows every message in the conversation")
                    }
                }
                // A row reveals its content as it grows, so new text never shows over the rows still moving below it.
                .clipped()
                .overlay(alignment: .top) {
                    if index > 0 { Divider().padding(.horizontal, margin) }
                }
                .id(item.anchor)
            }
        }
    }

    // A peek opens the conversation on any tap, so it cannot fold messages or offer
    // per-message actions. Every message is open, newest first: the peek opens on the
    // new message, and scrolling down reads back through the thread.
    @ViewBuilder private var preview: some View {
        MessageRow(message: latest, conversationID: conversation.id, threadSubject: conversation.subject, quoteStart: conversation.quoteStart(of: latest), answered: conversation.answered(by: latest),
                       ownAddresses: ownAddresses, margin: margin, isPreview: true)
        if !earlier.isEmpty {
            Text("Earlier messages").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, margin)
            ForEach(earlier.reversed()) { message in
                Divider().padding(.horizontal, margin)
                MessageRow(message: message, conversationID: conversation.id, threadSubject: conversation.subject, quoteStart: conversation.quoteStart(of: message), answered: conversation.answered(by: message),
                               ownAddresses: ownAddresses, margin: margin, isPreview: true)
            }
        }
    }

}

/// One message in a thread or a peek. Folded, it shows who wrote it, when, and its first line. Open, it shows the
/// recipients, the reply controls, and the whole message.
private struct MessageRow: View {
    @Environment(\.dynamicTypeSize) private var textSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var activeMatch: MessageMatch?
    let message: MailMessage
    let conversationID: UUID
    let threadSubject: String
    /// Where the composer's quote starts in the body. It stays folded until the reader shows it.
    let quoteStart: Int?
    /// The message this one answers. Its formatting proves a rich-text quote unchanged.
    let answered: MailMessage?
    let ownAddresses: Set<String>
    let margin: CGFloat
    /// A peek opens the conversation on any tap, so its HTML takes no touches and nothing folds or unfolds.
    var isPreview = false
    var expanded = true
    /// Folds or opens the message. Nil when it cannot fold: a single-message thread or a peek.
    var toggle: (() -> Void)?
    /// Nil hides the reply controls.
    var compose: ((ComposeMode) -> Void)?
    var showSender: ((Sender) -> Void)?
    @State private var showsDetails = false
    @State private var showsQuote = false
    private var richText: NSAttributedString? { message.richText.map { RichText.decode($0, fallback: message.body) } }
    private var canManageSender: Bool { !isPreview && !message.outgoing && !ownAddresses.contains(message.address.lowercased()) }

    private var foldedSummary: String {
        [message.sender, message.date.mailboxStamp, message.attachments?.isEmpty == false ? "Attachments" : nil, firstLine]
            .compactMap { $0 }.joined(separator: ", ")
    }
    private var firstLine: String {
        message.body.split(whereSeparator: \.isNewline).lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header.padding(.horizontal, margin)
            if expanded { content.transition(.opacity) }
        }
        .padding(.vertical, expanded ? 14 : 12)
        // A folded message opens on a tap anywhere. The tap sits in an overlay, not on the row, so it cannot merge
        // the sender line into one accessibility element; for VoiceOver, the sender line is the row's button.
        // Open, the overlay takes no touches, so links, selection, and controls in the message keep their own taps.
        .overlay {
            Color.clear.contentShape(Rectangle())
                .onTapGesture { toggle?() }
                .allowsHitTesting(!expanded)
                .accessibilityHidden(true)
        }
        // A message opens as it was first shown, with its quote and addresses hidden.
        .onChange(of: expanded) { _, open in
            if !open { showsQuote = false; showsDetails = false }
        }
    }

    @ViewBuilder private var content: some View {
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
                // Only the composer writes rich text with a quote, so plain mail never folds.
                if let hit = activeMatch, hit.inBody, let rich, rich.string.utf16.elementsEqual(message.body.utf16) {
                    messageText(highlighted(rich, match: hit))
                } else if let rich, quoteStart != nil, quoteIsUnchanged(rich), let quoteStart {
                    // The composer separates the quote with exactly two line breaks. Blank lines above them stay.
                    messageText(rich.attributedSubstring(from: NSRange(location: 0, length: quoteStart - 2)))
                    if !isPreview {
                        Button {
                            withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) { showsQuote.toggle() }
                        } label: {
                            Image(systemName: "ellipsis").font(.caption.weight(.bold)).frame(width: 24, height: 12)
                        }
                        .buttonStyle(.bordered).buttonBorderShape(.capsule).tint(.secondary)
                        .accessibilityLabel(showsQuote ? "Hide quoted text" : "Show quoted text")
                        .padding(.horizontal, margin)
                        // The quote opens below its button, so the button stays where it was tapped.
                        if showsQuote { messageText(rich.attributedSubstring(from: NSRange(location: quoteStart, length: rich.length - quoteStart))) }
                    }
                } else if let rich {
                    messageText(rich)
                } else {
                    messageText(nil)
                }
            }
            if let attachments = message.attachments, !attachments.isEmpty {
                AttachmentList(attachments: attachments).padding(.horizontal, margin)
            }
    }

    private func highlighted(_ rich: NSAttributedString, match: MessageMatch) -> NSAttributedString {
        let marked = NSMutableAttributedString(attributedString: rich)
        marked.addAttributes([.backgroundColor: UIColor.systemYellow, .foregroundColor: UIColor.black],
                             range: NSRange(match.range, in: match.field))
        return marked
    }
    private var linkedBody: AttributedString {
        var text = MessageLinks.linked(message.body)
        if let hit = activeMatch, hit.inBody, let range = Range(NSRange(hit.range, in: hit.field), in: text) {
            text[range].backgroundColor = .yellow
            text[range].foregroundColor = .black
        }
        return text
    }
    private func messageText(_ text: NSAttributedString?) -> some View {
        Group {
            if let text { RichMessageText(text: text) } else { Text(linkedBody) }
        }
        .font(.body).lineSpacing(5).textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, margin)
    }
    /// True when rich text holds exactly the body's characters, and its quote still looks as the composer wrote it from
    /// the answered message. A writer can bold, strike through, or center quoted words to point at them, and those must stay visible.
    private func quoteIsUnchanged(_ text: NSAttributedString) -> Bool {
        guard let quoteStart, let answered, text.string.utf16.elementsEqual(message.body.utf16) else { return false }
        let original = RichText.decode(answered.richText, fallback: answered.body)
        guard original.string.utf16.elementsEqual(answered.body.utf16) else { return false }
        return RichText.isUnchangedQuote(text, from: quoteStart, attributionLength: QuotedText.attribution(for: answered).utf16.count,
                                         quoting: original)
    }

    @ViewBuilder private var controls: some View {
        if compose != nil || canManageSender {
            let id = conversationID
            // In the labels, the date and time tell apart two open messages from one sender.
            let time = message.date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
            HStack(spacing: 8) {
                if let compose {
                    Button { compose(.reply(id)) } label: { Image(systemName: "arrowshape.turn.up.left") }
                        .accessibilityIdentifier((activeMatch == nil ? "reply-" : "matched-reply-") + message.id.uuidString)
                        .accessibilityLabel("Reply to \(message.sender), \(time)")
                }
                Menu {
                    if let compose {
                        Button("Reply", systemImage: "arrowshape.turn.up.left") { compose(.reply(id)) }
                        Button("Reply All", systemImage: "arrowshape.turn.up.left.2") { compose(.replyAll(id)) }
                        Button("Forward", systemImage: "arrowshape.turn.up.right") { compose(.forward(id)) }
                        if canManageSender { Divider() }
                    }
                    if canManageSender, let showSender {
                        Button("Sender History", systemImage: "person.crop.circle") {
                            showSender(Sender(name: message.sender, address: message.address))
                        }
                        SenderBlockButton(address: message.address)
                    }
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
        HStack(spacing: 4) {
            if !expanded, message.attachments?.isEmpty == false {
                Image(systemName: "paperclip").accessibilityLabel("Attachments")
            }
            Text(dateText)
        }.fixedSize()
    }
    private var dateText: String {
        expanded && !Calendar.current.isDateInToday(message.date)
            ? message.date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
            : message.date.mailboxStamp
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            // The avatar folds an open message too. It is a plain tap: VoiceOver has the sender line's button.
            SenderAvatar(message: message, size: 36)
                .onTapGesture { toggle?() }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: expanded ? 4 : 2) {
                // One view in both states, so the sender line keeps its identity while toggling. Open, it folds the
                // message and acts as a button. Folded, the whole row is the button.
                nameLine
                    .gesture(TapGesture().onEnded { toggle?() }, including: expanded && toggle != nil ? .all : .subviews)
                    // VoiceOver reads the whole folded row here, and this element folds or opens the message.
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(expanded ? "\(message.sender), \(dateText)" : foldedSummary)
                    .accessibilityAddTraits(toggle != nil ? .isButton : [])
                    .accessibilityHint(toggle == nil ? "" : expanded ? "Collapses the message" : "Expands the message")
                    // VoiceOver activates this directly: folded, the touch target is the hidden overlay, not this line.
                    .modifier(ToggleAction(toggle: toggle))
                if expanded {
                    // At accessibility sizes the reply controls get their own line, so the recipients keep the full width.
                    let layout = textSize.isAccessibilitySize
                        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(alignment: .center))
                    layout {
                        Group {
                            if isPreview { recipientsLabel } else {
                                Button {
                                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) { showsDetails.toggle() }
                                } label: {
                                    // The caption stays compact, but the free width beside the reply controls, at their height, takes the tap.
                                    recipientsLabel.frame(maxWidth: .infinity, minHeight: 36, alignment: .leading).contentShape(Rectangle())
                                }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(recipients)
                                    .accessibilityHint(showsDetails ? "Hides the addresses" : "Shows the addresses")
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        controls
                    }
                    .transition(.opacity)
                } else {
                    // The sender line's button reads this line for VoiceOver.
                    Text(firstLine).font(.footnote).lineLimit(1).transition(.opacity).accessibilityHidden(true)
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
        // The fold target reaches up into the space above the header, so it never overlaps the recipient details below.
        .padding(.top, 12).contentShape(Rectangle()).padding(.top, -12)
    }
    private var sender: some View {
        Text(message.sender).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
    }
    @ViewBuilder private var foldIndicator: some View {
        if toggle != nil {
            Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                .rotationEffect(.degrees(expanded ? 180 : 0))
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

/// Exposes the same fold action to VoiceOver as the sender line.
private struct ToggleAction: ViewModifier {
    let toggle: (() -> Void)?
    func body(content: Content) -> some View {
        if let toggle { content.accessibilityAction { toggle() } } else { content }
    }
}
