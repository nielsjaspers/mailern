import SwiftUI
import ContactsUI
import PhotosUI
import UniformTypeIdentifiers

struct ComposerView: View {
    @Environment(MailStore.self) private var store
    @Environment(DraftStore.self) private var drafts
    @Environment(ComposerPanel.self) private var panel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let mode: ComposeMode
    /// The message a new reply or forward quotes. Nil targets the latest message.
    var messageID: UUID?
    var inboxAccountID: String?
    @AppStorage("defaultComposeAccount") private var defaultAccount = ""
    @State private var draft = ComposerDraft()
    @State private var initial = ComposerDraft()
    @State private var editor = RichTextState()
    @State private var loaded = false
    @State private var completed = false
    @State private var finishing = false
    @State private var savesInFlight = 0
    @State private var autosave: Task<Void, Never>?
    @State private var subjectFocused = false
    @State private var expanded = false
    /// Gives the keyboard to a field once the panel is open and still: the field a resume or a new draft starts in,
    /// or the one that was editing when a canceled pull began.
    @State private var refocus: (() -> Void)?
    @State private var filePicker = false
    @State private var photoPicker = false
    @State private var photos: [PhotosPickerItem] = []
    @State private var contacts = false
    @State private var systemContacts = false
    @State private var recipientSearch = ""
    @State private var importsInFlight = 0
    @State private var error: String?
    @State private var savedInput: DraftInput?
    @State private var picking: TimeChoice?
    @AppStorage(UndoSend.key) private var undoDelay = UndoSend.defaultDelay
    private enum TimeChoice: String, Identifiable {
        case sendLater, reminder
        var id: Self { self }
    }
    struct DraftInput: Equatable {
        var draft: ComposerDraft
        var text: NSAttributedString
        var edited: Bool
    }
    /// Compares with the last saved input, not the opening one: a header changed, autosaved,
    /// and then reverted still differs from what is on disk.
    static func isDirty(_ input: DraftInput, saved: DraftInput?, initial: ComposerDraft) -> Bool {
        if let saved { return saved != input }
        return input.draft != initial || input.edited
    }
    private var input: DraftInput { DraftInput(draft: draft, text: editor.text, edited: editor.edited) }
    @FocusState private var focus: Field?
    private enum Field { case to, cc, bcc }
    private var dirty: Bool {
        guard loaded else { return false }
        if savesInFlight > 0 { return true }
        return Self.isDirty(input, saved: savedInput, initial: initial)
    }
    private var saved: Bool { drafts.drafts.contains { $0.id == draft.id } }
    /// A closed composer is on its way out and does not minimize.
    private var canPull: Bool { loaded && !(completed || importing || finishing) }
    private var account: MailAccount { store.account(draft.accountID) }
    private let attachmentLimit = 25 * 1024 * 1024
    private var importing: Bool { importsInFlight > 0 }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    addressRow("To", text: $draft.to, field: .to, add: true)
                    Divider()
                    if expanded {
                        addressRow("Cc", text: $draft.cc, field: .cc)
                        Divider()
                        addressRow("Bcc", text: $draft.bcc, field: .bcc)
                        Divider()
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("From:").foregroundStyle(.secondary).fixedSize()
                            Menu {
                                Picker("From", selection: $draft.accountID) {
                                    ForEach(store.accounts) { Text($0.address).tag($0.id) }
                                }
                            } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Text(account.address)
                                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                                        .truncationMode(.middle)
                                        .multilineTextAlignment(.leading)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Image(systemName: "chevron.up.chevron.down").font(.caption)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 12)
                                .contentShape(Rectangle())
                            }.tint(.primary).disabled(draft.mode.replyID != nil)
                                .accessibilityLabel("From, \(account.address)")
                        }.frame(minHeight: 48)
                        Divider()
                    } else {
                        Button {
                            withAnimation(.snappy(duration: 0.25)) { expanded = true }
                        } label: {
                            Text("Cc/Bcc, From:  \(account.address)")
                                .font(.subheadline).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel("Cc/Bcc, From")
                        Divider()
                    }
                    HStack(spacing: 6) {
                        Text("Subject:").foregroundStyle(.secondary)
                        ComposerSubjectField(text: $draft.subject, isFocused: subjectFocused) { subjectFocused = $0 }
                    }.frame(minHeight: 48)
                    Divider()
                    if let followUp = draft.followUp {
                        HStack(spacing: 8) {
                            Label("Remind me \(followUp.formatted(.dateTime.weekday(.abbreviated).hour().minute())) if nobody replies",
                                  systemImage: "hourglass")
                                .font(.subheadline).foregroundStyle(.orange)
                            Spacer()
                            Button("Remove reminder", systemImage: "xmark.circle.fill") { draft.followUp = nil }
                                .labelStyle(.iconOnly).foregroundStyle(.secondary)
                        }.frame(minHeight: 44)
                        Divider()
                    }
                    RichTextEditor(state: editor)
                    if !draft.attachments.isEmpty {
                        AttachmentList(attachments: draft.attachments) { id in draft.attachments.removeAll { $0.id == id } }
                            .padding(.bottom, 20)
                    }
                }.padding(.horizontal, 16).padding(.top, 10)
            }
            .safeAreaInset(edge: .bottom, alignment: .trailing, spacing: 0) {
                // Keep the tools in the composer so UIKit only has to animate the keyboard.
                if editor.editing && !editor.formatting {
                    keyboardTools.padding(.trailing, 16).padding(.top, 4).padding(.bottom, 12)
                }
            }
            .disabled(completed || finishing)
            .scrollDismissesKeyboard(.immediately)
            // The top inset is the navigation bar, with the large title while it shows: the panel's pull zone.
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentInsets.top } action: { _, top in panel.pullZone = top }
            .scrollBounceBehavior(.always)
            .simultaneousGesture(DragGesture(minimumDistance: 10).onChanged { value in
                guard abs(value.translation.height) > abs(value.translation.width) else { return }
                focus = nil
                subjectFocused = false
                editor.view?.window?.endEditing(true)
            })
            .background(ComposerPanel.background)
            .navigationTitle(draft.title).navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { closeControl.disabled(importing || finishing) }
                ToolbarItem(placement: .confirmationAction) {
                    // Hold Send for Send Later and a follow-up reminder, as in Mail.
                    Menu {
                        Button("Send Later…", systemImage: "calendar.badge.clock") { picking = .sendLater }
                        Button(draft.followUp == nil ? "Remind Me If No Reply…" : "Change Reminder…", systemImage: "hourglass") { picking = .reminder }
                    } label: {
                        Label("Send", systemImage: "arrow.up")
                    } primaryAction: { Task { await send() } }
                        .labelStyle(.iconOnly).tint(.blue)
                        .foregroundStyle(draft.canSend ? Color.white : Color.secondary).disabled(!draft.canSend || !loaded || completed || finishing || importing)
                }
            }
        }
        .tint(.blue)
        .writingToolsBehavior(.disabled)
        .onAppear { load() }
        .onChange(of: canPull, initial: true) { _, value in panel.canPull = value }
        .onChange(of: saved || dirty, initial: true) { _, value in panel.canDock = value }
        // Only a loaded draft: the empty placeholder would show "New Message" on a resuming panel for a frame.
        .onChange(of: loaded ? DockSummary(draft) : nil, initial: true) { _, value in if let value { panel.summary = value } }
        .onChange(of: panel.settled) { _, settled in
            guard settled, let refocus else { return }
            self.refocus = nil
            // A field tapped while the panel moved keeps the keyboard.
            if editor.view?.isFirstResponder != true, !subjectFocused, focus == nil { refocus() }
        }
        // A pull puts the keyboard away, so it does not ride over the mailbox. A canceled pull gives it back.
        .onChange(of: panel.pulling) { _, pulling in
            guard pulling else { return }
            refocus = editingFocus()
            editor.view?.window?.endEditing(true)
        }
        .onChange(of: panel.minimizeVelocity) { _, velocity in
            guard let velocity else { return }
            panel.minimizeVelocity = nil
            minimize(velocity: velocity)
        }
        .onChange(of: draft.accountID) { _, id in if loaded { replaceSignature(with: store.account(id).signature) } }
        .onChange(of: input) { _, value in
            autosave?.cancel()
            guard loaded, !completed, !finishing,
                  savedInput != nil || savesInFlight > 0 || value.draft != initial || value.edited else { return }
            autosave = Task {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard !completed, !finishing, !Task.isCancelled else { return }
                await saveDraft(submitted: value)
            }
        }
        .onDisappear {
            autosave?.cancel()
            guard !completed else { return }
            // A composer that leaves without closing, such as when the mailbox session changes, keeps its edits.
            if dirty {
                do {
                    let content = try snapshot(input)
                    let activity = DraftSaveActivity()
                    Task {
                        await drafts.save(content)
                        activity.end()
                    }
                } catch { drafts.error = error.localizedDescription }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background && !completed && dirty { Task { await saveDraft() } }
        }
        .fileImporter(isPresented: $filePicker, allowedContentTypes: [.item], allowsMultipleSelection: true, onCompletion: importFiles)
        .photosPicker(isPresented: $photoPicker, selection: $photos, maxSelectionCount: 10, matching: .images)
        .onChange(of: photos) { _, items in
            guard !items.isEmpty else { return }
            importsInFlight += 1
            Task { @MainActor in
                defer { importsInFlight -= 1; photos = [] }
                for item in items {
                    do {
                        guard let data = try await item.loadTransferable(type: Data.self) else { continue }
                        let type = item.supportedContentTypes.first ?? .image
                        try attach(MailAttachment(name: "Photo-\(UUID().uuidString.prefix(6)).\(type.preferredFilenameExtension ?? "jpg")", data: data, contentType: type.identifier))
                    } catch { self.error = error.localizedDescription }
                }
            }
        }
        .sheet(isPresented: $contacts) { recipientPicker }
        .sheet(item: $picking) { choice in
            NavigationStack {
                Group {
                    switch choice {
                    case .sendLater:
                        SnoozeOptionsForm(customLabel: "Send at", confirmTitle: { "Send \($0.formatted(date: .abbreviated, time: .shortened))" }) { date in
                            picking = nil
                            Task { await send(at: date) }
                        }
                    case .reminder:
                        SnoozeOptionsForm(customLabel: "Remind me", confirmTitle: { "Remind me \($0.formatted(date: .abbreviated, time: .shortened))" }) { date in
                            draft.followUp = date
                            picking = nil
                        }
                    }
                }
                .navigationTitle(choice == .sendLater ? "Send Later" : "Remind If No Reply").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { picking = nil } } }
            }
        }
        .alert("Composer", isPresented: Binding(get: { error != nil || drafts.error != nil }, set: { if !$0 { error = nil; drafts.error = nil } })) {
            Button("OK") { error = nil; drafts.error = nil; if completed { panel.close() } }
        } message: { Text(error ?? drafts.error ?? "") }
    }

    @ViewBuilder private var keyboardTools: some View {
        let tools = HStack(spacing: 0) {
            Button(action: editor.showFormat) {
                Text("Aa").frame(width: 56, height: 46).contentShape(.rect)
            }
            .accessibilityLabel("Format")
            Menu {
                Button("Attach File", systemImage: "doc") { filePicker = true }
                Button("Photo Library", systemImage: "photo.on.rectangle") { photoPicker = true }
            } label: {
                Image(systemName: "paperclip").frame(width: 56, height: 46).contentShape(.rect)
            }
            .accessibilityLabel("Attach").disabled(importing)
        }
        .font(.system(size: 22)).buttonStyle(.plain).foregroundStyle(.primary)
        .padding(.horizontal, 8)
        if #available(iOS 26, *) {
            tools.glassEffect(.regular.interactive(), in: .capsule)
        } else {
            tools.background(.regularMaterial, in: .capsule)
        }
    }

    @ViewBuilder private var closeControl: some View {
        if completed {
            Button("Cancel", systemImage: "xmark") { panel.close() }.labelStyle(.iconOnly).tint(.primary)
        } else if dirty || saved {
            Menu {
                Button("Delete Draft", role: .destructive) {
                    Task {
                        guard !finishing else { return }
                        let activity = DraftSaveActivity()
                        defer { activity.end() }
                        finishing = true
                        defer { finishing = false }
                        guard await drafts.delete(draft.id) else { return }
                        complete()
                        panel.close()
                    }
                }
                Button("Save Draft") { Task { await saveDraft(then: .close) } }
            } label: { Image(systemName: "xmark") }
            .accessibilityLabel("Cancel").tint(.primary).disabled(importing)
        } else {
            Button("Cancel", systemImage: "xmark") { complete(); panel.close() }
                .labelStyle(.iconOnly).tint(.primary)
        }
    }
    private func addressRow(_ label: String, text: Binding<String>, field: Field, add: Bool = false) -> some View {
        HStack(spacing: 6) {
            Text("\(label):").foregroundStyle(.secondary)
            TextField("", text: text, axis: .vertical)
                .accessibilityLabel(label).keyboardType(.emailAddress)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .focused($focus, equals: field).submitLabel(.next)
                .onSubmit {
                    if field == .to { focus = nil; subjectFocused = true }
                    else { focus = .to }
                }
            if add {
                Button("Add recipient", systemImage: "plus.circle.fill") { recipientSearch = ""; contacts = true }
                    .labelStyle(.iconOnly).foregroundStyle(.secondary)
            }
        }.frame(minHeight: 48)
    }
    private var recipientPicker: some View {
        let query = recipientSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = recipients.filter {
            query.isEmpty || $0.name.localizedStandardContains(query) || $0.address.localizedStandardContains(query)
        }
        return NavigationStack {
            List {
                ForEach(matches, id: \.address) { person in
                    Button {
                        addRecipient(person.address)
                    } label: {
                        VStack(alignment: .leading) { Text(person.name); Text(person.address).font(.caption).foregroundStyle(.secondary) }
                    }.foregroundStyle(.primary)
                }
            }
            .accessibilityIdentifier("recipient-list")
            .overlay {
                if !query.isEmpty && matches.isEmpty {
                    ContentUnavailableView("No recipients found", systemImage: "magnifyingglass")
                }
            }
            .searchable(text: $recipientSearch, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search recipients")
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .navigationTitle("Recipients").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { contacts = false } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Contacts", systemImage: "person.crop.circle") { systemContacts = true }
                }
            }
            .background {
                SystemEmailPicker(isPresented: $systemContacts) { address in
                    if let address { addRecipient(address) }
                }
            }
        }
    }
    private func addRecipient(_ address: String) {
        draft.to += draft.to.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? address : ", \(address)"
        contacts = false
    }
    private var recipients: [(name: String, address: String)] {
        var seen = Set(store.accounts.map(\.address))
        return store.conversations.flatMap(\.messages).filter { seen.insert($0.address).inserted }
            .map { (name: $0.sender, address: $0.address) }.sorted { $0.name < $1.name }
    }
    private func load() {
        guard !loaded else { return }
        if case .draft(let id) = mode {
            guard let saved = drafts.drafts.first(where: { $0.id == id }) else {
                error = "This draft is no longer available."
                return
            }
            draft = saved
        } else if let replyID = mode.replyID, let existing = drafts.drafts.first(where: { $0.mode.replyID == replyID && $0.messageID == messageID }) {
            draft = existing
        } else {
            draft = ComposerDraft.make(mode: mode, conversation: mode.sourceID.flatMap(store.conversation), message: messageID, accounts: store.accounts, preferredAccountID: inboxAccountID ?? defaultAccount)
        }
        // A draft can outlive its account, for example after a demo reset. It sends from the default account instead.
        let missingAccount = !store.accounts.contains { $0.id == draft.accountID }
        if missingAccount { draft.accountID = store.accounts.first { $0.id == defaultAccount }?.id ?? store.accounts[0].id }
        let text = NSMutableAttributedString(attributedString: RichText.decode(draft.richText, fallback: draft.text))
        if !saved, draft.richText == nil, let sourceID = draft.mode.sourceID, let source = store.conversation(sourceID), text.length > 2 {
            // Retain the original formatting inside the editable reply or forward quote.
            let target = source.message(messageID)
            let original = target.body as NSString
            let bodyRange = NSRange(location: text.length - original.length, length: original.length)
            text.replaceCharacters(in: bodyRange, with: RichText.decode(target.richText, fallback: target.body))
            // The quote starts after the signature and the blank line that separates them.
            let start = (ComposerDraft.signatureBlock(draft.signature ?? "") as NSString).length + 2
            RichText.markQuote(in: text, from: start, body: bodyRange.location)
        }
        editor.text = text
        // A replaced signature moves the text, so the saved position no longer fits.
        let resume = missingAccount ? nil : drafts.docked.flatMap { $0.id == draft.id ? $0 : nil }
        let selections: [NSRange] = resume?.selections.map { range in
            let start = min(range.location, text.length)
            return NSRange(location: start, length: min(range.length, text.length - start))
        } ?? []
        let selection = selections.first ?? NSRange(location: 0, length: 0)
        editor.selection = selection
        let typing = resume?.typing ?? [.font: UIFont.preferredFont(forTextStyle: .body), .foregroundColor: UIColor.label]
        editor.typing = typing
        if missingAccount { replaceSignature(with: account.signature) }
        initial = draft
        loaded = true
        if draft.to.isEmpty && resume == nil { refocus = { focus = .to } }
        else {
            refocus = { [editor] in
                guard let view = editor.view else { return }
                view.becomeFirstResponder()
                if #available(iOS 26, *), !selections.isEmpty { view.selectedRanges = selections }
                else { view.selectedRange = selection }
                view.typingAttributes = typing
                if resume != nil { view.revealCaret(); editor.revealOnKeyboard = true }
            }
        }
    }
    /// Gives the keyboard back to the field that has it now.
    private func editingFocus() -> (() -> Void)? {
        if editor.view?.isFirstResponder == true { return { [editor] in editor.view?.becomeFirstResponder() } }
        if subjectFocused { return { subjectFocused = true } }
        if let field = focus { return { focus = field } }
        return nil
    }
    /// Swaps the inserted signature for `signature`. An edited signature stays, because it is no longer the account's.
    private func replaceSignature(with signature: String) {
        let text = NSMutableAttributedString(attributedString: editor.text)
        var quote: Int?
        text.enumerateAttribute(RichText.quote, in: NSRange(location: 0, length: text.length)) { value, span, stop in
            if value as? Bool == true { quote = span.location; stop.pointee = true }
        }
        let replacement = RichText.plain(ComposerDraft.signatureBlock(signature))
        guard let range = ComposerDraft.swapSignature(in: text, old: draft.signature ?? "", replacement: replacement, quoteStart: quote,
                                                      unedited: { RichText.isPlain(text, in: $0) }) else { return }
        if editor.selection.location >= NSMaxRange(range) { editor.selection.location += replacement.length - range.length }
        editor.text = text
        draft.signature = signature
    }
    private func snapshot(_ value: DraftInput) throws -> ComposerDraft {
        var result = value.draft
        result.text = value.text.string
        result.richText = try RichText.encode(value.text)
        result.updatedAt = .now
        return result
    }
    /// Closes the draft for good, and takes it out of the dock. Any draft minimized before shows again once the
    /// panel is gone.
    private func complete() {
        completed = true
        if drafts.docked?.id == draft.id { drafts.docked = nil }
    }
    /// Ending editing commits any text the keyboard is still composing before deciding where the panel goes.
    private func minimize(velocity: CGFloat) {
        editor.view?.window?.endEditing(true)
        guard canPull else { panel.open(velocity: velocity); return }
        guard saved || dirty else { complete(); panel.close(velocity: velocity); return }
        panel.dock(velocity: velocity)
        if dirty {
            Task { await saveDraft(then: .minimize) }
        } else {
            recordDockPosition()
            panel.dockReady()
        }
    }
    /// Puts the saved draft in the dock, with the editor's position, so a resume continues there.
    private func recordDockPosition() {
        guard loaded, saved else { return }
        let selections: [NSRange]
        if #available(iOS 26, *), let view = editor.view { selections = view.selectedRanges }
        else { selections = [editor.view?.selectedRange ?? editor.selection] }
        drafts.docked = DraftStore.Docked(id: draft.id, selections: selections, typing: editor.view?.typingAttributes ?? editor.typing)
    }
    private enum AfterSave { case stay, close, minimize }
    private func saveDraft(then after: AfterSave = .stay, submitted: DraftInput? = nil) async {
        guard loaded, !completed, !finishing else { return }
        let activity = DraftSaveActivity()
        defer { activity.end() }
        let dismissAfter = after != .stay
        if dismissAfter {
            finishing = true
            editor.view?.window?.endEditing(true)
        }
        savesInFlight += 1
        defer {
            savesInFlight -= 1
            if dismissAfter { finishing = false }
        }
        let submitted = submitted ?? input
        do {
            let content = try snapshot(submitted)
            // A failed save keeps the composer open, so the alert can show and the edits stay.
            guard await drafts.save(content) else { if after == .minimize { panel.open() }; return }
            if drafts.drafts.first(where: { $0.id == content.id })?.matchesContent(of: content) == true { savedInput = submitted }
            switch after {
            case .stay: break
            case .close: complete(); panel.close()
            case .minimize: recordDockPosition(); panel.dockReady()
            }
        } catch {
            self.error = error.localizedDescription
            if after == .minimize { panel.open() }
        }
    }
    /// Sends now, after the Undo Send delay, or at `scheduled`. Delayed mail waits in the outbox as this draft.
    private func send(at scheduled: Date? = nil) async {
        guard draft.canSend, loaded, !completed, !finishing, !importing else { return }
        let activity = DraftSaveActivity()
        defer { activity.end() }
        finishing = true
        defer { finishing = false }
        editor.view?.window?.endEditing(true)
        do {
            let content = try snapshot(input)
            let sendAt = scheduled ?? (undoDelay > 0 ? Date.now.addingTimeInterval(TimeInterval(undoDelay)) : nil)
            if let followUp = content.followUp, followUp <= (sendAt ?? .now) {
                error = "Choose a reminder after the message is sent."
                return
            }
            if let sendAt {
                guard await drafts.schedule(content, at: sendAt, holdingForUndo: scheduled == nil) else { return }
                if scheduled == nil { drafts.undoable = content.id }
            } else {
                // The draft's ID makes sending a leftover draft again a no-op if deleting it fails below.
                guard store.send(content) else {
                    error = store.error
                    store.error = nil
                    return
                }
            }
            complete()
            focus = nil
            editor.view?.resignFirstResponder()
            if sendAt == nil, !(await drafts.delete(draft.id)) {
                drafts.error = nil
                error = "Message sent. Mailern will retry draft cleanup."
                return
            }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            panel.close()
        } catch { self.error = error.localizedDescription }
    }
    private func importFiles(_ result: Result<[URL], any Error>) {
        importsInFlight += 1
        Task {
            defer { importsInFlight -= 1 }
            do {
                for url in try result.get() {
                    let remaining = attachmentLimit - draft.attachments.reduce(0) { $0 + $1.data.count }
                    let file = try await Task.detached(priority: .userInitiated) {
                        try AttachmentImport.read(url, limit: remaining)
                    }.value
                    try attach(file)
                }
            } catch { self.error = error.localizedDescription }
        }
    }
    private func attach(_ file: MailAttachment) throws {
        guard draft.attachments.reduce(file.data.count, { $0 + $1.data.count }) <= attachmentLimit else { throw AttachmentImport.Failure.tooLarge }
        draft.attachments.append(file)
    }
}

