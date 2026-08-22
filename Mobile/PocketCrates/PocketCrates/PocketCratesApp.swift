import SwiftUI

@main
struct PocketCratesApp: App {
    @State private var store = SnapshotStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .task { store.restore() }
        }
    }
}
