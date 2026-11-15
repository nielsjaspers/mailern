import SwiftUI

@main
struct MailernApp: App {
    @State private var store = MailStore()
    @State private var drafts = DraftStore(write: { data, url in
        #if DEBUG
        if ProcessInfo.processInfo.environment["MAILERN_TEST_DRAFT_WRITE_FAILURE"] == "1" {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        #endif
        try data.write(to: url, options: .atomic)
    })
    @State private var snoozePreferences = SnoozePreferences()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            MailboxView().environment(store).environment(drafts).environment(snoozePreferences).tint(.teal)
                .onChange(of: scenePhase) { _, phase in if phase == .active { store.wakeDue() } }
                .task {
                    while !Task.isCancelled {
                        store.wakeDue()
                        try? await Task.sleep(for: .seconds(1))
                    }
                }
        }
    }
}
