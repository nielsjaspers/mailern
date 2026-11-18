import SwiftUI

struct SnoozeView: View {
    @Environment(MailStore.self) private var store
    @Environment(DraftStore.self) private var drafts
    @Environment(\.dismiss) private var dismiss
    let ids: Set<UUID>
    var draftIDs: Set<UUID> = []
    var beforeSnooze: () -> Void = {}
    var onSnooze: () -> Void = {}
    @State private var saving = false

    var body: some View {
        NavigationStack {
            SnoozeOptionsForm(customLabel: "Return to Inbox", confirmTitle: { "Snooze until \($0.formatted(date: .abbreviated, time: .shortened))" },
                              pick: snooze) {
                Section {
                    NavigationLink("Snooze settings") { SnoozeSettingsView() }
                }
            }
            .navigationTitle("Snooze").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }.presentationDetents([.large])
        .disabled(saving)
        .interactiveDismissDisabled(saving)
        .modifier(DraftStorageAlert(active: true))
    }
    private func snooze(_ date: Date) {
        guard date > .now else { return }
        guard !saving else { return }
        saving = true
        Task {
            defer { saving = false }
            if !draftIDs.isEmpty, !(await drafts.snooze(draftIDs, until: date)) { return }
            guard ids.isEmpty || store.apply(ids: ids, action: .move(.snoozed, until: date)) else { return }
            beforeSnooze()
            dismiss(); onSnooze()
        }
    }
}

/// The snooze presets and a custom date. Snooze, Send Later, and follow-up reminders all pick their time here.
struct SnoozeOptionsForm<Footer: View>: View {
    @Environment(SnoozePreferences.self) private var preferences
    let customLabel: String
    let confirmTitle: (Date) -> String
    let pick: (Date) -> Void
    @ViewBuilder var footer: Footer
    @State private var date = Date.now.addingTimeInterval(3600)

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Form {
                Section {
                    ForEach(preferences.settings.options(now: context.date)) { option in
                        Button {
                            // Resolve relative delays when tapped, even if the sheet has been open for a while.
                            if let current = preferences.settings.options(now: .now).first(where: { $0.id == option.id }) {
                                pick(current.date)
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
                    DatePicker(customLabel, selection: $date, in: context.date.addingTimeInterval(1)...)
                    Button(confirmTitle(date)) { pick(date) }
                        .disabled(date <= context.date)
                }
                footer
            }
        }
    }
}

extension SnoozeOptionsForm where Footer == EmptyView {
    init(customLabel: String, confirmTitle: @escaping (Date) -> String, pick: @escaping (Date) -> Void) {
        self.init(customLabel: customLabel, confirmTitle: confirmTitle, pick: pick) { EmptyView() }
    }
}
