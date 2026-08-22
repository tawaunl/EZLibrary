import Foundation
import Observation
import EZLibrarySnapshotKit

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
    private(set) var pendingIntents: [PendingIntent] = []

    private var baseSnapshot: LibrarySnapshot?
    private static let intentsFilename = "intents-pending.json"

    var library: SnapshotLibrary? {
        if case let .loaded(lib) = state { return lib }
        return nil
    }

    var snapshotID: UUID? { baseSnapshot?.snapshotID }
    var hasPendingIntents: Bool { !pendingIntents.isEmpty }

    // MARK: - Folder lifecycle

    func restore() {
        guard let url = SnapshotFolderBookmark.resolve() else {
            state = .needsFolder
            return
        }
        folderURL = url
        load(from: url)
    }

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
        guard let folderURL else { state = .needsFolder; return }
        load(from: folderURL)
    }

    func forgetFolder() {
        SnapshotFolderBookmark.forget()
        folderURL = nil
        baseSnapshot = nil
        pendingIntents = []
        state = .needsFolder
    }

    // MARK: - Intents

    func addIntent(_ operation: IntentOperation) {
        guard let id = snapshotID else { return }
        let intent = PendingIntent(id: UUID(), createdAt: Date(), snapshotID: id, operation: operation)
        pendingIntents.append(intent)
        rebuildEffective()
        saveIntents()
    }

    func removeIntent(id: UUID) {
        pendingIntents.removeAll { $0.id == id }
        rebuildEffective()
        saveIntents()
    }

    func clearAllIntents() {
        pendingIntents = []
        rebuildEffective()
        saveIntents()
    }

    /// Writes the effective snapshot (base + all pending intents applied) to the sync
    /// folder as a new JSON file. The Mac picks this up as the newest snapshot the next
    /// time EZLibrary opens. Pending intents are cleared afterwards since they are now
    /// baked into the exported file.
    func exportEffectiveSnapshot() throws {
        guard let folderURL, let base = baseSnapshot else { return }

        let effective = base.applying(pendingIntents)
        // Fresh ID + timestamp so the Mac sees this as a new, authoritative snapshot.
        let exported = LibrarySnapshot(
            libraryFingerprint: effective.libraryFingerprint,
            tracks: effective.tracks,
            crates: effective.crates
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(exported)

        let filename = "snapshot-phone-\(exported.snapshotID.uuidString.lowercased()).json"
        let fileURL = folderURL.appendingPathComponent(filename)

        try SnapshotFolderBookmark.withAccess(to: folderURL) {
            try data.write(to: fileURL, options: .atomic)
        }

        // Intents are now baked into the exported file — clear them and reload.
        pendingIntents = []
        saveIntents()
        load(from: folderURL)
    }

    // MARK: - Private helpers

    private func load(from url: URL) {
        state = .loading
        do {
            let raw = try SnapshotFolderBookmark.withAccess(to: url) {
                try SnapshotFolder.loadNewest(in: url)
            }
            baseSnapshot = raw.snapshot
            loadIntents(from: url)
            rebuildEffective()
        } catch let error as LocalizedError {
            state = .failed([error.errorDescription, error.recoverySuggestion]
                .compactMap { $0 }
                .joined(separator: " "))
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func rebuildEffective() {
        guard let base = baseSnapshot else { return }
        let effective = base.applying(pendingIntents)
        state = .loaded(SnapshotLibrary(snapshot: effective))
    }

    // MARK: - Intent persistence

    private func intentsURL(in folder: URL) -> URL {
        folder.appendingPathComponent(Self.intentsFilename)
    }

    private func loadIntents(from folder: URL) {
        let url = intentsURL(in: folder)
        let data: Data? = SnapshotFolderBookmark.withAccess(to: folder) { try? Data(contentsOf: url) }
        guard let data else { pendingIntents = []; return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        pendingIntents = (try? decoder.decode([PendingIntent].self, from: data)) ?? []
    }

    private func saveIntents() {
        guard let folderURL else { return }
        let url = intentsURL(in: folderURL)
        SnapshotFolderBookmark.withAccess(to: folderURL) {
            if pendingIntents.isEmpty {
                try? FileManager.default.removeItem(at: url)
            } else {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = .prettyPrinted
                if let data = try? encoder.encode(pendingIntents) {
                    try? data.write(to: url, options: .atomic)
                }
            }
        }
    }

#if DEBUG
    func loadPreview() {
        baseSnapshot = SnapshotLibrary.preview.snapshot
        pendingIntents = []
        state = .loaded(.preview)
    }
#endif
}
