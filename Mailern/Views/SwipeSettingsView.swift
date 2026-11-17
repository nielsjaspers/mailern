import SwiftUI

enum MailboxSwipeAction: String, CaseIterable, Identifiable {
    case workflow, read, snooze, pin, trash, none
    var id: Self { self }
    var title: String {
        switch self {
        case .workflow: "Settle / Restore"
        case .read: "Read / Unread"
        case .snooze: "Snooze"
        case .pin: "Pin / Unpin"
        case .trash: "Move to Trash"
        case .none: "None"
        }
    }
}

struct SwipeSettingsView: View {
    @AppStorage("leftSwipePrimary") private var leftPrimary: MailboxSwipeAction = .workflow
    @AppStorage("leftSwipeSecondary") private var leftSecondary: MailboxSwipeAction = .snooze
    @AppStorage("rightSwipePrimary") private var rightPrimary: MailboxSwipeAction = .read
    @AppStorage("rightSwipeSecondary") private var rightSecondary: MailboxSwipeAction = .pin
    @AppStorage("leftSwipeTertiary") private var leftTertiary: MailboxSwipeAction = .none
    @AppStorage("rightSwipeTertiary") private var rightTertiary: MailboxSwipeAction = .none

    var body: some View {
        Form {
            direction("Swipe left", primary: $leftPrimary, secondary: $leftSecondary, tertiary: $leftTertiary)
            direction("Swipe right", primary: $rightPrimary, secondary: $rightSecondary, tertiary: $rightTertiary)
            Section {
                Button("Reset Swipe Actions") {
                    leftPrimary = .workflow
                    leftSecondary = .snooze
                    rightPrimary = .read
                    rightSecondary = .pin
                    leftTertiary = .none
                    rightTertiary = .none
                }
            }
        }
        .navigationTitle("Swipe actions")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func direction(
        _ title: String, primary: Binding<MailboxSwipeAction>, secondary: Binding<MailboxSwipeAction>,
        tertiary: Binding<MailboxSwipeAction>
    ) -> some View {
        Section {
            actionPicker("Full Swipe", id: "\(title)-primary", selection: primary, others: [secondary, tertiary])
            actionPicker("Additional Action 1", id: "\(title)-secondary", selection: secondary, others: [primary, tertiary])
            actionPicker("Additional Action 2", id: "\(title)-tertiary", selection: tertiary, others: [primary, secondary])
        } header: {
            Text(title)
        } footer: {
            Text("Full Swipe also appears as the first button. Set it to None to use only buttons. Applies to Inbox, Snoozed, and Settled.")
        }
    }

    private func actionPicker(
        _ title: String, id: String, selection: Binding<MailboxSwipeAction>, others: [Binding<MailboxSwipeAction>]
    ) -> some View {
        Picker(title, selection: Binding(get: { selection.wrappedValue }, set: { value in
            if value != .none {
                for other in others where other.wrappedValue == value { other.wrappedValue = .none }
            }
            selection.wrappedValue = value
        })) {
            ForEach(MailboxSwipeAction.allCases) { Text($0.title).tag($0) }
        }
        .accessibilityIdentifier(id)
    }
}
