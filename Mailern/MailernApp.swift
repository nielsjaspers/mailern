import SwiftUI
#if DEBUG
import CoreFoundation
#endif

@main
struct MailernApp: App {
    @UIApplicationDelegateAdaptor(MailNotifications.self) private var notifications
    @State private var mailboxes = MailboxSessions()

    #if DEBUG
    init() {
        TestStorage.applyAnimationSetting()
    }
    #endif

    @MainActor fileprivate struct MailboxSession: Identifiable {
        let id = UUID()
        let benchmark: BenchmarkMailbox?
        let store: MailStore
        let drafts: DraftStore
        let defaults: UserDefaults
        let snoozePreferences: SnoozePreferences
        /// Set for mail from mailern-server. Its mail, drafts, and preferences are separate from the demo's.
        let sync: ServerSync?

        init(benchmark: BenchmarkMailbox?) {
            self.benchmark = benchmark
            sync = nil
            defaults = TestStorage.preferences(for: benchmark)
            snoozePreferences = SnoozePreferences(defaults: defaults)
            store = MailStore(persistence: SQLitePersistence(url: TestStorage.mailURL(for: benchmark), requiresSeed: benchmark != nil))
            drafts = makeDrafts(mail: store, url: TestStorage.directory(for: benchmark).appending(path: "drafts-v1.json"))
            #if DEBUG
            if benchmark == nil, TestStorage.isTestSession {
                if TestStorage.environment["MAILERN_TEST_LONG_THREAD"] == "1",
                   let id = store.conversations.first(where: { $0.subject == "Dinner on Saturday?" })?.id {
                    for _ in 0..<15 { store.receiveReply(id) }
                }
                if TestStorage.environment["MAILERN_TEST_LARGE_INBOX"] == "1" {
                    for _ in 0..<20 { store.receiveNew() }
                }
            }
            #endif
        }

        init(server url: URL) throws {
            benchmark = nil
            let directory = TestStorage.directory(forServer: url)
            // A server mailbox starts empty. Its first sync brings the accounts and mail.
            try SQLitePersistence(url: directory.appending(path: "mail.sqlite"))
                .seedIfNeeded { MailData(conversations: [], accounts: []) }
            defaults = TestStorage.preferences(forServer: url)
            snoozePreferences = SnoozePreferences(defaults: defaults)
            store = MailStore(persistence: SQLitePersistence(url: directory.appending(path: "mail.sqlite"), requiresSeed: true),
                              isServerMailbox: true)
            drafts = makeDrafts(mail: store, url: directory.appending(path: "drafts-v1.json"))
            sync = ServerSync(url: url, store: store)
        }
    }
    private static func makeDrafts(mail: MailStore, url: URL) -> DraftStore {
        #if DEBUG
        // Pending writes must retain the fault settings of their own fixture session.
        let environment = TestStorage.environment
        #endif
        return DraftStore(url: url, mail: mail, write: { data, url in
            #if DEBUG
            if environment["MAILERN_TEST_DRAFT_WRITE_FAILURE"] == "1" {
                throw CocoaError(.fileWriteOutOfSpace)
            }
            if environment["MAILERN_TEST_DRAFT_DELETE_FAILURE"] == "1",
               let previous = try? AttachmentJSON.decoder(for: url).decode([ComposerDraft].self, from: Data(contentsOf: url)),
               let next = try? AttachmentJSON.decoder(for: url).decode([ComposerDraft].self, from: data), next.count < previous.count {
                throw CocoaError(.fileWriteOutOfSpace)
            }
            #endif
            try data.write(to: url, options: .atomic)
        })
    }
    @MainActor @Observable fileprivate final class MailboxSessions {
        let id = UUID()
        private let demo = MailboxSession(benchmark: nil)
        private var fixture = TestStorage.selectedBenchmark.map { MailboxSession(benchmark: $0) }
        private var server = TestStorage.selectedServer.flatMap { try? MailboxSession(server: $0) }
        @ObservationIgnored private var dueWork: Task<Void, Never>?
        @ObservationIgnored private var selecting = false
        @ObservationIgnored private var switching = false
        var active: MailboxSession { server ?? fixture ?? demo }
        var serverURL: URL? { server == nil ? nil : TestStorage.selectedServer }
        private var sessions: [MailboxSession] { [demo] + (fixture.map { [$0] } ?? []) + (server.map { [$0] } ?? []) }

        var reminderBoxes: [ReminderMailbox] {
            sessions.map {
                ReminderMailbox(scope: $0.sync != nil ? "server" : $0.benchmark.map { String($0.id) } ?? "demo", mail: $0.store, drafts: $0.drafts)
            }
        }

        /// Shows mail from the server at `url`, or the demo mail again when it is nil. A new server must answer first.
        func connect(_ url: URL?) async throws {
            guard !selecting else { return }
            selecting = true
            defer { selecting = false }
            if let url {
                guard url.scheme == "https" || url.host() == "127.0.0.1" || url.host() == "localhost" else {
                    throw MailServerClient.Failure(status: 0, message: "Use an https address, such as the one mailern-server prints when it starts.")
                }
                _ = try await MailServerClient(base: url).sync(since: 0, wait: 0)
            }
            switching = true
            defer { switching = false }
            await dueWork?.value
            await server?.drafts.finishPendingWrites()
            let next = try url.map { try MailboxSession(server: $0) }
            if let store = next?.store, store.needsReload {
                throw SQLitePersistence.Failure(message: store.error ?? "The mail server's mailbox could not be loaded.")
            }
            TestStorage.selectedServer = url
            server = next
        }

        func select(_ benchmark: BenchmarkMailbox?) async throws {
            guard !selecting, benchmark != active.benchmark else { return }
            selecting = true
            defer { selecting = false }
            if let benchmark {
                let url = TestStorage.mailURL(for: benchmark)
                try await Task.detached(priority: .userInitiated) {
                    try SQLitePersistence(url: url).seedIfNeeded { benchmark.makeMail() }
                }.value
            }
            // Stop the timer from starting another operation on the outgoing fixture while it drains.
            switching = true
            defer { switching = false }
            await dueWork?.value
            await fixture?.drafts.finishPendingWrites()
            try Task.checkCancellation()
            let next = benchmark.map { MailboxSession(benchmark: $0) }
            if let store = next?.store, store.needsReload {
                throw SQLitePersistence.Failure(message: store.error ?? "The large mailbox could not be loaded.")
            }
            TestStorage.selectedBenchmark = benchmark
            fixture = next
        }

        func processDue() async {
            guard !switching, dueWork == nil else { return }
            let sessions = self.sessions
            let work = Task {
                let active: @MainActor () -> Bool = { UIApplication.shared.applicationState == .active }
                for session in sessions {
                    await session.drafts.recoverAfterMailLoad()
                    guard active() else { return }
                    session.store.wakeDue()
                    await session.drafts.wakeDue(whileActive: active)
                    await session.drafts.sendDue(through: session.store, whileActive: active)
                }
            }
            dueWork = work
            await work.value
            dueWork = nil
        }
    }

    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            let sessions = mailboxes
            let session = sessions.active
            MailboxView(benchmark: session.benchmark, selectBenchmark: { benchmark in
                try await sessions.select(benchmark)
                refreshReminders(sessions)
                await notifications.finishPendingChanges()
            })
                .environment(session.store).environment(session.drafts).environment(session.snoozePreferences).tint(.teal)
                .environment(\.mailServer, MailServerConnection(url: sessions.serverURL, sync: session.sync) { url in
                    try await sessions.connect(url)
                    refreshReminders(sessions)
                })
                .task(id: scenePhase == .active ? session.id : nil) {
                    guard scenePhase == .active else { return }
                    await session.sync?.run()
                }
                .onChange(of: session.store.mailboxRevision) { _, _ in
                    guard let sync = session.sync else { return }
                    Task { await sync.push() }
                }
                .defaultAppStorage(session.defaults)
                .id(session.id)
                .onChange(of: sessions.reminderBoxes.map {
                    ReminderRevision(session: sessions.id, scope: $0.scope, mail: $0.mail.mailboxRevision,
                                     drafts: $0.drafts.reminderRevision, mailReady: !$0.mail.needsReload,
                                     draftsReady: $0.drafts.hasReadableManifest)
                }, initial: true) { _, _ in refreshReminders(sessions) }
                .onReceive(NotificationCenter.default.publisher(for: Notification.Name("MailernReminderAuthorizationChanged"))) { _ in
                    refreshReminders(sessions, checkPermission: true)
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { refreshReminders(sessions, checkPermission: true) }
                    else { notifications.protectPendingChanges() }
                }
                .task(id: scenePhase == .active ? sessions.id : nil) {
                    guard scenePhase == .active else { return }
                    while !Task.isCancelled {
                        await sessions.processDue()
                        try? await Task.sleep(for: .seconds(1))
                    }
                }
                #if DEBUG
                .onAppear {
                    TestStorage.observeReset { environment in
                        TestStorage.environment = environment
                        TestStorage.applyAnimationSetting()
                        mailboxes = MailboxSessions()
                    }
                }
                .onChange(of: sessions.id, initial: true) { _, _ in TestStorage.acknowledge() }
                #endif
        }
    }
    private struct ReminderRevision: Equatable {
        let session: UUID
        let scope: String
        let mail: UInt64
        let drafts: UInt64
        let mailReady: Bool
        let draftsReady: Bool
    }

    private func refreshReminders(_ sessions: MailboxSessions, checkPermission: Bool = false) {
        notifications.refresh(namespace: TestStorage.reminderNamespace, mailboxes: sessions.reminderBoxes, checkPermission: checkPermission)
    }
}

