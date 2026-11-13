import SwiftUI

struct SnoozeSettingsView: View {
    @Environment(SnoozePreferences.self) private var preferences
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        @Bindable var preferences = preferences
        Form {
            Section("Delays") {
                Stepper(value: $preferences.settings.shortDelayMinutes, in: 15...1440, step: 15) {
                    LabeledContent("Short delay", value: SnoozeSettings.delayTitle(preferences.settings.shortDelayMinutes))
                }
                Stepper(value: $preferences.settings.longDelayMinutes, in: 15...1440, step: 15) {
                    LabeledContent("Long delay", value: SnoozeSettings.delayTitle(preferences.settings.longDelayMinutes))
                }
            }
            Section("Return times") {
                DatePicker("This evening", selection: timeBinding(\.eveningMinutes), displayedComponents: .hourAndMinute)
                DatePicker("Tomorrow", selection: timeBinding(\.tomorrowMinutes), displayedComponents: .hourAndMinute)
                Picker("Next week", selection: $preferences.settings.nextWeekday) {
                    ForEach([2, 3, 4, 5, 6, 7, 1], id: \.self) { weekday in
                        Text(Calendar.current.weekdaySymbols[weekday - 1]).tag(weekday)
                    }
                }
                DatePicker("Next week time", selection: timeBinding(\.nextWeekMinutes), displayedComponents: .hourAndMinute)
            }
            Section {
                Button("Use default times") { preferences.settings = SnoozeSettings() }
            } footer: {
                Text("Changes apply to future snoozes. Conversations already snoozed keep their return times.")
            }
        }
        .environment(\.timeZone, .gmt)
        .navigationTitle("Snooze settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }

    private func timeBinding(_ keyPath: WritableKeyPath<SnoozeSettings, Int>) -> Binding<Date> {
        Binding {
            SnoozeSettings.clockDate(minutes: preferences.settings[keyPath: keyPath])
        } set: { date in
            preferences.settings[keyPath: keyPath] = SnoozeSettings.clockMinutes(date: date)
        }
    }
}
