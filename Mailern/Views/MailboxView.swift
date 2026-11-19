import SwiftUI

struct MailboxView: View {
    var benchmark: BenchmarkMailbox?
    var selectBenchmark: ((BenchmarkMailbox?) async throws -> Void)?
    @Environment(MailStore.self) private var store
    @State private var selection: Workflow = .inbox
    @State private var searchInput = MailboxSearchInput()
    private var search: String { searchInput.text }
    @AppStorage("mailboxFilters") private var filterData = Data()
    @State private var filtering: Workflow?
    @State private var settling: DraftDiscard?
    @State private var snoozingDraft: ComposerDraft?
    @Environment(DraftStore.self) private var drafts
    @State private var selecting = false
    @State private var selectedIDs: Set<UUID> = []
    @State private var bulkSnooze = false
    @State private var settings = false
    @State private var searching = false
    @State private var searchScope = SearchScope.section
    @State private var pull = InboxPullInteraction()
    @State private var toolbarBottom: CGFloat = 0
    @State private var overlayTop: CGFloat?
    @AppStorage("inboxPullAction") private var pullAction: InboxPullAction = .off
    @AppStorage("leftSwipePrimary") private var leftPrimary: MailboxSwipeAction = .workflow
    @AppStorage("leftSwipeSecondary") private var leftSecondary: MailboxSwipeAction = .snooze
    @AppStorage("rightSwipePrimary") private var rightPrimary: MailboxSwipeAction = .read
    @AppStorage("rightSwipeSecondary") private var rightSecondary: MailboxSwipeAction = .pin
    @AppStorage("leftSwipeTertiary") private var leftTertiary: MailboxSwipeAction = .none
    @AppStorage("rightSwipeTertiary") private var rightTertiary: MailboxSwipeAction = .none
    @State private var panel = ComposerPanel()
    /// The tab the open composer belongs to. A tab switch while it docks keeps its editor alive there, so a failed save
    /// can bring that same editor back.
    @State private var panelTab: Workflow?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var demo = false
    @State private var snoozing: Conversation?
    @State private var peeking: UUID?
    @State private var paths: [Workflow: [MailboxRoute]] = [:]
    /// Each section's list as it was when a conversation opened from it. Opening can drop a conversation from a
    /// filtered list, so Settle and next walks this order.
    @State private var readerLists: [Workflow: [Int: ReaderList]] = [:]
    var body: some View {
        let pullDistance = pull.distance
        let armCount = pull.armCount
        return tabs
        .overlay {
            GeometryReader { geometry in
                if let overlayTop, selection == .inbox, paths[.inbox, default: []].isEmpty,
                   !selecting, pullAction != .off, pullDistance > 40, toolbarBottom > 0,
                   !searching, panel.request == nil, !settings, !demo {
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
        // One place for the haptic of every move, including those made in a thread, a sheet, or a confirmation.
        .sensoryFeedback(.impact(weight: .light), trigger: store.actionCount + drafts.actionCount)
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
                        paths[selection, default: []].append(.conversation(id))
                    },
                    onCompose: { mode in
                        peeking = nil
                        compose(mode)
                    },
                    onSnooze: { snoozing = conversation }
                )
                .transition(.opacity.combined(with: .scale(scale: reduceMotion ? 1 : 0.97)))
            }
        }
        .animation(.easeOut(duration: reduceMotion ? 0 : 0.18), value: peeking)
        .onChange(of: selection) { _, _ in peeking = nil; searching = false; endSelection() }
        .onChange(of: searching) { _, active in if !active { searchScope = .section } }
        // Bulk actions and filters belong to one section, so All mail leaves selection.
        .onChange(of: searchScope) { _, scope in
            if scope == .section { store.endAllMailSearch() }
            peeking = nil
            endSelection()
        }
        .onChange(of: search) { _, _ in pruneSelection() }
        .onChange(of: filterData) { _, _ in peeking = nil; pruneSelection() }
        .onChange(of: drafts.drafts) { _, saved in
            store.clearWorkflowUndo(involving: Set(saved.compactMap { $0.mode.replyID }))
            pruneSelection()
        }
        .onChange(of: store.mailboxRevision) { _, _ in
            pruneSelection()
            if let id = peeking, store.conversation(id)?.workflow != selection {
                peeking = nil
            }
        }
        // Undo Send and Edit take scheduled mail back into the composer from wherever it was sent.
        // An open composer finishes first, so the request waits until its panel is gone.
        .onChange(of: ReopenState(id: drafts.reopening, open: panel.request != nil)) { _, state in
            guard let id = state.id, !state.open else { return }
            drafts.reopening = nil
            compose(.draft(id))
        }
        .onChange(of: panel.request?.id) { _, id in panelTab = id == nil ? nil : (panelTab ?? selection) }
        // A failed save brings the composer back up, on its own tab.
        .onChange(of: panel.covering) { _, covering in
            if covering, let panelTab, panelTab != selection { selection = panelTab }
        }
        .modifier(DraftStorageAlert(active: paths[selection, default: []].isEmpty))
        .sheet(isPresented: $settings) {
            NavigationStack { SettingsView(pullAction: $pullAction) }
        }
        .sheet(isPresented: $demo) { DemoView(benchmark: benchmark, selectBenchmark: selectBenchmark) }
        .sheet(item: $filtering) { status in
            MailboxFilterView(status: status, filter: filterBinding(status))
        }
        .modifier(DiscardDraftsConfirmation(request: $settling, onDone: endSelection))
        .sheet(isPresented: $bulkSnooze) {
            SnoozeView(ids: selectedIDs, beforeSnooze: endSelection)
        }
        .sheet(item: $snoozing) { SnoozeView(ids: [$0.id], beforeSnooze: { peeking = nil }) }
        .sheet(item: $snoozingDraft) { SnoozeView(ids: [], draftIDs: [$0.id]) }
        .environment(panel)
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
    private struct ReopenState: Equatable { var id: UUID?; var open: Bool }
    private func compose(_ mode: ComposeMode) { panel.present(mode, inboxAccountID: composeInboxAccount) }
    private enum SearchScope: CaseIterable, Identifiable {
        case section, allMail
        var id: Self { self }
        var title: String {
            switch self { case .section: "This section"; case .allMail: "All mail" }
        }
    }
    /// The scope choice sits in the content, not in `.searchScopes`. With the large title kept visible during search,
    /// the native scope bar resizes the navigation bar mid-transition and the title jumps over the search field.
    private var scopePicker: some View {
        Picker("Search scope", selection: $searchScope) {
            ForEach(SearchScope.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
    }
    /// True when `status` shows search results from Inbox, Snoozed, and Settled together.
    private func allMail(_ status: Workflow) -> Bool { status == selection && searching && searchScope == .allMail }

    private enum MailboxTab: Hashable {
        case workflow(Workflow), compose
    }

    @ViewBuilder private var tabs: some View {
        if #available(iOS 27, *) {
            TabView(selection: Binding<MailboxTab>(get: { .workflow(selection) }, set: { tab in
                switch tab {
                case .workflow(let status): selection = status
                case .compose: compose(.new)
                }
            })) {
                ForEach(Workflow.allCases) { status in
                    Tab(status.title, systemImage: status.symbol, value: MailboxTab.workflow(status)) {
                        section(status)
                    }
                    .badge(status == .inbox ? store.inboxUnreadCount : 0)
                }
                Tab(value: MailboxTab.compose, role: .prominent) {
                    Color.clear
                } label: {
                    Label("Compose", systemImage: "square.and.pencil")
                }
            }
            .background(ComposeTabAction { compose(.new) })
        } else {
            TabView(selection: $selection) {
                ForEach(Workflow.allCases) { status in
                    section(status)
                        .tabItem { Label(status.title, systemImage: status.symbol) }
                        .tag(status)
                        .badge(status == .inbox ? store.inboxUnreadCount : 0)
                }
            }
        }
    }

    private func section(_ status: Workflow) -> some View {
        NavigationStack(
            path: Binding(get: { paths[status, default: []] }, set: { paths[status] = $0 })
        ) {
            mailboxViewport(status)
                // The Undo banner sits above the dock, so the dock stays put while it shows.
                .safeAreaInset(edge: .bottom, spacing: 0) { UndoBanner() }
                .draftDock()
                .navigationTitle(status.title)
                .searchable(text: $searchInput.text, isPresented: Binding(
                    get: { searching && selection == status },
                    set: { if selection == status { searching = $0 } }
                ), prompt: allMail(status) ? "Search all mail" : "Search \(status.title)")
                .modifier(MailboxSearchToolbar())
                .toolbar { mailboxToolbar(status) }
                .toolbar {
                    if legacyBottomCompose && !selecting && !panel.hidesToolbar {
                        ToolbarItem(placement: .bottomBar) {
                            Button("Compose", systemImage: "square.and.pencil") { compose(.new) }
                        }
                    }
                }
                .toolbar {
                    if selecting && status == selection {
                        let candidates = projection(status).selection
                        BulkSelectionToolbar(status: status, count: selectedIDs.count,
                                             hasUnread: !selectedIDs.isDisjoint(with: candidates.unread),
                                             allPinned: !selectedIDs.isEmpty && selectedIDs.isDisjoint(with: candidates.unpinned),
                                             apply: applySelection, snooze: { bulkSnooze = true })
                    }
                }
                .toolbar(selecting || panel.covering || !paths[status, default: []].isEmpty ? .hidden : .visible, for: .tabBar)
                .navigationDestination(for: MailboxRoute.self) { route in
                    Group {
                        switch route {
                        case .conversation(let id, let depth):
                            if store.conversation(id) != nil {
                                let list = readerLists[status]?[depth]
                                let neighbors = list?.neighbors(of: id, available: readerAvailability(status, depth: depth, list: list))
                                ThreadView(id: id, inboxAccountID: depth == 1 ? composeInboxAccount : nil,
                                           initialQuery: list?.query ?? "", previousID: neighbors?.previous, nextID: neighbors?.next,
                                           next: { neighbors?.next ?? neighbors?.previous }, open: { next in
                                    guard paths[status]?.last == .conversation(id, depth: depth) else { return }
                                    paths[status]?.removeLast()
                                    paths[status]?.append(.conversation(next, depth: depth))
                                }, showSender: { sender in
                                    paths[status, default: []].append(.sender(sender))
                                })
                                // A replaced thread is a new view, so it marks the next conversation read and drops the old one's state.
                                .id(id)
                            }
                            else { DraftThreadView(id: id) }
                        case .sender(let sender): SenderHistoryView(sender: sender) { id, order in openSecondary(id, status: status, order: order, query: "") }
                        case .removed(let mailbox): RemovedMailboxView(mailbox: mailbox) { id, order, query in openSecondary(id, status: status, order: order, query: query) }
                        case .scheduled: ScheduledMailboxView()
                        case .scheduledMessage(let id): ScheduledMessageView(id: id)
                        }
                    }.draftDock()
                }
        }
        // Over the tab's screens and under its tab bar, so the tab bar floats over the docked panel.
        .overlay { if status == (panelTab ?? selection) { ComposerPanelHost() } }
    }
    @ToolbarContentBuilder private func mailboxToolbar(_ status: Workflow) -> some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if selecting {
                let visibleIDs = projection(status).selection.eligible
                let allSelected = !visibleIDs.isEmpty && visibleIDs.count <= selectedIDs.count && visibleIDs.isSubset(of: selectedIDs)
                Button(allSelected ? "Deselect All" : "Select All") {
                    selectedIDs = allSelected ? [] : visibleIDs
                }
                .disabled(visibleIDs.isEmpty)
            } else {
                Menu {
                    Section("Mailboxes") {
                        Button { paths[status, default: []].append(.scheduled) } label: {
                            Label("Scheduled", systemImage: "calendar.badge.clock")
                            let count = drafts.outbox.count
                            Text(count == 0 ? "Empty" : count == 1 ? "1 message" : "\(count) messages")
                        }
                        ForEach(RemovedMailbox.allCases) { mailbox in
                            Button { paths[status, default: []].append(.removed(mailbox)) } label: {
                                Label(mailbox.title, systemImage: mailbox.symbol)
                                let count = store.list(mailbox).count
                                Text(count == 0 ? "Empty" : count == 1 ? "1 conversation" : "\(count) conversations")
                            }
                        }
                    }
                    Button("Demo", systemImage: "play.circle") { demo = true }
                    if drafts.needsReload { Button("Retry loading drafts", systemImage: "arrow.clockwise") { Task { await drafts.reload() } } }
                    Button("Settings", systemImage: "gearshape") { settings = true }
                    if store.needsReload { Button("Retry loading mail", systemImage: "arrow.clockwise") { store.reload() } }
                } label: { Label("More", systemImage: "ellipsis.circle") }
            }
        }
        if #available(iOS 26, *), !selecting, !allMail(status) {
            ToolbarItem(placement: .topBarTrailing) {
                MailboxFilterToolbar(filter: filters[status], status: status, accounts: store.accounts,
                                     select: { peeking = nil; pull.cancel(); selecting = true },
                                     toggle: { toggleFilter(status) }, options: { filtering = status })
            }
            .sharedBackgroundVisibility(.hidden)
        } else if !allMail(status) {
            ToolbarItem(placement: .topBarTrailing) {
                Button(selecting ? "Cancel" : "Select") {
                    if selecting { endSelection() }
                    else { peeking = nil; pull.cancel(); selecting = true }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if !selecting {
                    MailboxFilterControl(filter: filters[status], status: status, accounts: store.accounts,
                                         toggle: { toggleFilter(status) }, options: { filtering = status })
                }
            }
        }
    }
    private func toggleFilter(_ status: Workflow) {
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) {
            filterBinding(status).wrappedValue.enabled.toggle()
        }
    }
    private var legacyBottomCompose: Bool {
        if #available(iOS 27, *) { return false }
        return true
    }

    private func empty(_ status: Workflow) -> some View {
        let filtered = filters[status].enabled && !allMail(status)
        return ContentUnavailableView(
            filtered ? "No matching mail" : search.isEmpty
                ? (status == .inbox ? "You're all caught up" : "No \(status.rawValue) mail") : "No results",
            systemImage: filtered ? "line.3.horizontal.decrease.circle" : search.isEmpty ? status.symbol : "magnifyingglass",
            description: Text(filtered ? "Change your filters or turn filtering off." : search.isEmpty ? "" : allMail(status) ? "Try another search." : "Try another search in this section.")
        )
    }

    private func mailboxViewport(_ status: Workflow) -> some View {
        // Draw through the keyboard transition, but let the last result scroll above the keyboard.
        GeometryReader { available in
            GeometryReader { viewport in
                let covered = max(0, viewport.frame(in: .global).maxY - available.frame(in: .global).maxY)
                mailbox(status)
                    .contentMargins(.bottom, covered, for: .scrollContent)
            }
            .ignoresSafeArea(.keyboard, edges: .bottom)
        }
    }

    private func mailbox(_ status: Workflow) -> some View {
        let projection = projection(status)
        let items = projection.items
        let pulls = status == .inbox && pullAction != .off && !selecting
        let pullsEmpty = items.isEmpty && pulls && search.isEmpty
        let searchingHere = searching && status == selection
        // One list for every state: swapping in another scroll view while search opens or closes fades the large title.
        // An empty message is a row when it must scroll: below the scope picker, or in a pullable Inbox. Otherwise it
        // is centered in an overlay, because a full-height list row loops the list's layout.
        return List(selection: selecting ? $selectedIDs : nil) {
            if searchingHere {
                scopePicker
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
            if items.isEmpty {
                if pullsEmpty || searchingHere {
                    empty(status)
                        .frame(maxWidth: .infinity)
                        .padding(.top, searchingHere ? 40 : 80)
                        .background { if pullsEmpty { PullScrollObserver(interaction: pull, action: performPull) } }
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
            } else if allMail(status) {
                // Results keep their own mailbox, so each one gets a section that names it.
                ForEach(Workflow.allCases) { mailbox in
                    let found = items.filter { $0.workflow == mailbox }
                    if !found.isEmpty {
                        Section {
                            ForEach(found) { row($0, status: status, order: projection.order) }
                        } header: {
                            Label("\(mailbox.title) · \(found.count)", systemImage: mailbox.symbol).textCase(nil)
                        }
                    }
                }
            } else {
                Section {
                    ForEach(items) { row($0, status: status, order: projection.order) }
                } header: {
                    VStack(alignment: .leading, spacing: 0) {
                        if selecting {
                            Text("\(selectedIDs.count) selected").textCase(nil)
                        } else if status == .inbox {
                            let unreadCount = projection.unread
                            Text(unreadCount > 0 ? "\(unreadCount) unread" : "All read").textCase(nil)
                        } else {
                            Text(items.count == 1 ? "1 item" : "\(items.count) items").textCase(nil)
                        }
                        Color.clear.frame(height: 0)
                    }
                    .background {
                        if pulls {
                            PullScrollObserver(interaction: pull, action: performPull)
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if items.isEmpty && !pullsEmpty && !searchingHere { empty(status).allowsHitTesting(false) }
        }
        .environment(\.editMode, .constant(selecting ? .active : .inactive))
        .modifier(InboxPullModifier(mode: status == .inbox && !selecting ? pullAction : .off, interaction: pull))
    }
    @ViewBuilder private func row(_ item: MailboxItem, status: Workflow, order: [UUID]) -> some View {
        let isThread = item.conversation != nil
        let acceptsRead = isThread && item.workflow != .settled
        let background: Color = item.hasDraft ? .orange.opacity(0.07) : item.unread ? ConversationRow.unreadBackground : .clear
        // One button per ID lets List discover offscreen rows without constructing their gestures and menus.
        Button {
            if !isThread { paths[status, default: []].append(.conversation(item.id)) }
            else if selecting {
                if selectedIDs.contains(item.id) { selectedIDs.remove(item.id) }
                else { selectedIDs.insert(item.id) }
            } else if peeking == nil {
                captureList(status, order: order)
                paths[status, default: []].append(.conversation(item.id))
            }
        } label: {
            switch item {
            case .thread(let conversation, let replies): ConversationRow(query: search, searchSession: searchInput.session, conversation: conversation, hasDraft: !replies.isEmpty)
            case .draft(let draft): DraftRow(draft: draft)
            }
        }
        .buttonStyle(.plain)
        .disabled(selecting && !isThread)
        .selectionDisabled(!isThread)
        .listRowBackground(background)
        .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
        .swipeActions(edge: .trailing, allowsFullSwipe: leftPrimary != .none && (leftPrimary != .read || acceptsRead)) {
            rowActions(item, primary: leftPrimary, secondary: leftSecondary, tertiary: leftTertiary)
        }
        .swipeActions(edge: .leading, allowsFullSwipe: rightPrimary != .none && (rightPrimary != .read || acceptsRead)) {
            rowActions(item, primary: rightPrimary, secondary: rightSecondary, tertiary: rightTertiary)
        }
        .gesture(EmptySwipeGuard(
            left: swipeActions(primary: leftPrimary, secondary: leftSecondary, tertiary: leftTertiary).allSatisfy { $0 == .read && !acceptsRead },
            right: swipeActions(primary: rightPrimary, secondary: rightSecondary, tertiary: rightTertiary).allSatisfy { $0 == .read && !acceptsRead }
        ))
        .simultaneousGesture(LongPressGesture().onEnded { _ in
            guard isThread, !selecting else { return }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            peek(item.id, in: status, order: order)
        }, isEnabled: isThread)
        .accessibilityActions {
            switch item {
            case .thread(let conversation, _):
                Button("Peek") { if !selecting { peek(conversation.id, in: status, order: order) } }
                Button("Move to Trash") { if !selecting { trash(conversation.id, hasDraft: item.hasDraft) } }
            case .draft(let draft):
                Button(draft.pinned == true ? "Unpin" : "Pin") { Task { await drafts.togglePin(draft.id) } }
                Button("Snooze") { snoozingDraft = draft }
                Button("Settle") { settling = DraftDiscard(ids: [draft.id], action: .move(.settled)) }
            }
        }
    }
    @ViewBuilder private func rowActions(_ item: MailboxItem, primary: MailboxSwipeAction, secondary: MailboxSwipeAction, tertiary: MailboxSwipeAction) -> some View {
        switch item {
        case .thread(let conversation, let replies):
            swipeButtons(primary: primary, secondary: secondary, tertiary: tertiary, conversation: conversation, hasDraft: !replies.isEmpty)
        case .draft(let draft):
            draftSwipeButtons(primary: primary, secondary: secondary, tertiary: tertiary, draft: draft)
        }
    }
    private func swipeActions(
        primary: MailboxSwipeAction, secondary: MailboxSwipeAction, tertiary: MailboxSwipeAction
    ) -> [MailboxSwipeAction] {
        var actions: [MailboxSwipeAction] = []
        for action in [primary, secondary, tertiary] where action != .none && !actions.contains(action) {
            actions.append(action)
        }
        return actions
    }

    private func conversationSwipeActions(
        primary: MailboxSwipeAction, secondary: MailboxSwipeAction, tertiary: MailboxSwipeAction, conversation: Conversation
    ) -> [MailboxSwipeAction] {
        swipeActions(primary: primary, secondary: secondary, tertiary: tertiary)
            .filter { $0 != .read || conversation.workflow != .settled }
    }

    @ViewBuilder private func swipeButtons(
        primary: MailboxSwipeAction, secondary: MailboxSwipeAction, tertiary: MailboxSwipeAction,
        conversation: Conversation, hasDraft: Bool
    ) -> some View {
        if !selecting {
            ForEach(conversationSwipeActions(primary: primary, secondary: secondary, tertiary: tertiary, conversation: conversation), id: \.self) { action in
                swipeButton(action, conversation: conversation, hasDraft: hasDraft)
            }
        }
    }

    @ViewBuilder private func swipeButton(_ action: MailboxSwipeAction, conversation: Conversation, hasDraft: Bool) -> some View {
        switch action {
        case .workflow:
            Button(conversation.workflow == .settled ? "Restore" : "Settle",
                   systemImage: conversation.workflow == .settled ? "tray" : "checkmark") {
                if conversation.workflow != .settled && hasDraft { settling = DraftDiscard(ids: [conversation.id], action: .move(.settled)) }
                else { act { store.move(conversation.id, to: conversation.workflow == .settled ? .inbox : .settled) } }
            }.tint(conversation.workflow == .settled ? .blue : .teal)
        case .read:
            if conversation.workflow != .settled {
                Button(conversation.unread ? "Read" : "Unread",
                       systemImage: conversation.unread ? "envelope.open" : "envelope.badge") {
                    act { store.setUnread(conversation.id, !conversation.unread) }
                }.tint(.blue)
            }
        case .snooze:
            Button("Snooze", systemImage: "clock") { snoozing = conversation }.tint(.orange)
        case .pin:
            Button(conversation.pinned ? "Unpin" : "Pin",
                   systemImage: conversation.pinned ? "pin.slash" : "pin") {
                act { store.togglePin(conversation.id) }
            }.tint(.orange)
        case .trash:
            Button("Trash", systemImage: RemovedMailbox.trash.symbol) { trash(conversation.id, hasDraft: hasDraft) }.tint(.red)
        case .none:
            EmptyView()
        }
    }
    private func trash(_ id: UUID, hasDraft: Bool) {
        if hasDraft { settling = DraftDiscard(ids: [id], action: .remove(.trash)) }
        else { act { store.apply(ids: [id], action: .remove(.trash)) } }
    }

    /// What `status` lists now: its own items, or all mail while that search scope is active.
    private func projection(_ status: Workflow) -> MailboxProjections.Entry {
        let scope: Workflow? = allMail(status) ? nil : status
        return store.mailbox(drafts: drafts.drafts, status: scope, query: search,
                                filter: scope.map { filters[$0] } ?? MailboxFilter())
    }
    private var filters: MailboxFilters {
        (try? JSONDecoder().decode(MailboxFilters.self, from: filterData)) ?? MailboxFilters()
    }
    private func filterBinding(_ status: Workflow) -> Binding<MailboxFilter> {
        Binding(get: { filters[status] }, set: { value in
            var updated = filters
            updated[status] = value
            if let data = try? JSONEncoder().encode(updated) { filterData = data }
        })
    }
    @ViewBuilder private func draftSwipeButtons(primary: MailboxSwipeAction, secondary: MailboxSwipeAction, tertiary: MailboxSwipeAction, draft: ComposerDraft) -> some View {
        if !selecting {
            ForEach(draftSwipeActions(primary: primary, secondary: secondary, tertiary: tertiary), id: \.self) { action in
                if action == .pin {
                    Button(draft.pinned == true ? "Unpin" : "Pin", systemImage: draft.pinned == true ? "pin.slash" : "pin") {
                        Task { await drafts.togglePin(draft.id) }
                    }.tint(.orange)
                } else if action == .snooze {
                    Button("Snooze", systemImage: "clock") { snoozingDraft = draft }.tint(.orange)
                } else if action == .trash {
                    Button("Discard", systemImage: RemovedMailbox.trash.symbol) {
                        settling = DraftDiscard(ids: [draft.id], action: .remove(.trash))
                    }.tint(.red)
                } else {
                    Button("Settle", systemImage: "checkmark") { settling = DraftDiscard(ids: [draft.id], action: .move(.settled)) }.tint(.teal)
                }
            }
        }
    }
    private func draftSwipeActions(
        primary: MailboxSwipeAction, secondary: MailboxSwipeAction, tertiary: MailboxSwipeAction
    ) -> [MailboxSwipeAction] {
        swipeActions(primary: primary, secondary: secondary, tertiary: tertiary).filter { $0 != .read }
    }
    private func endSelection() { selecting = false; selectedIDs = [] }
    private func pruneSelection() {
        guard !selectedIDs.isEmpty else { return }
        selectedIDs.formIntersection(projection(selection).selection.eligible)
    }
    private func applySelection(_ action: ConversationAction) {
        let ids = selectedIDs
        let leavesDrafts = switch action {
        case .move(.settled, _), .remove: true
        default: false
        }
        if leavesDrafts, drafts.drafts.contains(where: { $0.mode.replyID.map(ids.contains) ?? false }) {
            settling = DraftDiscard(ids: ids, action: action)
            return
        }
        act { if store.apply(ids: ids, action: action) { endSelection() } }
    }
    private func performPull() {
        guard pullAction != .off && !selecting else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        if pullAction == .search { withTransaction(transaction) { searching = true } }
        if pullAction == .compose { compose(.new) }
    }
    private func captureList(_ status: Workflow, order: [UUID]) {
        let scope: Workflow? = allMail(status) ? nil : status
        readerLists[status, default: [:]][1] = ReaderList(order: order, query: search, scope: scope, filter: filters[status])
    }
    private func openSecondary(_ id: UUID, status: Workflow, order: [UUID], query: String) {
        let depth = paths[status, default: []].count + 1
        readerLists[status, default: [:]][depth] = ReaderList(order: order, query: query, scope: nil, filter: MailboxFilter())
        paths[status, default: []].append(.conversation(id, depth: depth))
    }
    private func readerAvailability(_ status: Workflow, depth: Int, list: ReaderList?) -> Set<UUID> {
        guard let list else { return [] }
        if depth > 1, let path = paths[status], path.count >= depth {
            switch path[depth - 2] {
            case .sender(let sender): return Set(store.conversations(with: sender.address).map(\.id))
            case .removed(let mailbox): return Set(store.list(mailbox, search: list.query).map(\.id))
            default: break
            }
        }
        return store.mailbox(drafts: drafts.drafts, status: list.scope, query: list.query,
                             filter: list.scope == nil ? MailboxFilter() : list.filter).selection.eligible
    }
    private func peek(_ id: UUID, in status: Workflow, order: [UUID]) {
        captureList(status, order: order)
        peeking = id
    }
    private var composeInboxAccount: String? {
        let filter = filters[.inbox]
        guard selection == .inbox, !allMail(.inbox), filter.enabled, let ids = filter.accountIDs else { return nil }
        let included = store.accounts.filter { ids.contains($0.id) }
        return included.count == 1 ? included[0].id : nil
    }
    private func act(_ action: () -> Void) {
        withAnimation { action() }
    }
}

enum MailboxRoute: Hashable {
    case sender(Sender)
    case conversation(UUID, depth: Int = 1)
    case removed(RemovedMailbox)
    case scheduled
    case scheduledMessage(UUID)
}

struct UndoBanner: View {
    @Environment(MailStore.self) private var store
    @Environment(DraftStore.self) private var drafts
    /// Shows only Undo Send. A thread closes after its own moves, so their Undo belongs to the mailbox.
    var sendingOnly = false
    var body: some View {
        if let id = drafts.undoable, drafts.outbox.contains(where: { $0.id == id }) {
            banner("Sending…", symbol: "paperplane.fill", undo: { Task { await drafts.edit(id) } }, dismiss: { drafts.undoable = nil })
        } else if !sendingOnly, let notice = store.notice {
            banner(notice, symbol: "checkmark.circle.fill", undo: { withAnimation { store.undo() } }, dismiss: { store.clearNotice() })
        }
    }
    private func banner(_ text: String, symbol: String, undo: @escaping () -> Void, dismiss: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: symbol).foregroundStyle(.teal)
            Text(text).font(.subheadline)
            Spacer()
            Button("Undo", action: undo).fontWeight(.semibold)
            Button("Dismiss", systemImage: "xmark", action: dismiss).labelStyle(.iconOnly)
        }
        .padding().background(.regularMaterial)
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
    let status: Workflow
    let count: Int
    let hasUnread: Bool
    let allPinned: Bool
    let apply: (ConversationAction) -> Void
    let snooze: () -> Void

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .bottomBar) {
            Button(status == .settled ? "Restore" : "Settle", systemImage: status == .settled ? "tray" : "checkmark") {
                apply(.move(status == .settled ? .inbox : .settled))
            }.disabled(count == 0)
            Spacer()
            Button("Snooze", systemImage: "clock", action: snooze).disabled(count == 0)
            Spacer()
            Button("Move to Trash", systemImage: RemovedMailbox.trash.symbol) { apply(.remove(.trash)) }.disabled(count == 0)
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
                Button("Move to Junk", systemImage: RemovedMailbox.junk.symbol) { apply(.remove(.junk)) }
            } label: { Label("Mark", systemImage: "ellipsis.circle") }
            .disabled(count == 0)
        }
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
