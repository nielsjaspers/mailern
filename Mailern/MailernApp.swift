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
    #endif

    private static func makeStore() -> MailStore {
        let store = MailStore(persistence: TestStorage.mail)
        #if DEBUG
        if TestStorage.isTestSession, TestStorage.environment["MAILERN_TEST_LONG_THREAD"] == "1",
           let id = store.conversations.first(where: { $0.subject == "Dinner on Saturday?" })?.id {
            for _ in 0..<11 { store.receiveReply(id) }
        }
        if TestStorage.isTestSession, TestStorage.environment["MAILERN_TEST_LARGE_INBOX"] == "1" {
            for _ in 0..<20 { store.receiveNew() }
        }
        #endif
        return store
    }
    private static func makeDrafts() -> DraftStore {
        #if DEBUG
        // Pending writes must retain the fault settings of their own fixture session.
        let environment = TestStorage.environment
        #endif
        return DraftStore(url: TestStorage.draftsURL, write: { data, url in
            #if DEBUG
            if environment["MAILERN_TEST_DRAFT_WRITE_FAILURE"] == "1" {
                throw CocoaError(.fileWriteOutOfSpace)
            }
            if environment["MAILERN_TEST_DRAFT_DELETE_FAILURE"] == "1",
               let previous = try? AttachmentJSON.decoder(for: url).decode([ComposerDraft].self, from: Data(contentsOf: url)),
               let next = try? AttachmentJSON.decoder(for: url).decode([ComposerDraft].self, from: data), next.count < previous.count {
                throw CocoaError(.fileWriteOutOfSpace)
            }
            if let subject = environment["MAILERN_TEST_DRAFT_REVERT_SUBJECT"],
               let previous = try? AttachmentJSON.decoder(for: url).decode([ComposerDraft].self, from: Data(contentsOf: url)),
               let next = try? AttachmentJSON.decoder(for: url).decode([ComposerDraft].self, from: data),
               next.contains(where: { draft in draft.subject == subject && previous.contains { $0.id == draft.id && $0.subject != subject } }) {
                throw CocoaError(.fileWriteOutOfSpace)
            }
            #endif
            try data.write(to: url, options: .atomic)
        })
    }
    @State private var snoozePreferences = SnoozePreferences(defaults: TestStorage.defaults)
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            MailboxView().environment(store).environment(drafts).environment(snoozePreferences).tint(.teal)
                .defaultAppStorage(TestStorage.defaults)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { store.wakeDue(); Task { await drafts.wakeDue() } }
                }
                .task {
                    #if DEBUG
                    if let subject = TestStorage.environment["MAILERN_TEST_EXPIRING_DRAFT"],
                       !drafts.drafts.contains(where: { $0.subject == subject }) {
                        var draft = ComposerDraft(subject: subject, text: "Expiry proof")
                        draft.snoozedUntil = .now.addingTimeInterval(20)
                        await drafts.save(draft)
                    }
                    #endif
                    while !Task.isCancelled {
                        store.wakeDue()
                        await drafts.wakeDue()
                        try? await Task.sleep(for: .seconds(1))
                    }
                }
                #if DEBUG
                .onAppear {
                    TestStorage.observeReset { environment in
                        TestStorage.environment = environment
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
        if let session { return UserDefaults(suiteName: "Mailern.UITests.\(session)")! }
        #endif
        return .standard
    }
    static var draftsURL: URL { directory.appending(path: "drafts-v1.json") }
    static var mail: SQLitePersistence {
        let persistence = SQLitePersistence(url: directory.appending(path: "mail.sqlite"))
        #if DEBUG
        if session != nil, TestStorage.environment["MAILERN_TEST_RESET_MAIL"] == "1" {
            do { try persistence.save(MailData(conversations: DemoData.conversations())) }
            catch { fatalError("Could not reset UI test mail: \(error)") }
        }
        #endif
        return persistence
    }
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
    static var session: String? {
        guard let value = TestStorage.environment["MAILERN_TEST_SESSION"],
              let id = UUID(uuidString: value) else { return nil }
        return id.uuidString
    }
    #endif
}
