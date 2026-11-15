import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct ComposerView: View {
    @Environment(MailStore.self) private var store
    @Environment(DraftStore.self) private var drafts
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    let mode: ComposeMode
    @State private var draft = ComposerDraft()
    @State private var initial = ComposerDraft()
    @State private var editor = RichTextState()
    @State private var loaded = false
    @State private var completed = false
    @State private var expanded = false
    @State private var filePicker = false
    @State private var photoPicker = false
    @State private var photos: [PhotosPickerItem] = []
    @State private var contacts = false
    @State private var importingPhotos = false
    @State private var error: String?
    @State private var savedInput: DraftInput?
    private struct DraftInput: Equatable {
        var draft: ComposerDraft
        var text: NSAttributedString
        var edited: Bool
    }
    private var input: DraftInput { DraftInput(draft: draft, text: editor.text, edited: editor.edited) }
    @FocusState private var focus: Field?
    private enum Field { case to, cc, bcc, subject }
    private var dirty: Bool { loaded && (draft != initial || editor.edited) }
    private var saved: Bool { drafts.drafts.contains { $0.id == draft.id } }
    private var title: String { draft.subject.isEmpty ? "New Message" : draft.subject }
    private var account: MailAccount { MailAccount.demo.first { $0.id == draft.accountID } ?? MailAccount.demo[1] }
    private let attachmentLimit = 25 * 1024 * 1024

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
                        HStack(spacing: 8) {
                            Text("From:").foregroundStyle(.secondary)
                            Picker("From", selection: $draft.accountID) {
                                ForEach(MailAccount.demo) { Text($0.address).tag($0.id) }
                            }.labelsHidden().tint(.primary).disabled(draft.mode.replyID != nil)
                            Spacer(minLength: 0)
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
                        TextField("", text: $draft.subject).accessibilityLabel("Subject").focused($focus, equals: .subject)
                    }.frame(minHeight: 48)
                    Divider()
                    RichTextEditor(state: editor, attach: { filePicker = true }, photos: { photoPicker = true })
                    if !draft.attachments.isEmpty {
                        AttachmentList(attachments: draft.attachments) { id in draft.attachments.removeAll { $0.id == id } }
                            .padding(.bottom, 20)
                    }
                }.padding(.horizontal, 16).padding(.top, 10)
            }
            .disabled(completed)
            .scrollDismissesKeyboard(.interactively)
            .background(Color(uiColor: .systemBackground))
            .navigationTitle(title).navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { closeControl.disabled(importingPhotos) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send", systemImage: "arrow.up", action: send)
                        .labelStyle(.iconOnly).tint(.blue)
                        .foregroundStyle(draft.canSend ? Color.white : Color.secondary).disabled(!draft.canSend || !loaded || completed || importingPhotos)
                }
            }
        }
        .tint(.blue)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(importingPhotos || (!completed && dirty && savedInput != input))
        .presentationBackground(Color(uiColor: .systemBackground))
        .onAppear(perform: load)
        .task(id: input) {
            guard loaded, dirty, !completed else { return }
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard !completed, !Task.isCancelled else { return }
            saveDraft(dismissAfter: false)
        }
        .onChange(of: scenePhase) { _, phase in if phase == .background && !completed && dirty { saveDraft(dismissAfter: false) } }
        .fileImporter(isPresented: $filePicker, allowedContentTypes: [.item], allowsMultipleSelection: true, onCompletion: importFiles)
        .photosPicker(isPresented: $photoPicker, selection: $photos, maxSelectionCount: 10, matching: .images)
        .onChange(of: photos) { _, items in
            guard !items.isEmpty else { return }
            importingPhotos = true
            Task { @MainActor in
                defer { importingPhotos = false; photos = [] }
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
        .alert("Composer", isPresented: Binding(get: { error != nil || drafts.error != nil }, set: { if !$0 { error = nil; drafts.error = nil } })) {
            Button("OK") { error = nil; drafts.error = nil; if completed { dismiss() } }
        } message: { Text(error ?? drafts.error ?? "") }
    }

    @ViewBuilder private var closeControl: some View {
        if completed {
            Button("Cancel", systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly).tint(.primary)
        } else if dirty || saved {
            Menu {
                Button("Delete Draft", role: .destructive) {
                    guard !saved || drafts.delete(draft.id) else { return }
                    completed = true
                    dismiss()
                }
                Button("Save Draft") { saveDraft(dismissAfter: true) }
            } label: { Image(systemName: "xmark") }
            .accessibilityLabel("Cancel").tint(.primary).disabled(importingPhotos)
        } else {
            Button("Cancel", systemImage: "xmark") { completed = true; dismiss() }
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
                .onSubmit { focus = field == .to ? .subject : .to }
            if add {
                Button("Add recipient", systemImage: "plus.circle.fill") { contacts = true }
                    .labelStyle(.iconOnly).foregroundStyle(.secondary)
            }
        }.frame(minHeight: 48)
    }
    private var recipientPicker: some View {
        NavigationStack {
            List {
                ForEach(recipients, id: \.address) { person in
                    Button {
                        draft.to += draft.to.trimmingCharacters(in: .whitespaces).isEmpty ? person.address : ", \(person.address)"
                        contacts = false
                    } label: {
                        VStack(alignment: .leading) { Text(person.name); Text(person.address).font(.caption).foregroundStyle(.secondary) }
                    }.foregroundStyle(.primary)
                }
            }
            .navigationTitle("Recipients").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { contacts = false } } }
        }
    }
    private var recipients: [(name: String, address: String)] {
        var seen = Set(MailAccount.demo.map(\.address))
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
        } else {
            draft = ComposerDraft.make(mode: mode, conversation: mode.sourceID.flatMap(store.conversation))
        }
        let text = NSMutableAttributedString(attributedString: RichText.decode(draft.richText, fallback: draft.text))
        if draft.richText == nil, let sourceID = draft.mode.sourceID, let source = store.conversation(sourceID), text.length > 2 {
            // Retain the original formatting inside the editable reply or forward quote.
            let original = source.latest.body as NSString
            let bodyRange = NSRange(location: text.length - original.length, length: original.length)
            text.replaceCharacters(in: bodyRange, with: RichText.decode(source.latest.richText, fallback: source.latest.body))
            let quote = NSRange(location: 2, length: text.length - 2)
            text.addAttribute(.foregroundColor, value: UIColor.systemPurple, range: NSRange(location: 2, length: bodyRange.location - 2))
            text.addAttribute(RichText.quote, value: true, range: quote)
            text.enumerateAttribute(.paragraphStyle, in: quote) { value, range, _ in
                let style = ((value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
                style.headIndent += 10
                style.firstLineHeadIndent += 10
                text.addAttribute(.paragraphStyle, value: style, range: range)
            }
        }
        editor.text = text
        editor.selection = NSRange(location: 0, length: 0)
        editor.typing = [.font: UIFont.preferredFont(forTextStyle: .body), .foregroundColor: UIColor.label]
        initial = draft
        loaded = true
        if draft.to.isEmpty { focus = .to }
        else {
            DispatchQueue.main.async {
                guard let view = editor.view else { return }
                view.becomeFirstResponder()
                view.selectedRange = NSRange(location: 0, length: 0)
                view.typingAttributes = [.font: UIFont.preferredFont(forTextStyle: .body), .foregroundColor: UIColor.label]
            }
        }
    }
    private func snapshot() throws -> ComposerDraft {
        var result = draft
        result.text = editor.text.string
        result.richText = try RichText.encode(editor.text)
        result.updatedAt = .now
        return result
    }
    private func saveDraft(dismissAfter: Bool) {
        do {
            guard drafts.save(try snapshot()) else { return }
            savedInput = input
            if dismissAfter { completed = true; dismiss() }
        } catch { self.error = error.localizedDescription }
    }
    private func send() {
        guard draft.canSend, loaded, !completed, !importingPhotos else { return }
        do {
            let content = try snapshot()
            guard store.send(threadID: content.mode.replyID, account: account, to: ComposerDraft.addresses(content.to), cc: ComposerDraft.addresses(content.cc),
                       subject: content.subject.isEmpty ? "(No Subject)" : content.subject, body: content.text,
                       bcc: ComposerDraft.addresses(content.bcc), richText: content.richText, attachments: content.attachments) else {
                error = store.error
                store.error = nil
                return
            }
            completed = true
            focus = nil
            editor.view?.resignFirstResponder()
            if saved && !drafts.delete(draft.id) {
                drafts.error = nil
                error = "Message saved, but the draft could not be removed. You can retry deleting it from Drafts."
                return
            }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
    private func importFiles(_ result: Result<[URL], any Error>) {
        do {
            for url in try result.get() {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let info = try url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey])
                guard (info.fileSize ?? 0) <= attachmentLimit else { throw AttachmentError.tooLarge }
                try attach(MailAttachment(name: url.lastPathComponent, data: Data(contentsOf: url), contentType: (info.contentType ?? .data).identifier))
            }
        } catch { self.error = error.localizedDescription }
    }
    private func attach(_ file: MailAttachment) throws {
        guard draft.attachments.reduce(file.data.count, { $0 + $1.data.count }) <= attachmentLimit else { throw AttachmentError.tooLarge }
        draft.attachments.append(file)
    }
    private enum AttachmentError: LocalizedError {
        case tooLarge
        var errorDescription: String? { "Attachments can total up to 25 MB in this prototype." }
    }
}