// Each UI test uses its own persisted files and preferences, including across relaunches.
private enum TestStorage {
    private static let benchmarkKey = "demoBenchmarkMailbox"

    private static var suite: String? {
        #if DEBUG
        if let session { return "Mailern.UITests.\(session)" }
        #endif
        return nil
    }
    // iOS shares one queue for every fixture of this test app. A reset replaces its old requests.
    static var reminderNamespace: String {
        #if DEBUG
        if isTestSession { return "mailern/Mailern.UITests." }
        #endif
        return "mailern/local/"
    }
    private static var defaultPreferences: UserDefaults {
        suite.map { UserDefaults(suiteName: $0)! } ?? .standard
    }
    static func preferences(for benchmark: BenchmarkMailbox?) -> UserDefaults {
        let defaults = benchmark.map { UserDefaults(suiteName: "\(suite ?? "Mailern").Benchmark.\($0.id)")! } ?? defaultPreferences
        #if DEBUG
        if isTestSession {
            // Most cases check sent messages at once. The Undo Send case sets its own delay.
            defaults.register(defaults: [UndoSend.key: Int(environment["MAILERN_TEST_UNDO_SEND"] ?? "") ?? 0])
        }
        #endif
        return defaults
    }
    static var selectedBenchmark: BenchmarkMailbox? {
        get {
            guard let benchmark = BenchmarkMailbox(rawValue: defaultPreferences.integer(forKey: benchmarkKey)),
                  FileManager.default.fileExists(atPath: mailURL(for: benchmark).path) else { return nil }
            return benchmark
        }
        set { defaultPreferences.set(newValue?.id, forKey: benchmarkKey) }
    }
    private static let serverKey = "mailServerURL"
    static var selectedServer: URL? {
        get { defaultPreferences.string(forKey: serverKey).flatMap(URL.init(string:)) }
        set { defaultPreferences.set(newValue?.absoluteString, forKey: serverKey) }
    }
    /// Each server gets its own folder and preferences, so switching servers never mixes their mail.
    private static func serverName(_ url: URL) -> String {
        "\(url.host() ?? "server")-\(url.port ?? 443)".map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." ? $0 : "_" }.reduce("") { $0 + String($1) }
    }
    static func directory(forServer url: URL) -> URL {
        directory(for: nil).appending(path: "Server/\(serverName(url))")
    }
    static func preferences(forServer url: URL) -> UserDefaults {
        UserDefaults(suiteName: "\(suite ?? "Mailern").Server.\(serverName(url))")!
    }
    static func mailURL(for benchmark: BenchmarkMailbox?) -> URL {
        directory(for: benchmark).appending(path: "mail.sqlite")
    }
    static func directory(for benchmark: BenchmarkMailbox?) -> URL {
        var directory = URL.applicationSupportDirectory.appending(path: "Mailern")
        #if DEBUG
        if let session { directory = directory.appending(path: "UITests/\(session)") }
        #endif
        if let benchmark { directory = directory.appending(path: "Benchmark/\(benchmark.id)") }
        return directory
    }
    #if DEBUG
    static var environment = ProcessInfo.processInfo.environment
    private static let observer = NSObject()
    private static let process = "\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)"
    private static var reset: (([String: String]) -> Void)?
    private static var control: (path: String, name: String)? {
        let initial = ProcessInfo.processInfo.environment
        guard isTestSession, let path = initial["MAILERN_TEST_CONTROL_FILE"],
              let name = initial["MAILERN_TEST_CONTROL_NAME"] else { return nil }
        return (path, name)
    }