@MainActor private final class DraftSaveActivity {
    private var identifier = UIBackgroundTaskIdentifier.invalid
    init() {
        identifier = UIApplication.shared.beginBackgroundTask(withName: "Save draft") { [weak self] in self?.end() }
    }
    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}

private struct ComposerSubjectField: UIViewRepresentable {
    @Binding var text: String
    var isFocused: Bool
    var onFocus: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UITextField {
        let view = UITextField()
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.accessibilityLabel = "Subject"
        view.writingToolsBehavior = .none
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.delegate = context.coordinator
        view.addTarget(context.coordinator, action: #selector(Coordinator.changed), for: .editingChanged)
        return view
    }
    func updateUIView(_ view: UITextField, context: Context) {
        context.coordinator.parent = self
        if view.isEnabled != context.environment.isEnabled { view.isEnabled = context.environment.isEnabled }
        // Autosave updates must not replace text while the keyboard is editing it.
        if !view.isFirstResponder, view.text != text { view.text = text }
        if isFocused, !view.isFirstResponder, view.isEnabled {
            let coordinator = context.coordinator
            DispatchQueue.main.async { [weak view, weak coordinator] in
                guard let view, let coordinator, coordinator.parent.isFocused, view.isEnabled, !view.isFirstResponder else { return }
                view.becomeFirstResponder()
            }
        }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: (uiView.font?.lineHeight ?? 20) + 4)
    }
    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: ComposerSubjectField
        init(_ parent: ComposerSubjectField) { self.parent = parent }
        @objc func changed(_ view: UITextField) { parent.text = view.text ?? "" }
        func textFieldDidBeginEditing(_ textField: UITextField) { if !parent.isFocused { parent.onFocus(true) } }
        func textFieldDidEndEditing(_ textField: UITextField) {
            if parent.text != textField.text { parent.text = textField.text ?? "" }
            if parent.isFocused { parent.onFocus(false) }
        }
        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            textField.resignFirstResponder()
            return true
        }
    }
}

