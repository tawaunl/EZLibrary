import Foundation
import Observation
import EZLibrarySnapshotKit

/// Owns the loaded library and the folder it came from.
///
/// Parsing, searching, and tree-building all live in `EZLibrarySnapshotKit`,
/// where they are unit-tested and compiled for iOS by CI. This is only the
/// state machine around them.
@Observable
final class SnapshotStore {
    enum State {
        case needsFolder
        case loading
        case loaded(SnapshotLibrary)
        case failed(String)
    }

    private(set) var state: State = .needsFolder
    private(set) var folderURL: URL?

    var library: SnapshotLibrary? {
        if case let .loaded(library) = state { return library }
        return nil
    }

    /// Loads from the previously chosen folder, if there is one.
    func restore() {
        guard let url = SnapshotFolderBookmark.resolve() else {
            state = .needsFolder
            return
        }
        folderURL = url
        load(from: url)
    }

    /// Adopts a folder the user just picked.
    func use(folder url: URL) {
        do {
            try SnapshotFolderBookmark.save(url)
        } catch {
            state = .failed("Couldn't keep access to that folder: \(error.localizedDescription)")
            return
        }
        folderURL = url
        load(from: url)
    }

    func reload() {
        guard let folderURL else {
            state = .needsFolder
            return
        }
        load(from: folderURL)
    }

    func forgetFolder() {
        SnapshotFolderBookmark.forget()
        folderURL = nil
        state = .needsFolder
    }

#if DEBUG
    func loadPreview() {
        state = .loaded(.preview)
    }
#endif

    private func load(from url: URL) {
        state = .loading
        do {
            let library = try SnapshotFolderBookmark.withAccess(to: url) {
                try SnapshotFolder.loadNewest(in: url)
            }
            state = .loaded(library)
        } catch let error as LocalizedError {
            state = .failed([error.errorDescription, error.recoverySuggestion]
                .compactMap { $0 }
                .joined(separator: " "))
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}
