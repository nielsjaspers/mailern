import SwiftUI

@main
struct MailernApp: App {
    @State private var store: MailStore = {
        let store = MailStore(persistence: TestStorage.mail)
        #if DEBUG
        if TestStorage.isTestSession, ProcessInfo.processInfo.environment["MAILERN_TEST_LONG_THREAD"] == "1",
           let id = store.conversations.first(where: { $0.subject == "Dinner on Saturday?" })?.id {
            for _ in 0..<11 { store.receiveReply(id) }
        }
        if TestStorage.isTestSession, ProcessInfo.processInfo.environment["MAILERN_TEST_LARGE_INBOX"] == "1" {
            for _ in 0..<20 { store.receiveNew() }
        }
        #endif
        return store
    }()
    @State private var drafts = DraftStore(url: TestStorage.draftsURL, write: { data, url in
        #if DEBUG
        if ProcessInfo.processInfo.environment["MAILERN_TEST_DRAFT_WRITE_FAILURE"] == "1" {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        if ProcessInfo.processInfo.environment["MAILERN_TEST_DRAFT_DELETE_FAILURE"] == "1",
           let previous = try? AttachmentJSON.decoder(for: url).decode([ComposerDraft].self, from: Data(contentsOf: url)),
           let next = try? AttachmentJSON.decoder(for: url).decode([ComposerDraft].self, from: data), next.count < previous.count {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        if let subject = ProcessInfo.processInfo.environment["MAILERN_TEST_DRAFT_REVERT_SUBJECT"],
           let previous = try? AttachmentJSON.decoder(for: url).decode([ComposerDraft].self, from: Data(contentsOf: url)),
           let next = try? AttachmentJSON.decoder(for: url).decode([ComposerDraft].self, from: data),
           next.contains(where: { draft in draft.subject == subject && previous.contains { $0.id == draft.id && $0.subject != subject } }) {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        #endif
        try data.write(to: url, options: .atomic)
    })
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
                    if let subject = ProcessInfo.processInfo.environment["MAILERN_TEST_EXPIRING_DRAFT"],
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
        }
    }
}

// Each UI test uses its own persisted files and preferences, including across relaunches.
private enum TestStorage {
    static let defaults: UserDefaults = {
        #if DEBUG
        if let session { return UserDefaults(suiteName: "Mailern.UITests.\(session)")! }
        #endif
        return .standard
    }()
    static var draftsURL: URL { directory.appending(path: "drafts-v1.json") }
    static var mail: JSONPersistence {
        let persistence = JSONPersistence(url: directory.appending(path: "demo-v1.json"))
        #if DEBUG
        if session != nil, ProcessInfo.processInfo.environment["MAILERN_TEST_RESET_MAIL"] == "1" {
            do { try persistence.save(DemoData.conversations()) }
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
    static var isTestSession: Bool { session != nil }
    private static var session: String? {
        guard let value = ProcessInfo.processInfo.environment["MAILERN_TEST_SESSION"],
              let id = UUID(uuidString: value) else { return nil }
        return id.uuidString
    }
    #endif
}
