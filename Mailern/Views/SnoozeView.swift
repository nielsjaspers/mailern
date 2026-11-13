import SwiftUI

struct SnoozeView: View {
    @Environment(MailStore.self) private var store
    @Environment(SnoozePreferences.self) private var preferences
    @Environment(\.dismiss) private var dismiss
    let id: UUID
    var beforeSnooze: () -> Void = {}
    var onSnooze: () -> Void = {}
    @State private var date = Date.now.addingTimeInterval(3600)

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Form {
                    Section {
                        ForEach(preferences.settings.options(now: context.date)) { option in
                            Button {
                                // Resolve relative delays when tapped, even if the sheet has been open for a while.
                                if let current = preferences.settings.options(now: .now).first(where: { $0.id == option.id }) {
                                    snooze(current.date)
                                }
                            } label: {
                                HStack {
                                    Text(option.title).foregroundStyle(.primary)
                                    Spacer()
                                    Text(option.date, format: .dateTime.weekday(.abbreviated).hour().minute())
                                        .foregroundStyle(.secondary).font(.subheadline)
                                }
                            }
                        }
                    }
                    Section("Custom") {
                        DatePicker("Return to Inbox", selection: $date, in: context.date.addingTimeInterval(1)...)
                        Button("Snooze until \(date.formatted(date: .abbreviated, time: .shortened))") { snooze(date) }
                            .disabled(date <= context.date)
                    }
                    Section {
                        NavigationLink("Snooze settings") { SnoozeSettingsView() }
                    }
                }
            }
            .navigationTitle("Snooze").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }.presentationDetents([.large])
    }
    private func snooze(_ date: Date) {
        guard date > .now else { return }
        beforeSnooze()
        store.move(id, to: .snoozed, until: date)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        dismiss(); onSnooze()
    }
}
