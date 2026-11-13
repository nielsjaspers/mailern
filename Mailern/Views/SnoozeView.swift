import SwiftUI

struct SnoozeView: View {
    @Environment(MailStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let id: UUID
    var onSnooze: () -> Void = {}
    @State private var date = Date.now.addingTimeInterval(3600)
    private func morning(days: Int) -> Date {
        let day = Calendar.current.date(byAdding: .day, value: days, to: .now)!
        return Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: day)!
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    option("Later today", date: .now.addingTimeInterval(3 * 3600))
                    option("Tomorrow morning", date: morning(days: 1))
                    option("Later this week", date: morning(days: 3))
                    option("Next week", date: morning(days: 7))
                }
                Section("Custom") {
                    DatePicker("Return to Inbox", selection: $date, in: Date.now.addingTimeInterval(1)...)
                    Button("Snooze until \(date.formatted(date: .abbreviated, time: .shortened))") { snooze(date) }.disabled(date <= .now)
                }
                Section {
                    option("In 10 seconds", date: .now.addingTimeInterval(10))
                } footer: { Text("Use the short timer to try automatic return. New incoming replies always return immediately.") }
            }
            .navigationTitle("Snooze").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }.presentationDetents([.large])
    }
    private func option(_ title: String, date: @autoclosure @escaping () -> Date) -> some View {
        Button { snooze(date()) } label: {
            HStack { Text(title).foregroundStyle(.primary); Spacer(); Text(date(), format: .dateTime.weekday(.abbreviated).hour().minute()).foregroundStyle(.secondary).font(.subheadline) }
        }
    }
    private func snooze(_ date: Date) {
        store.move(id, to: .snoozed, until: date)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        dismiss(); onSnooze()
    }
}
