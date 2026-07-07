import SwiftUI
import AppKit

struct FinderFolderControls: View {
    let label: String
    @Binding var path: String
    let browsePrompt: String
    let browseStartURL: URL
    let allowsNewFolderCreation: Bool
    let onPathChanged: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                TextField(label, text: $path)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout)
                    .controlSize(.small)

                Button {
                    browseForFolder()
                } label: {
                    Label("Browse…", systemImage: "folder")
                }
                .controlSize(.small)

                if allowsNewFolderCreation {
                    Button {
                        createNewFolder()
                    } label: {
                        Label("New Folder…", systemImage: "folder.badge.plus")
                    }
                    .controlSize(.small)
                }

                Button {
                    openInFinder()
                } label: {
                    Label("Open", systemImage: "arrow.up.right.square")
                }
                .controlSize(.small)
                .disabled(currentFolderURL == nil)

                Button {
                    revealInFinder()
                } label: {
                    Label("Reveal", systemImage: "eye")
                }
                .controlSize(.small)
                .disabled(currentFolderURL == nil)

                Menu {
                    Button("Copy Path") {
                        copyCurrentPath()
                    }
                    .disabled(currentFolderURL == nil)

                    Button("Show Info") {
                        showFolderInfo()
                    }
                    .disabled(currentFolderURL == nil)

                    Divider()

                    if allowsNewFolderCreation {
                        Button("Rename…") {
                            renameCurrentFolder()
                        }
                        .disabled(currentFolderURL == nil)

                        Button("Duplicate…") {
                            duplicateCurrentFolder()
                        }
                        .disabled(currentFolderURL == nil)

                        Divider()

                        Button("New Folder…") {
                            createNewFolder()
                        }
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .controlSize(.small)
                .disabled(currentFolderURL == nil)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.45))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.16), lineWidth: 1)
        )
    }

    private var currentFolderURL: URL? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return browseStartURL
        }

        return URL(fileURLWithPath: trimmed)
    }

    private func browseForFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = browsePrompt
        panel.directoryURL = currentFolderURL

        if panel.runModal() == .OK, let url = panel.url {
            path = url.path
            onPathChanged?()
        }
    }

    private func createNewFolder() {
        guard let parentURL = currentFolderURL else { return }

        let alert = NSAlert()
        alert.messageText = "Create New Folder"
        alert.informativeText = "Create a new folder inside \(parentURL.lastPathComponent)."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")

        let nameField = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        nameField.placeholderString = "Folder name"
        nameField.stringValue = suggestedFolderName(in: parentURL)
        alert.accessoryView = nameField

        if alert.runModal() != .alertFirstButtonReturn {
            return
        }

        let folderName = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !folderName.isEmpty else { return }

        let createdURL = parentURL.appendingPathComponent(folderName, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: createdURL, withIntermediateDirectories: false)
            path = createdURL.path
            onPathChanged?()
            NSWorkspace.shared.activateFileViewerSelecting([createdURL])
        } catch {
            showError(message: "Couldn't create folder: \(error.localizedDescription)")
        }
    }

    private func renameCurrentFolder() {
        guard let folderURL = currentFolderURL else { return }
        guard folderURL.path != "/" else {
            showError(message: "The root folder cannot be renamed.")
            return
        }

        let alert = NSAlert()
        alert.messageText = "Rename Folder"
        alert.informativeText = "Enter a new name for \(folderURL.lastPathComponent)."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let nameField = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        nameField.placeholderString = "Folder name"
        nameField.stringValue = folderURL.lastPathComponent
        alert.accessoryView = nameField

        if alert.runModal() != .alertFirstButtonReturn {
            return
        }

        let newName = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty else { return }

        let destinationURL = folderURL.deletingLastPathComponent().appendingPathComponent(newName, isDirectory: true)
        do {
            try FileManager.default.moveItem(at: folderURL, to: destinationURL)
            path = destinationURL.path
            onPathChanged?()
            NSWorkspace.shared.activateFileViewerSelecting([destinationURL])
        } catch {
            showError(message: "Couldn't rename folder: \(error.localizedDescription)")
        }
    }

    private func duplicateCurrentFolder() {
        guard let folderURL = currentFolderURL else { return }

        let alert = NSAlert()
        alert.messageText = "Duplicate Folder"
        alert.informativeText = "Create a copy of \(folderURL.lastPathComponent) in the same parent folder."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Duplicate")
        alert.addButton(withTitle: "Cancel")

        let nameField = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        nameField.placeholderString = "Copy name"
        nameField.stringValue = suggestedCopyName(for: folderURL)
        alert.accessoryView = nameField

        if alert.runModal() != .alertFirstButtonReturn {
            return
        }

        let copyName = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !copyName.isEmpty else { return }

        let destinationURL = folderURL.deletingLastPathComponent().appendingPathComponent(copyName, isDirectory: true)
        do {
            try FileManager.default.copyItem(at: folderURL, to: destinationURL)
            path = destinationURL.path
            onPathChanged?()
            NSWorkspace.shared.activateFileViewerSelecting([destinationURL])
        } catch {
            showError(message: "Couldn't duplicate folder: \(error.localizedDescription)")
        }
    }

    private func copyCurrentPath() {
        guard let folderURL = currentFolderURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(folderURL.path, forType: .string)
    }

    private func showFolderInfo() {
        guard let folderURL = currentFolderURL else { return }

        let fileManager = FileManager.default
        let exists = fileManager.fileExists(atPath: folderURL.path)
        let isDirectory = (try? folderURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        let existsText = exists ? "Yes" : "No"
        let isDirectoryText = isDirectory ? "Yes" : "No"

        let alert = NSAlert()
        alert.messageText = folderURL.lastPathComponent.isEmpty ? folderURL.path : folderURL.lastPathComponent
        alert.informativeText = [
            "Path: \(folderURL.path)",
            "Exists: \(existsText)",
            "Directory: \(isDirectoryText)"
        ]
        .joined(separator: "\n")
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func openInFinder() {
        guard let folderURL = currentFolderURL else { return }
        NSWorkspace.shared.open(folderURL)
    }

    private func revealInFinder() {
        guard let folderURL = currentFolderURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([folderURL])
    }

    private func suggestedFolderName(in parentURL: URL) -> String {
        let base = "New Folder"
        var candidate = base
        var counter = 2
        while FileManager.default.fileExists(atPath: parentURL.appendingPathComponent(candidate, isDirectory: true).path) {
            candidate = "\(base) \(counter)"
            counter += 1
        }
        return candidate
    }

    private func suggestedCopyName(for folderURL: URL) -> String {
        let base = "\(folderURL.lastPathComponent) copy"
        var candidate = base
        var counter = 2
        while FileManager.default.fileExists(atPath: folderURL.deletingLastPathComponent().appendingPathComponent(candidate, isDirectory: true).path) {
            candidate = "\(base) \(counter)"
            counter += 1
        }
        return candidate
    }

    private func showError(message: String) {
        let alert = NSAlert()
        alert.messageText = "Couldn't Create Folder"
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}