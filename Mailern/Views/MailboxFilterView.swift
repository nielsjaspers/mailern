import SwiftUI

@available(iOS 26, *)
struct MailboxFilterToolbar: View {
    let filter: MailboxFilter
    let status: Workflow
    let accounts: [MailAccount]
    let select: () -> Void
    let toggle: () -> Void
    let options: () -> Void
    @Namespace private var glass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let control = MailboxFilterControl(filter: filter, status: status, accounts: accounts, toggle: toggle, options: options)
        GlassEffectContainer(spacing: 16) {
            FilterToolbarLayout(expansion: filter.enabled ? 1 : 0) {
                Button(action: select) {
                    Text("Select")
                        .padding(.horizontal, 16)
                        .frame(minHeight: 44)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .glassEffect(.regular.interactive(), in: .capsule)
                Group {
                    if filter.enabled {
                        control.summary
                            .glassEffect(.regular.interactive(), in: .capsule)
                            .glassEffectUnion(id: "filter", namespace: glass)
                    } else {
                        control.summary.hidden().accessibilityHidden(true)
                    }
                }
                control.toggleButton
                    .glassEffect(.regular.interactive(), in: .capsule)
                    .glassEffectUnion(id: "filter", namespace: glass)
                MailboxFilterControl(filter: .initial(for: status), status: status, accounts: accounts, toggle: toggle, options: options)
                    .summary.hidden().accessibilityHidden(true)
            }
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: filter.enabled)
    }
}

// One layout owns the expansion. The toggle never changes position, including between animation frames.
private struct FilterToolbarLayout: Layout {
    var expansion: CGFloat
    var animatableData: CGFloat {
        get { expansion }
        set { expansion = newValue }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let select = subviews[0].sizeThatFits(.unspecified)
        let summary = subviews[1].sizeThatFits(ProposedViewSize(width: 144, height: nil))
        let idealWidth = select.width + 12 + summary.width + 52
        let minimumSummary = min(summary.width, subviews[3].sizeThatFits(.unspecified).width)
        let minimumWidth = select.width + 12 + minimumSummary + 52
        return CGSize(width: max(minimumWidth, min(idealWidth, proposal.width ?? idealWidth)),
                      height: max(44, select.height, summary.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let select = subviews[0].sizeThatFits(.unspecified)
        let available = max(0, bounds.width - select.width - 12 - 52)
        let summary = subviews[1].sizeThatFits(ProposedViewSize(width: min(144, available), height: 44))
        let extra = summary.width
        subviews[0].place(at: CGPoint(x: bounds.minX + extra * (1 - expansion), y: bounds.midY),
                          anchor: .leading, proposal: .unspecified)
        subviews[1].place(at: CGPoint(x: bounds.maxX - 52 - extra, y: bounds.midY),
                          anchor: .leading, proposal: ProposedViewSize(summary))
        subviews[2].place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing,
                          proposal: ProposedViewSize(width: 52, height: 44))
        subviews[3].place(at: bounds.origin, proposal: .unspecified)
    }
}

struct MailboxFilterControl: View {
    let filter: MailboxFilter
    let status: Workflow
    /// Passed in, because the toolbar reads `summary` from an instance that SwiftUI never installs.
    let accounts: [MailAccount]
    let toggle: () -> Void
    let options: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if filter.enabled { summary.frame(maxWidth: 144) }
            toggleButton
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    var summary: some View {
        Button(action: options) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Filtered by")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                HStack(spacing: 3) {
                    Text(filter.summary(for: status, accounts: accounts)).lineLimit(1)
                    Image(systemName: "chevron.down").font(.caption.weight(.semibold))
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.tint)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Filter options")
        .accessibilityValue(filter.summary(for: status, accounts: accounts))
    }

    var toggleButton: some View {
        Button(action: toggle) {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 20, weight: .medium))
                .contentTransition(.identity)
                .foregroundStyle(filter.enabled ? Color.white : Color.primary)
                .frame(width: 48, height: 40)
                .background { Capsule().fill(.tint).opacity(filter.enabled ? 1 : 0) }
                .padding(2)
                .contentShape(Capsule())
                .transaction { $0.animation = nil }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Filter")
        .accessibilityValue(filter.enabled ? filter.summary(for: status, accounts: accounts) : "Off")
        .accessibilityAddTraits(filter.enabled ? .isSelected : [])
    }
}

struct MailboxFilterView: View {
    @Environment(MailStore.self) private var store
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
                    ForEach(store.accounts) { account in
                        Button {
                            update { filter in
                                // A removed account can remain in a stored filter. It no longer counts toward "all".
                                let all = Set(store.accounts.map(\.id))
                                var ids = filter.accountIDs?.intersection(all) ?? all
                                if !ids.insert(account.id).inserted { ids.remove(account.id) }
                                filter.accountIDs = ids == all ? nil : ids
                            }
                        } label: {
                            HStack {
                                Circle().fill(account.color.color).frame(width: 10, height: 10)
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
