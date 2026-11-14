import SwiftUI

enum InboxPullAction: String, CaseIterable, Identifiable {
    case off, search, compose
    var id: Self { self }
    var title: String {
        switch self {
        case .off: "Off"
        case .search: "Search"
        case .compose: "New email"
        }
    }
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var pullAction: InboxPullAction
    @Binding var bottomCompose: Bool

    var body: some View {
        Form {
            Section {
                NavigationLink("Snooze settings") { SnoozeSettingsView() }
            }
            Section("Labs") {
                Picker("Inbox pull-down", selection: $pullAction) {
                    ForEach(InboxPullAction.allCases) { action in
                        Text(action.title).tag(action)
                    }
                }
                Toggle("Compose at bottom right", isOn: $bottomCompose)
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }
}

struct InboxPullModifier: ViewModifier {
    let mode: InboxPullAction
    let action: @MainActor () -> Void
    @State private var distance: CGFloat = 0
    @State private var pending = false

    func body(content: Content) -> some View {
        if mode == .off {
            content
        } else if #available(iOS 18, *) {
            content
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    max(0, -geometry.contentOffset.y - geometry.contentInsets.top)
                } action: { _, value in
                    distance = value
                    if value >= 80 { pending = true }
                }
                .onScrollPhaseChange { _, new in
                    if new == .tracking { pending = false }
                    if new == .idle && pending {
                        pending = false
                        action()
                    }
                }
                .overlay(alignment: .top) {
                    if distance > 15 {
                        Label(mode == .search ? "Search" : "New email", systemImage: mode == .search ? "magnifyingglass" : "square.and.pencil")
                            .font(.subheadline).padding(10)
                            .foregroundStyle(distance >= 80 ? .teal : .secondary)
                            .background(.regularMaterial, in: Capsule())
                            .padding(.top, 8).allowsHitTesting(false)
                    }
                }
        } else {
            content.refreshable { action() }
        }
    }
}

struct LabsBottomBar: View {
    @Binding var selection: Workflow
    let unreadCount: Int
    let compose: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 0) {
                ForEach(Workflow.allCases) { status in
                    Button { selection = status } label: {
                        VStack(spacing: 3) {
                            Image(systemName: status.symbol).font(.title3)
                                .overlay(alignment: .topTrailing) {
                                    if status == .inbox && unreadCount > 0 {
                                        Text("\(unreadCount)").font(.caption2).bold()
                                            .padding(.horizontal, 4).background(.red, in: Capsule())
                                            .foregroundStyle(.white).offset(x: 12, y: -7)
                                    }
                                }
                            Text(status.title).font(.caption2)
                        }
                        .foregroundStyle(selection == status ? Color.teal : Color.primary)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(selection == status ? Color.primary.opacity(0.08) : .clear, in: Capsule())
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(status.title)
                    .accessibilityAddTraits(selection == status ? .isSelected : [])
                }
            }
            .padding(4)
            .modifier(LabsGlass())
            Button(action: compose) {
                Image(systemName: "square.and.pencil").font(.title2)
                    .frame(width: 60, height: 60)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.teal)
            .modifier(LabsGlass())
            .accessibilityLabel("Compose")
        }
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 4)
    }
}

private struct LabsGlass: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.glassEffect(.regular.interactive(), in: Capsule())
        } else {
            content.background(.regularMaterial, in: Capsule())
        }
    }
}
