import SwiftUI
import AppKit

/// Compact folder selector that collapses a path field + browse buttons into a
/// single dropdown. Remembers recently used folders (persisted per `recentsKey`)
/// so common destinations can be re-picked without re-browsing.
struct FolderDropdownControl: View {
    let label: String
    @Binding var path: String
    let recentsKey: String
    let browsePrompt: String
    let browseStartURL: URL
    var suggestedPaths: [String] = []
    var onPathChanged: (() -> Void)? = nil

    @State private var recents: [String] = []

    private var trimmedPath: String {
        path.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var currentURL: URL? {
        trimmedPath.isEmpty ? nil : URL(fileURLWithPath: trimmedPath, isDirectory: true)
    }

    private var collapsedLabel: String {
        guard !trimmedPath.isEmpty else { return "Choose folder…" }
        return URL(fileURLWithPath: trimmedPath).lastPathComponent
    }

    private var options: [String] {
        let fileManager = FileManager.default
        var seen = Set<String>()
        var result: [String] = []
        for candidate in ([trimmedPath] + suggestedPaths + recents) {
            let value = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, seen.insert(value).inserted else { continue }
            // Always keep the current selection; drop stale/missing others.
            if value == trimmedPath || fileManager.fileExists(atPath: value) {
                result.append(value)
            }
        }
        return result
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Menu {
                ForEach(options, id: \.self) { option in
                    Button {
                        select(option)
                    } label: {
                        if option == trimmedPath {
                            Label(abbreviated(option), systemImage: "checkmark")
                        } else {
                            Text(abbreviated(option))
                        }
                    }
                }

                Divider()

                Button {
                    browse()
                } label: {
                    Label("Browse…", systemImage: "folder")
                }

                if let url = currentURL {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } label: {
                        Label("Reveal in Finder", systemImage: "eye")
                    }

                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url.path, forType: .string)
                    } label: {
                        Label("Copy Path", systemImage: "doc.on.doc")
                    }
                }
            } label: {
                Label(collapsedLabel, systemImage: "folder")
            }
            .menuStyle(.button)
            .controlSize(.small)
            .fixedSize()
            .help(trimmedPath.isEmpty ? "Choose \(label.lowercased())" : trimmedPath)
        }
        .onAppear { recents = loadRecents() }
    }

    private func abbreviated(_ value: String) -> String {
        (value as NSString).abbreviatingWithTildeInPath
    }

    private func select(_ value: String) {
        guard value != trimmedPath else { return }
        path = value
        addRecent(value)
        onPathChanged?()
    }

    private func browse() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = browsePrompt
        panel.directoryURL = currentURL ?? browseStartURL

        if panel.runModal() == .OK, let url = panel.url {
            path = url.path
            addRecent(url.path)
            onPathChanged?()
        }
    }

    private func loadRecents() -> [String] {
        UserDefaults.standard.stringArray(forKey: recentsKey) ?? []
    }

    private func addRecent(_ value: String) {
        var list = loadRecents().filter { $0 != value }
        list.insert(value, at: 0)
        list = Array(list.prefix(8))
        UserDefaults.standard.set(list, forKey: recentsKey)
        recents = list
    }
}
