import SwiftUI

struct ConversationContent: View {
    let conversation: Conversation
    var isPreview = false
    var hasDraft = false
    var drafts: [ComposerDraft] = []
    var editDraft: (UUID) -> Void = { _ in }
    var discardDraft: (UUID) -> Void = { _ in }
    var deletingDraft = false
    private var workflow: Workflow { hasDraft || !drafts.isEmpty ? .inbox : conversation.workflow }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
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
                    ForEach(conversation.messages) { message in
                        VStack(alignment: .leading, spacing: 14) {
                            if isPreview { Divider() }
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(message.sender).font(.subheadline.bold())
                                    Text(message.address).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(message.date, format: .dateTime.month(.abbreviated).day().hour().minute()).font(
                                    .caption
                                ).foregroundStyle(.secondary)
                            }
                            Text(
                                "To: \(message.to.joined(separator: ", "))"
                                    + (message.cc.isEmpty ? "" : "\nCc: \(message.cc.joined(separator: ", "))")
                            ).font(.caption).foregroundStyle(.secondary)
                            if let subject = message.subject,
                               subject != conversation.subject, subject.caseInsensitiveCompare("Re: \(conversation.subject)") != .orderedSame {
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
                        .padding(isPreview ? 0 : 18)
                        .background(
                            isPreview ? Color.clear : message.outgoing
                                ? Color.teal.opacity(0.07) : Color(uiColor: .secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 18))
                    }
                    ForEach(drafts) { draft in
                        DraftCard(draft: draft, edit: { editDraft(draft.id) }, discard: { discardDraft(draft.id) }, deleting: deletingDraft)
                            .id(draft.id)
                    }
                }.padding(18)
            }
            .background(Color(uiColor: isPreview ? .secondarySystemGroupedBackground : .systemGroupedBackground))
            .onAppear { if let id = drafts.last?.id { proxy.scrollTo(id, anchor: .bottom) } }
            .onChange(of: drafts.map(\.id)) { _, ids in if let id = ids.last { proxy.scrollTo(id, anchor: .bottom) } }
        }
    }
}