private struct SystemEmailPicker: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let finish: (String?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIViewController(context: Context) -> UIViewController { UIViewController() }

    func updateUIViewController(_ host: UIViewController, context: Context) {
        guard isPresented, host.presentedViewController == nil, !context.coordinator.presenting else { return }
        let picker = CNContactPickerViewController()
        context.coordinator.presenting = true
        context.coordinator.finish = { address in
            isPresented = false
            context.coordinator.presenting = false
            finish(address)
        }
        picker.delegate = context.coordinator
        picker.displayedPropertyKeys = [CNContactEmailAddressesKey]
        picker.predicateForEnablingContact = NSPredicate(format: "emailAddresses.@count > 0")
        picker.predicateForSelectionOfContact = NSPredicate(value: false)
        picker.predicateForSelectionOfProperty = NSPredicate(format: "key == %@", CNContactEmailAddressesKey)
        host.present(picker, animated: true)
    }

    final class Coordinator: NSObject, CNContactPickerDelegate {
        var presenting = false
        var finish: ((String?) -> Void)?
        private func complete(_ address: String?) {
            let callback = finish
            finish = nil
            callback?(address)
        }
        func contactPickerDidCancel(_ picker: CNContactPickerViewController) { complete(nil) }
        func contactPicker(_ picker: CNContactPickerViewController, didSelect property: CNContactProperty) {
            complete(property.value as? String)
        }
    }
}
