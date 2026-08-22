import Foundation
import Observation
import UIKit
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
    private(set) var pendingIntents: [SnapshotIntent] = []

    private var baseSnapshot: LibrarySnapshot?
    private static let intentsFilename = "intents-pending.json"
    private static let deviceIDDefaultsKey = "PocketCrates.deviceID"

    var library: SnapshotLibrary? {
        if case let .loaded(lib) = state { return lib }
        return nil
    }

    var snapshotID: UUID? { baseSnapshot?.snapshotID }
    var hasPendingIntents: Bool { !pendingIntents.isEmpty }

    // MARK: - Device identity

    /// Stable per-install identifier that names this device's queue file, so
    /// the Mac can tell one device's edits from another's and no two devices
    /// ever write the same file.
    private static func deviceID() -> UUID {
        if let stored = UserDefaults.standard.string(forKey: deviceIDDefaultsKey),
           let id = UUID(uuidString: stored) {
            return id
        }
        let id = UUID()
        UserDefaults.standard.set(id.uuidString, forKey: deviceIDDefaultsKey)
        return id
    }

    private static var deviceName: String {
        let name = UIDevice.current.name
        return name.isEmpty ? "iPhone" : name
    }

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

    func addIntent(_ operation: SnapshotIntentOperation) {
        guard let id = snapshotID else { return }
        let intent = SnapshotIntent(baseSnapshotID: id, operation: operation)
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

    /// Sends the pending edits to the Mac by writing them to this device's
    /// queue file in the sync folder. EZLibrary on the Mac reviews and applies
    /// them, then deletes the file.
    ///
    /// Merges with any queue the Mac hasn't consumed yet, so edits made while
    /// offline accumulate rather than overwriting each other. Local pending
    /// intents are cleared once written — they now live in the outbox.
    func sendToMac() throws {
        guard let folderURL, let base = baseSnapshot else { return }

        let deviceID = Self.deviceID()
        let alreadyQueued = existingQueue(for: deviceID, in: folderURL)?.intents ?? []
        let combined = alreadyQueued + pendingIntents
        guard !combined.isEmpty else { return }

        let queue = SnapshotIntentQueue(
            deviceID: deviceID,
            deviceName: Self.deviceName,
            baseSnapshotID: base.snapshotID,
            intents: combined
        )
        let data = try SnapshotIntentQueueCodec.encode(queue)
        let fileURL = folderURL.appendingPathComponent(queue.fileName)

        try SnapshotFolderBookmark.withAccess(to: folderURL) {
            try data.write(to: fileURL, options: .atomic)
        }

        pendingIntents = []
        saveIntents()
        load(from: folderURL)
    }

    private func existingQueue(for deviceID: UUID, in folder: URL) -> SnapshotIntentQueue? {
        let fileURL = folder.appendingPathComponent(
            "\(SnapshotIntentQueue.filePrefix)\(deviceID.uuidString.lowercased()).\(SnapshotIntentQueue.fileExtension)"
        )
        let data: Data? = SnapshotFolderBookmark.withAccess(to: folder) { try? Data(contentsOf: fileURL) }
        guard let data else { return nil }
        return try? SnapshotIntentQueueCodec.decode(data)
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
        pendingIntents = (try? decoder.decode([SnapshotIntent].self, from: data)) ?? []
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
