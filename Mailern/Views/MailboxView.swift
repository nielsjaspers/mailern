import SwiftUI

struct MailboxView: View {
    @Environment(MailStore.self) private var store
    @State private var selection: Workflow = .inbox
    @State private var search = ""
    @AppStorage("inboxUnreadFirst") private var unreadFirst = false
    @Namespace private var composeTransition
    @Environment(DraftStore.self) private var drafts
    @State private var selecting = false
    @State private var selectedIDs: Set<UUID> = []
    @State private var bulkSnooze = false
    @State private var settings = false
    @State private var searching = false
    @State private var pull = InboxPullInteraction()
    @State private var toolbarBottom: CGFloat = 0
    @State private var overlayTop: CGFloat?
    @AppStorage("inboxPullAction") private var pullAction: InboxPullAction = .off
    @AppStorage("bottomCompose") private var bottomCompose = false
    @AppStorage("leftSwipePrimary") private var leftPrimary: MailboxSwipeAction = .workflow
    @AppStorage("leftSwipeSecondary") private var leftSecondary: MailboxSwipeAction = .snooze
    @AppStorage("rightSwipePrimary") private var rightPrimary: MailboxSwipeAction = .read
    @AppStorage("rightSwipeSecondary") private var rightSecondary: MailboxSwipeAction = .pin
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
                   !selecting, pullAction != .off, pullDistance > 40, toolbarBottom > 0,
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
        .onChange(of: selection) { _, _ in peeking = nil; searching = false; endSelection() }
        .onChange(of: search) { _, _ in pruneSelection() }
        .onChange(of: drafts.drafts) { _, saved in
            store.clearWorkflowUndo(involving: Set(saved.compactMap { $0.mode.replyID }))
            pruneSelection()
        }
        .onChange(of: store.conversations) { _, conversations in
            pruneSelection()
            if let id = peeking, !conversations.contains(where: { $0.id == id && $0.workflow == selection }) {
                peeking = nil
            }
        }
        .sheet(item: $composer) {
            ComposerView(mode: $0).modifier(ComposerTransition(source: composerSourceID, namespace: composeTransition))
        }
        .modifier(DraftStorageAlert(active: composer == nil && paths[selection, default: []].isEmpty))
        .sheet(isPresented: $settings) {
            NavigationStack { SettingsView(pullAction: $pullAction, bottomCompose: $bottomCompose) }
        }
        .sheet(isPresented: $demo) { DemoView() }
        .sheet(isPresented: $bulkSnooze) {
            SnoozeView(ids: selectedIDs, beforeSnooze: endSelection)
        }
        .sheet(item: $snoozing) { SnoozeView(ids: [$0.id], beforeSnooze: { peeking = nil }) }
        .alert(
            "Mail storage",
            isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })
        ) {
            if store.needsReload { Button("Retry") { store.reload() } }
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
                    .badge(status == .inbox ? items(.inbox, search: "").filter(\.unread).count : 0)
                }
                if bottomCompose {
                    Tab(value: MailboxTab.compose, role: .prominent) {
                        Color.clear
                    } label: {
                        Label("Compose", systemImage: "square.and.pencil")
                            .modifier(ComposerSource(source: "compose-bottom", namespace: composeTransition))
                    }
                }
            }
            .background(ComposeTabAction(enabled: bottomCompose) { openComposer(.new) })
        } else {
            TabView(selection: $selection) {
                ForEach(Workflow.allCases) { status in
                    section(status)
                        .tabItem { Label(status.title, systemImage: status.symbol) }
                        .tag(status)
                        .badge(status == .inbox ? items(.inbox, search: "").filter(\.unread).count : 0)
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
                .modifier(MailboxSearchToolbar())
                .toolbar { mailboxToolbar(status) }
                .toolbar {
                    if legacyBottomCompose && !selecting {
                        ToolbarItem(placement: .bottomBar) {
                            Button("Compose", systemImage: "square.and.pencil") { openComposer(.new) }
                                .modifier(ComposerSource(source: "compose-\(status.rawValue)", namespace: composeTransition))
                        }
                    }
                }
                .toolbar {
                    BulkSelectionToolbar(active: selecting, status: status, count: selectedIDs.count,
                                         hasDrafts: drafts.drafts.contains { $0.mode.replyID.map(selectedIDs.contains) ?? false },
                                         hasUnread: selectedConversations.contains { $0.unread },
                                         allPinned: !selectedIDs.isEmpty && selectedConversations.allSatisfy { $0.pinned },
                                         apply: applySelection, snooze: { bulkSnooze = true })
                }
                .toolbar(selecting || !paths[status, default: []].isEmpty ? .hidden : .visible, for: .tabBar)
                .navigationDestination(for: UUID.self) { id in
                    if store.conversation(id) != nil { ThreadView(id: id) }
                    else { DraftThreadView(id: id) }
                }
        }
    }
    @ToolbarContentBuilder private func mailboxToolbar(_ status: Workflow) -> some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if selecting {
                let visibleIDs = Set(items(status).filter { $0.conversation != nil }.map(\.id))
                let allSelected = !visibleIDs.isEmpty && visibleIDs.isSubset(of: selectedIDs)
                Button(allSelected ? "Deselect All" : "Select All") {
                    selectedIDs = allSelected ? [] : visibleIDs
                }
                .disabled(visibleIDs.isEmpty)
            } else {
                Menu {
                    Button("Demo", systemImage: "play.circle") { demo = true }
                    if drafts.needsReload { Button("Retry loading drafts", systemImage: "arrow.clockwise") { Task { await drafts.reload() } } }
                    Button("Settings", systemImage: "gearshape") { settings = true }
                    if store.needsReload { Button("Retry loading mail", systemImage: "arrow.clockwise") { store.reload() } }
                } label: { Label("More", systemImage: "ellipsis.circle") }
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button(selecting ? "Cancel" : "Select") {
                if selecting { endSelection() }
                else { peeking = nil; pull.cancel(); selecting = true }
            }
        }
        if #available(iOS 26, *), !selecting, status == .inbox || !bottomCompose {
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
        }
        ToolbarItem(placement: .topBarTrailing) {
            if status == .inbox && !selecting {
                Button { withAnimation { unreadFirst.toggle() } } label: {
                    Label("Filter", systemImage: unreadFirst
                          ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }
                .accessibilityValue(unreadFirst ? "Unread first" : "All")
                .accessibilityAddTraits(unreadFirst ? .isSelected : [])
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            if !bottomCompose && !selecting {
                Button("Compose", systemImage: "square.and.pencil") { openComposer(.new) }
                    .modifier(ComposerSource(source: "compose-\(status.rawValue)", namespace: composeTransition))
            }
        }
    }
    private var composerSourceID: String {
        if #available(iOS 27, *), bottomCompose { return "compose-bottom" }
        return "compose-\(selection.rawValue)"
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
        let items = items(status)
        if items.isEmpty {
            if status == .inbox && pullAction != .off && search.isEmpty && !selecting {
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
            List(selection: selecting ? $selectedIDs : nil) {
                Section {
                    ForEach(items) { item in
                        if let conversation = item.conversation {
                            Button {
                                if selecting {
                                    if selectedIDs.contains(conversation.id) { selectedIDs.remove(conversation.id) }
                                    else { selectedIDs.insert(conversation.id) }
                                } else if peeking == nil { paths[status, default: []].append(conversation.id) }
                            } label: {
                                HStack {
                                    ConversationRow(conversation: conversation, hasDraft: item.hasDraft)
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(.tertiary)
                                }
                                .contentShape(Rectangle())
                            }
                                .buttonStyle(.plain)
                                .listRowBackground(item.hasDraft ? Color.orange.opacity(0.07) : Color.clear)
                                .tag(conversation.id)
                                .listRowInsets(EdgeInsets(top: 15, leading: 18, bottom: 15, trailing: 16))
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    swipeButtons(primary: leftPrimary, secondary: leftSecondary, conversation: conversation, hasDraft: item.hasDraft)
                                }
                                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                    swipeButtons(primary: rightPrimary, secondary: rightSecondary, conversation: conversation, hasDraft: item.hasDraft)
                                }
                                .gesture(EmptySwipeGuard(
                                    left: !hasSwipeActions(primary: leftPrimary, secondary: leftSecondary, conversation: conversation),
                                    right: !hasSwipeActions(primary: rightPrimary, secondary: rightSecondary, conversation: conversation)
                                ))
                                .simultaneousGesture(
                                    LongPressGesture().onEnded { _ in
                                        guard !selecting else { return }
                                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                        peeking = conversation.id
                                    }
                                )
                                .accessibilityAction(named: "Peek") { if !selecting { peeking = conversation.id } }
                        } else if let draft = item.drafts.first {
                            NavigationLink(value: draft.id) { DraftRow(draft: draft) }
                                .selectionDisabled()
                                .disabled(selecting)
                                .listRowInsets(EdgeInsets(top: 15, leading: 18, bottom: 15, trailing: 16))
                                .listRowBackground(Color.orange.opacity(0.07))
                        }
                    }
                } header: {
                    VStack(alignment: .leading, spacing: 0) {
                        if selecting {
                            Text("\(selectedIDs.count) selected").textCase(nil)
                        } else if status == .inbox {
                            let unreadCount = items.filter(\.unread).count
                            Text(unreadCount > 0 ? "\(unreadCount) unread" : "All read").textCase(nil)
                        } else {
                            Text("\(items.count) conversations").textCase(nil)
                        }
                        Color.clear.frame(height: 0)
                    }
                    .background {
                        if status == .inbox && pullAction != .off && !selecting {
                            PullScrollObserver(interaction: pull, action: performPull)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .environment(\.editMode, .constant(selecting ? .active : .inactive))
            .modifier(InboxPullModifier(mode: status == .inbox && !selecting ? pullAction : .off, interaction: pull))
        }
    }
    private func hasSwipeActions(primary: MailboxSwipeAction, secondary: MailboxSwipeAction, conversation: Conversation) -> Bool {
        primary != .none && (primary != .read || conversation.workflow != .settled || (secondary != .none && secondary != .read))
    }

    @ViewBuilder private func swipeButtons(
        primary: MailboxSwipeAction, secondary: MailboxSwipeAction, conversation: Conversation, hasDraft: Bool
    ) -> some View {
        if primary != .none && !selecting {
            swipeButton(primary, conversation: conversation, hasDraft: hasDraft)
            if secondary != .none && secondary != primary {
                swipeButton(secondary, conversation: conversation, hasDraft: hasDraft)
            }
        }
    }

    @ViewBuilder private func swipeButton(_ action: MailboxSwipeAction, conversation: Conversation, hasDraft: Bool) -> some View {
        switch action {
        case .workflow:
            Button(conversation.workflow == .settled ? "Restore" : "Settle",
                   systemImage: conversation.workflow == .settled ? "tray" : "checkmark") {
                act { store.move(conversation.id, to: conversation.workflow == .settled ? .inbox : .settled) }
            }.tint(conversation.workflow == .settled ? .blue : .teal).disabled(hasDraft)
        case .read:
            if conversation.workflow != .settled {
                Button(conversation.unread ? "Read" : "Unread",
                       systemImage: conversation.unread ? "envelope.open" : "envelope.badge") {
                    act { store.markRead(conversation.id, unread: !conversation.unread) }
                }.tint(.blue)
            }
        case .snooze:
            Button("Snooze", systemImage: "clock") { snoozing = conversation }.tint(.orange).disabled(hasDraft)
        case .pin:
            Button(conversation.pinned ? "Unpin" : "Pin",
                   systemImage: conversation.pinned ? "pin.slash" : "pin") {
                act { store.togglePin(conversation.id) }
            }.tint(.orange)
        case .none:
            EmptyView()
        }
    }

    private func items(_ status: Workflow, search: String? = nil) -> [MailboxItem] {
        MailboxItem.list(conversations: store.conversations, drafts: drafts.drafts, status: status, search: search ?? self.search, unreadFirst: unreadFirst)
    }
    private var selectedConversations: [Conversation] {
        store.conversations.filter { selectedIDs.contains($0.id) }
    }
    private func endSelection() { selecting = false; selectedIDs = [] }
    private func pruneSelection() {
        selectedIDs.formIntersection(items(selection).filter { $0.conversation != nil }.map(\.id))
    }
    private func applySelection(_ action: ConversationAction) {
        let ids = selectedIDs
        endSelection()
        act { store.apply(ids: ids, action: action) }
    }
    private func performPull() {
        guard pullAction != .off && !selecting else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        if pullAction == .search { withTransaction(transaction) { searching = true } }
        if pullAction == .compose { openComposer(.new) }
    }
    private func openComposer(_ mode: ComposeMode) {
        composer = mode
    }
    private func act(_ action: () -> Void) {
        withAnimation { action() }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}

private struct MailboxSearchToolbar: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 17.1, *) {
            content.searchPresentationToolbarBehavior(.avoidHidingContent)
        } else { content }
    }
}

struct BulkSelectionToolbar: ToolbarContent {
    let active: Bool
    let status: Workflow
    let count: Int
    var hasDrafts = false
    let hasUnread: Bool
    let allPinned: Bool
    let apply: (ConversationAction) -> Void
    let snooze: () -> Void

    var body: some ToolbarContent {
        if active {
            ToolbarItemGroup(placement: .bottomBar) {
                Button(status == .settled ? "Restore" : "Settle", systemImage: status == .settled ? "tray" : "checkmark") {
                    apply(.move(status == .settled ? .inbox : .settled))
                }.disabled(count == 0 || hasDrafts)
                Spacer()
                Button("Snooze", systemImage: "clock", action: snooze).disabled(count == 0 || hasDrafts)
                Spacer()
                Menu {
                    if status != .settled {
                        Button(hasUnread ? "Mark read" : "Mark unread",
                               systemImage: hasUnread ? "envelope.open" : "envelope.badge") {
                            apply(.read(unread: !hasUnread))
                        }
                    }
                    if status == .snoozed {
                        Button("Restore to Inbox", systemImage: "tray") { apply(.move(.inbox)) }
                    }
                    Button(allPinned ? "Unpin" : "Pin", systemImage: allPinned ? "pin.slash" : "pin") {
                        apply(.pin(!allPinned))
                    }
                } label: { Label("Mark", systemImage: "ellipsis.circle") }
                .disabled(count == 0)
            }
        }
    }
}

struct ConversationRow: View {
    let conversation: Conversation
    var hasDraft = false
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(conversation.unread ? Color.teal : .clear).frame(width: 7, height: 7).padding(.top, 7)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    if hasDraft { Image(systemName: "square.and.pencil").foregroundStyle(.orange).accessibilityLabel("Draft") }
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
                    if !hasDraft, let date = conversation.snoozedUntil {
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

// Cancel row activation only for horizontal drags with no available swipe action.
private struct EmptySwipeGuard: UIGestureRecognizerRepresentable {
    let left: Bool
    let right: Bool

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }
    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let recognizer = UIPanGestureRecognizer()
        recognizer.delegate = context.coordinator
        return recognizer
    }
    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        context.coordinator.left = left
        context.coordinator.right = right
    }
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var left = false
        var right = false
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view)
            guard abs(velocity.x) > abs(velocity.y) else { return false }
            return velocity.x > 0 ? right : left
        }
    }
}
