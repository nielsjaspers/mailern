import SwiftUI
#if DEBUG
import CoreFoundation
#endif

@main
struct MailernApp: App {
    @State private var store = makeStore()
    @State private var drafts = makeDrafts()
    #if DEBUG
    @State private var fixtureSession = TestStorage.session

    init() {
        TestStorage.applyAnimationSetting()
    }
    #endif

    private static func makeStore() -> MailStore {
        let store = MailStore(persistence: TestStorage.mail)
        #if DEBUG
        if TestStorage.isTestSession, TestStorage.environment["MAILERN_TEST_LONG_THREAD"] == "1",
           let id = store.conversations.first(where: { $0.subject == "Dinner on Saturday?" })?.id {
            for _ in 0..<15 { store.receiveReply(id) }
        }
        #endif
        return store
    }
    private static func makeDrafts() -> DraftStore {
        DraftStore(url: TestStorage.draftsURL)
    }
    @State private var snoozePreferences = SnoozePreferences(defaults: TestStorage.defaults)
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            MailboxView().environment(store).environment(drafts).environment(snoozePreferences).tint(.teal)
                .defaultAppStorage(TestStorage.defaults)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { store.wakeDue(); Task { await drafts.wakeDue(); await drafts.sendDue(through: store) } }
                }
                .task {
                    while !Task.isCancelled {
                        store.wakeDue()
                        await drafts.wakeDue()
                        await drafts.sendDue(through: store)
                        try? await Task.sleep(for: .seconds(1))
                    }
                }
                #if DEBUG
                .onAppear {
                    TestStorage.observeReset { environment in
                        TestStorage.environment = environment
                        TestStorage.applyAnimationSetting()
                        store = Self.makeStore()
                        drafts = Self.makeDrafts()
                        snoozePreferences = SnoozePreferences(defaults: TestStorage.defaults)
                        fixtureSession = TestStorage.session
                    }
                    TestStorage.acknowledge()
                }
                .id(fixtureSession)
                #endif
        }
    }
}

// Each UI test uses its own persisted files and preferences, including across relaunches.
private enum TestStorage {
    static var defaults: UserDefaults {
        #if DEBUG
        if let session {
            let defaults = UserDefaults(suiteName: "Mailern.UITests.\(session)")!
            // UI tests check sent messages at once, without waiting for Undo Send.
            defaults.register(defaults: [UndoSend.key: 0])
            return defaults
        }
        #endif
        return .standard
    }
    static var draftsURL: URL { directory.appending(path: "drafts-v1.json") }
    static var mail: SQLitePersistence { SQLitePersistence(url: directory.appending(path: "mail.sqlite")) }
    private static var directory: URL {
        #if DEBUG
        if let session { return URL.applicationSupportDirectory.appending(path: "Mailern/UITests/\(session)") }
        #endif
        return URL.applicationSupportDirectory.appending(path: "Mailern")
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
