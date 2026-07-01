import SwiftUI
import SeratoToolsCore

struct ContentView: View {
    @EnvironmentObject private var libraryService: LibraryService

    var body: some View {
        NavigationSplitView {
            List(libraryService.tracks) { track in
                Text(track.title)
            }
            .navigationTitle("Library")
        } detail: {
            Text("Select a track")
                .foregroundStyle(.secondary)
        }
        .task {
            try? libraryService.reload()
        }
    }
}
