import SwiftUI

struct MailboxFilterControl: View {
    let filter: MailboxFilter
    let status: Workflow
    let toggle: () -> Void
    let options: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: toggle) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(filter.enabled ? Color.white : Color.primary)
                    .frame(width: 40, height: 40)
                    .background { if filter.enabled { Circle().fill(.tint) } }
                    .padding(2)
                    .contentShape(Circle())
            }
            .accessibilityLabel("Filter")
            .accessibilityValue(filter.enabled ? filter.summary(for: status) : "Off")
            .accessibilityAddTraits(filter.enabled ? .isSelected : [])

            if filter.enabled {
                Button(action: options) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Filtered by")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        HStack(spacing: 3) {
                            Text(filter.summary(for: status)).lineLimit(1)
                            Image(systemName: "chevron.down").font(.caption.weight(.semibold))
                        }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.tint)
                    }
                    .frame(maxWidth: 120, alignment: .leading)
                    .padding(.trailing, 8)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .accessibilityLabel("Filter options")
                .accessibilityValue(filter.summary(for: status))
            }
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
    }
}

struct MailboxFilterView: View {
    let status: Workflow
    @Binding var filter: MailboxFilter
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Include mail from") {
                    accountRow("All accounts", selected: filter.accountIDs == nil) {
                        update { $0.accountIDs = nil }
                    }
                    ForEach(MailAccount.demo) { account in
                        Button {
                            update { filter in
                                var ids = filter.accountIDs ?? Set(MailAccount.demo.map(\.id))
                                if !ids.insert(account.id).inserted { ids.remove(account.id) }
                                filter.accountIDs = ids == Set(MailAccount.demo.map(\.id)) ? nil : ids
                            }
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(account.name).foregroundStyle(.primary)
                                    Text(account.address).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if filter.accountIDs?.contains(account.id) ?? true {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }.contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("filter-account-\(account.id)")
                        .accessibilityValue(filter.accountIDs?.contains(account.id) ?? true ? "Included" : "Excluded")
                    }
                }
                if status != .settled {
                    Section("Read status") {
                        ForEach(MailReadFilter.allCases) { readStatus in
                            accountRow(readStatus.title, selected: filter.readStatus == readStatus) {
                                update { $0.readStatus = readStatus }
                            }
                            .accessibilityIdentifier("filter-read-\(readStatus.rawValue)")
                        }
                    }
                    Section {
                        Toggle("Only drafts", isOn: criteria(\.onlyDrafts))
                    }
                } else {
                    Section {
                        Toggle("Only sent", isOn: criteria(\.onlySent))
                    }
                }
                Section {
                    Button("Reset filters") { filter = .initial(for: status) }
                }
            }
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
            }
        }
    }

    private func accountRow(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).foregroundStyle(.primary)
                Spacer()
                if selected { Image(systemName: "checkmark").foregroundStyle(.tint) }
            }.contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func criteria(_ keyPath: WritableKeyPath<MailboxFilter, Bool>) -> Binding<Bool> {
        Binding(get: { filter[keyPath: keyPath] }, set: { value in update { $0[keyPath: keyPath] = value } })
    }

    private func update(_ change: (inout MailboxFilter) -> Void) {
        var updated = filter
        change(&updated)
        updated.enabled = true
        filter = updated
    }
}
