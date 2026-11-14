import SwiftUI

struct MailboxView: View {
    @Environment(MailStore.self) private var store
    @State private var selection: Workflow = .inbox
    @State private var search = ""
    @AppStorage("inboxUnreadFirst") private var unreadFirst = false
    @State private var settings = false
    @State private var searching = false
    @State private var pull = InboxPullInteraction()
    @State private var toolbarBottom: CGFloat = 0
    @State private var overlayTop: CGFloat?
    @AppStorage("inboxPullAction") private var pullAction: InboxPullAction = .off
    @AppStorage("bottomCompose") private var bottomCompose = false
    @State private var composer: ComposeMode?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var demo = false
    @State private var snoozing: Conversation?
    @State private var peeking: UUID?
    @State private var paths: [Workflow: [UUID]] = [:]
    var body: some View {
        let pullDistance = pull.distance
        let armCount = pull.armCount
        return tabs
        .overlay {
            GeometryReader { geometry in
                if let overlayTop, selection == .inbox, paths[.inbox, default: []].isEmpty,
                   pullAction != .off, pullDistance > 40, toolbarBottom > 0,
                   !searching, composer == nil, !settings, !demo {
                    PullActionIndicator(mode: pullAction, progress: min(1, max(0, (pullDistance - 40) / (DeliberatePull.threshold - 40))), armCount: armCount)
                        .position(x: geometry.size.width / 2, y: toolbarBottom - overlayTop + 32)
                        .opacity(min(1, (pullDistance - 40) / 16))
                }
            }
            .background(PullPlacementReader { frame, controlsBottom in
                overlayTop = frame.minY
                toolbarBottom = controlsBottom
            })
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .blur(radius: peeking == nil ? 0 : 6)
        .allowsHitTesting(peeking == nil)
        .accessibilityHidden(peeking != nil)
        .overlay {
            if let id = peeking, let conversation = store.conversation(id) {
                ConversationPeekView(
                    conversation: conversation,
                    onDismiss: { peeking = nil },
                    onOpen: {
                        peeking = nil
                        paths[selection, default: []].append(id)
                    },
                    onCompose: { mode in
                        peeking = nil
                        openComposer(mode)
                    },
                    onSnooze: { snoozing = conversation }
                )
                .transition(.opacity.combined(with: .scale(scale: reduceMotion ? 1 : 0.97)))
            }
        }
        .animation(.easeOut(duration: reduceMotion ? 0 : 0.18), value: peeking)
        .onChange(of: selection) { _, _ in peeking = nil; searching = false }
        .onChange(of: store.conversations) { _, conversations in
            if let id = peeking, !conversations.contains(where: { $0.id == id && $0.workflow == selection }) {
                peeking = nil
            }
        }
        .sheet(item: $composer) { ComposerView(mode: $0) }
        .sheet(isPresented: $settings) {
            NavigationStack { SettingsView(pullAction: $pullAction, bottomCompose: $bottomCompose) }
        }
        .sheet(isPresented: $demo) { DemoView() }
        .sheet(item: $snoozing) { SnoozeView(id: $0.id, beforeSnooze: { peeking = nil }) }
        .alert(
            "Demo storage",
            isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })
        ) {
            Button("OK") { store.error = nil }
        } message: {
            Text(store.error ?? "")
        }
    }
    private enum MailboxTab: Hashable {
        case workflow(Workflow), compose
    }

    @ViewBuilder private var tabs: some View {
        if #available(iOS 27, *) {
            TabView(selection: Binding<MailboxTab>(get: { .workflow(selection) }, set: { tab in
                switch tab {
                case .workflow(let status): selection = status
                case .compose: openComposer(.new)
                }
            })) {
                ForEach(Workflow.allCases) { status in
                    Tab(status.title, systemImage: status.symbol, value: MailboxTab.workflow(status)) {
                        section(status)
                    }
                    .badge(status == .inbox ? store.list(.inbox).filter(\.unread).count : 0)
                }
                if bottomCompose {
                    Tab("Compose", systemImage: "square.and.pencil", value: MailboxTab.compose, role: .prominent) {
                        Color.clear
                    }
                }
            }
        } else {
            TabView(selection: $selection) {
                ForEach(Workflow.allCases) { status in
                    section(status)
                        .tabItem { Label(status.title, systemImage: status.symbol) }
                        .tag(status)
                        .badge(status == .inbox ? store.list(.inbox).filter(\.unread).count : 0)
                }
            }
        }
    }

    private func section(_ status: Workflow) -> some View {
        NavigationStack(
            path: Binding(get: { paths[status, default: []] }, set: { paths[status] = $0 })
        ) {
            mailbox(status)
                .safeAreaInset(edge: .bottom, spacing: 0) { undoBanner }
                .navigationTitle(status.title)
                .searchable(text: $search, isPresented: Binding(
                    get: { searching && selection == status },
                    set: { if selection == status { searching = $0 } }
                ), prompt: "Search this section")
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Menu {
                            Button("Demo", systemImage: "play.circle") { demo = true }
                            Button("Settings", systemImage: "gearshape") {
                                settings = true
                            }
                        } label: {
                            Label("More", systemImage: "ellipsis.circle")

                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        if status == .inbox {
                            Button {
                                withAnimation { unreadFirst.toggle() }
                            } label: {
                                Label(
                                    "Filter",
                                    systemImage: unreadFirst
                                        ? "line.3.horizontal.decrease.circle.fill"
                                        : "line.3.horizontal.decrease.circle")
                            }
                            .accessibilityValue(unreadFirst ? "Unread first" : "All")
                            .accessibilityAddTraits(unreadFirst ? .isSelected : [])
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        if !bottomCompose {
                            Button("Compose", systemImage: "square.and.pencil") { openComposer(.new) }
                        }
                    }
                }
                .toolbar {
                    if legacyBottomCompose {
                            ToolbarItem(placement: .bottomBar) {
                                Button("Compose", systemImage: "square.and.pencil") { openComposer(.new) }
                            }
                    }
                }
                .navigationDestination(for: UUID.self) { ThreadView(id: $0) }
        }
    }
    private var legacyBottomCompose: Bool {
        if #available(iOS 27, *) { return false }
        return bottomCompose
    }

    @ViewBuilder private var undoBanner: some View {
        if let notice = store.notice {
            HStack {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.teal)
                Text(notice).font(.subheadline)
                Spacer()
                Button("Undo") { withAnimation { store.undo() } }.fontWeight(.semibold)
                Button("Dismiss", systemImage: "xmark") { store.clearNotice() }.labelStyle(.iconOnly)
            }
            .padding().background(.regularMaterial)
        }
    }
    @ViewBuilder private func mailbox(_ status: Workflow) -> some View {
        let items = store.list(status, search: search, unreadFirst: unreadFirst)
        if items.isEmpty {
            if status == .inbox && pullAction != .off && search.isEmpty {
                ScrollView {
                    ContentUnavailableView("You're all caught up", systemImage: status.symbol)
                        .background(PullScrollObserver(interaction: pull, action: performPull))
                        .frame(maxWidth: .infinity).padding(.top, 80)
                }
                .scrollBounceBehavior(.always)
                .modifier(InboxPullModifier(mode: pullAction, interaction: pull))
            } else {
                ContentUnavailableView(
                    search.isEmpty
                        ? (status == .inbox ? "You're all caught up" : "No \(status.rawValue) conversations")
                        : "No results", systemImage: search.isEmpty ? status.symbol : "magnifyingglass",
                    description: Text(search.isEmpty ? "" : "Try another search in this section.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            List {
                Section {
                    ForEach(items) { conversation in
                        NavigationLink(value: conversation.id) { ConversationRow(conversation: conversation) }
                            .listRowInsets(EdgeInsets(top: 15, leading: 18, bottom: 15, trailing: 16))
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                if status != .settled {
                                    Button("Settle", systemImage: "checkmark") {
                                        act { store.move(conversation.id, to: .settled) }
                                    }.tint(.teal)
                                    Button("Snooze", systemImage: "clock") { snoozing = conversation }.tint(.orange)
                                } else {
                                    Button("Restore", systemImage: "tray") {
                                        act { store.move(conversation.id, to: .inbox) }
                                    }.tint(.blue)
                                }
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                Button(
                                    conversation.unread ? "Read" : "Unread",
                                    systemImage: conversation.unread ? "envelope.open" : "envelope.badge"
                                ) { act { store.markRead(conversation.id, unread: !conversation.unread) } }.tint(
                                    .blue)
                                Button(
                                    conversation.pinned ? "Unpin" : "Pin",
                                    systemImage: conversation.pinned ? "pin.slash" : "pin"
                                ) { act { store.togglePin(conversation.id) } }.tint(.orange)
                            }
                            .simultaneousGesture(
                                LongPressGesture().onEnded { _ in
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                    peeking = conversation.id
                                }
                            )
                            .accessibilityAction(named: "Peek") { peeking = conversation.id }
                    }
                } header: {
                    VStack(alignment: .leading, spacing: 0) {
                        if status == .inbox {
                            let unreadCount = items.filter(\.unread).count
                            if unreadCount > 0 { Text("\(unreadCount) unread").textCase(nil) }
                        } else {
                            Text("\(items.count) conversations").textCase(nil)
                        }
                        Color.clear.frame(height: 0)
                    }
                    .background {
                        if status == .inbox && pullAction != .off {
                            PullScrollObserver(interaction: pull, action: performPull)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .modifier(InboxPullModifier(mode: status == .inbox ? pullAction : .off, interaction: pull))
        }
    }
    private func performPull() {
        guard pullAction != .off else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if pullAction == .search { searching = true }
            if pullAction == .compose { openComposer(.new) }
        }
    }
    private func openComposer(_ mode: ComposeMode) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { composer = mode }
    }
    private func act(_ action: () -> Void) {
        withAnimation { action() }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}

struct ConversationRow: View {
    let conversation: Conversation
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(conversation.unread ? Color.teal : .clear).frame(width: 7, height: 7).padding(.top, 7)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(conversation.correspondent.sender).font(.subheadline).fontWeight(conversation.unread ? .bold : .medium).lineLimit(1)
                    if conversation.messages.count > 1 {
                        Text("\(conversation.messages.count)").font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Text(conversation.latest.date, format: Calendar.current.isDateInToday(conversation.latest.date) ? .dateTime.hour().minute() : .dateTime.month(.abbreviated).day()).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Text(conversation.subject).font(.subheadline).fontWeight(conversation.unread ? .semibold : .regular).lineLimit(1)
                Text(conversation.latest.body.replacingOccurrences(of: "\n", with: " ")).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                HStack(spacing: 6) {
                    Text(conversation.account.name).font(.caption2).foregroundStyle(.secondary)
                    if conversation.pinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.orange).accessibilityLabel("Pinned") }
                    if let date = conversation.snoozedUntil {
                        Image(systemName: "clock").font(.caption2)
                        Text(date, format: .dateTime.weekday(.abbreviated).hour().minute()).font(.caption2)
                    }
                }.padding(.top, 2)
            }
        }.padding(.vertical, 1)
        .accessibilityElement(children: .combine)
        .accessibilityValue(conversation.unread ? "Unread" : "Read")
    }
}
