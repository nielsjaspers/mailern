import SwiftUI
#if DEBUG
import CoreFoundation
#endif

@main
struct MailernApp: App {
    @State private var mailbox = MailboxSession(benchmark: TestStorage.selectedBenchmark)

    #if DEBUG
    init() {
        TestStorage.applyAnimationSetting()
    }
    #endif

    @MainActor private struct MailboxSession: Identifiable {
        let id = UUID()
        let benchmark: BenchmarkMailbox?
        let store: MailStore
        let drafts: DraftStore
        let defaults: UserDefaults
        let snoozePreferences: SnoozePreferences

        init(benchmark: BenchmarkMailbox?) {
            self.benchmark = benchmark
            defaults = TestStorage.preferences(for: benchmark)
            snoozePreferences = SnoozePreferences(defaults: defaults)
            store = MailStore(persistence: SQLitePersistence(url: TestStorage.mailURL(for: benchmark)))
            drafts = makeDrafts(url: TestStorage.directory(for: benchmark).appending(path: "drafts-v1.json"))
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
    }
    private static func makeDrafts(url: URL) -> DraftStore {
        #if DEBUG
        // Pending writes must retain the fault settings of their own fixture session.
        let environment = TestStorage.environment
        #endif
        return DraftStore(url: url, write: { data, url in
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
    private func selectBenchmark(_ benchmark: BenchmarkMailbox?) async throws {
        let previous = mailbox.id
        if let benchmark {
            let url = TestStorage.mailURL(for: benchmark)
            try await Task.detached(priority: .userInitiated) {
                try SQLitePersistence(url: url).seedIfNeeded { benchmark.makeMail() }
            }.value
        }
        try Task.checkCancellation()
        guard mailbox.id == previous else { return }
        let next = MailboxSession(benchmark: benchmark)
        if benchmark != nil, next.store.needsReload {
            throw SQLitePersistence.Failure(message: next.store.error ?? "The large mailbox could not be loaded.")
        }
        TestStorage.selectedBenchmark = benchmark
        mailbox = next
    }

    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            // Capture both stores together. A due-send task can outlive the screen that started it.
            let session = mailbox
            MailboxView(benchmark: session.benchmark, selectBenchmark: selectBenchmark)
                .environment(session.store).environment(session.drafts).environment(session.snoozePreferences).tint(.teal)
                .defaultAppStorage(session.defaults)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        session.store.wakeDue()
                        Task {
                            await session.drafts.wakeDue()
                            await session.drafts.sendDue(through: session.store)
                        }
                    }
                }
                .task {
                    while !Task.isCancelled {
                        session.store.wakeDue()
                        await session.drafts.wakeDue()
                        await session.drafts.sendDue(through: session.store)
                        try? await Task.sleep(for: .seconds(1))
                    }
                }
                #if DEBUG
                .onAppear {
                    TestStorage.observeReset { environment in
                        TestStorage.environment = environment
                        TestStorage.applyAnimationSetting()
                        mailbox = MailboxSession(benchmark: TestStorage.selectedBenchmark)
                    }
                    TestStorage.acknowledge()
                }
                #endif
                .id(session.id)
        }
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
