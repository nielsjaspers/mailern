import SwiftUI

enum MailboxSwipeAction: String, CaseIterable, Identifiable {
    case workflow, read, snooze, pin, none
    var id: Self { self }
    var title: String {
        switch self {
        case .workflow: "Settle / Restore"
        case .read: "Read / Unread"
        case .snooze: "Snooze"
        case .pin: "Pin / Unpin"
        case .none: "None"
        }
    }
}

struct SwipeSettingsView: View {
    @AppStorage("leftSwipePrimary") private var leftPrimary: MailboxSwipeAction = .workflow
    @AppStorage("leftSwipeSecondary") private var leftSecondary: MailboxSwipeAction = .snooze
    @AppStorage("rightSwipePrimary") private var rightPrimary: MailboxSwipeAction = .read
    @AppStorage("rightSwipeSecondary") private var rightSecondary: MailboxSwipeAction = .pin

    var body: some View {
        Form {
            direction("Swipe left", primary: $leftPrimary, secondary: $leftSecondary)
            direction("Swipe right", primary: $rightPrimary, secondary: $rightSecondary)
            Section {
                Button("Reset Swipe Actions") {
                    leftPrimary = .workflow
                    leftSecondary = .snooze
                    rightPrimary = .read
                    rightSecondary = .pin
                }
            }
        }
        .navigationTitle("Swipe actions")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func direction(
        _ title: String, primary: Binding<MailboxSwipeAction>, secondary: Binding<MailboxSwipeAction>
    ) -> some View {
        Section {
            Picker("Full swipe", selection: Binding(get: { primary.wrappedValue }, set: { value in
                if secondary.wrappedValue == value { secondary.wrappedValue = .none }
                primary.wrappedValue = value
            })) {
                ForEach(MailboxSwipeAction.allCases) { Text($0.title).tag($0) }
            }
            .accessibilityIdentifier("\(title)-primary")
            if primary.wrappedValue != .none {
                Picker("Additional action", selection: secondary) {
                    ForEach(MailboxSwipeAction.allCases.filter { $0 != primary.wrappedValue }) {
                        Text($0.title).tag($0)
                    }
                }
                .accessibilityIdentifier("\(title)-secondary")
            }
        } header: {
            Text(title)
        } footer: {
            Text("The full-swipe action also appears as the first button. Choose None to disable this direction. Applies to all mailboxes.")
        }
    }
}