    static func observeReset(_ action: @escaping ([String: String]) -> Void) {
        guard let control, reset == nil else { return }
        reset = action
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(observer).toOpaque(), { _, _, _, _, _ in
                DispatchQueue.main.async { TestStorage.receiveReset() }
            }, control.name as CFString, nil, .deliverImmediately)
    }

    private static func receiveReset() {
        guard let control, let data = try? Data(contentsOf: URL(fileURLWithPath: control.path)),
              let request = try? JSONDecoder().decode([String: String].self, from: data),
              let session = request["MAILERN_TEST_SESSION"], UUID(uuidString: session) != nil,
              session != self.session, request["MAILERN_TEST_REQUEST_ID"] != nil else { return }
        reset?(request)
    }

    static func acknowledge() {
        guard let control, let request = environment["MAILERN_TEST_REQUEST_ID"], let session else { return }
        let reply = ["request": request, "session": session, "process": process]
        do {
            try JSONEncoder().encode(reply).write(to: URL(fileURLWithPath: control.path + ".ack"), options: .atomic)
            CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                CFNotificationName(rawValue: (control.name + ".ack") as CFString), nil, nil, true)
        } catch { fatalError("Could not acknowledge UI fixture reset: \(error)") }
    }

    static var isTestSession: Bool { session != nil }

    /// XCTest waits for the app to settle after every action, which roughly halves UI test
    /// time when transitions are instant. Timers keep their real durations.
    static func applyAnimationSetting() {
        UIView.setAnimationsEnabled(!(isTestSession && environment["MAILERN_TEST_ANIMATIONS"] == "off"))
    }
    static var session: String? {
        guard let value = TestStorage.environment["MAILERN_TEST_SESSION"],
              let id = UUID(uuidString: value) else { return nil }
        return id.uuidString
    }
    #endif
}
