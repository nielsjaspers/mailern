import SwiftUI

struct ConversationContent: View {
    let conversation: Conversation
    var isPreview = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(conversation.subject).font(.title2.bold()).textSelection(.enabled)
                    HStack {
                        Label(conversation.workflow.title, systemImage: conversation.workflow.symbol)
                        Text("· \(conversation.account.name)")
                        if conversation.messages.count > 1 {
                            Text("· \(conversation.messages.count) messages")
                        }
                    }.font(.caption).foregroundStyle(.secondary)
                    if let date = conversation.snoozedUntil {
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
                        Text(.init(message.body)).font(.body).lineSpacing(5).textSelection(.enabled).frame(
                            maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(isPreview ? 0 : 18)
                    .background(
                        isPreview ? Color.clear : message.outgoing
                            ? Color.teal.opacity(0.07) : Color(uiColor: .secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 18))
                }
            }.padding(18)
        }
        .background(Color(uiColor: isPreview ? .secondarySystemGroupedBackground : .systemGroupedBackground))
    }
}
