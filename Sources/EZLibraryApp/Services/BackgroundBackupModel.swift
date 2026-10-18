// EZLibrary — an open source toolkit for Serato DJ libraries.
// Copyright (C) 2026 Tawaun Lucas
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. It is distributed WITHOUT ANY WARRANTY; see the GNU
// General Public License (LICENSE) for more details.

import AppKit
import SwiftUI
import EZLibraryCore

/// Owns an in-flight library backup at a level above the Backup view.
///
/// The backup used to be a `Task` inside `LibraryBackupView` writing to that
/// view's `@State`. Switching sections tears the view down, so on return the
/// screen showed an idle form — no sign the copy was still going, no result
/// when it finished, and nothing stopping a second backup being started on top
/// of it. Holding the state here keeps the job and its outcome alive across
/// navigation.
@MainActor
final class BackgroundBackupModel: ObservableObject {
    /// Everything the backup needs, snapshotted at start so it doesn't depend
    /// on view state that may be gone by the time it finishes.
    struct Request: Sendable {
        var destinationFolderURL: URL
        var mode: LibraryBackupService.BackupMode
        var tracks: [Track]
        var crates: [Crate]
        var selectedCrateID: UUID?
        var libraryDirectory: URL
        var rootDirectory: URL
    }

    /// The key the Backup view's destination field is stored under. The model
    /// writes it directly when a known drive appears, and the view's
    /// `@AppStorage` picks the change up, so switching works even while the
    /// Backup tab isn't open.
    static let destinationDefaultsKey = "LibraryBackupDestinationPath"

    @Published private(set) var isRunning = false
    /// Set when plugging in a known drive moved the destination; shown in the
    /// Backup view until the user dismisses it or starts a backup.
    @Published private(set) var deviceNotice: String?
    /// Drives used for backups before, most recently used first.
    @Published private(set) var knownDevices: [BackupDeviceMemory.Device] = []
    /// Volume UUIDs of the known drives that are plugged in right now.
    @Published private(set) var connectedDeviceUUIDs: Set<String> = []
    @Published private(set) var successMessage: String?
    @Published private(set) var errorMessage: String?

    private let deviceMemory = BackupDeviceMemory()

    /// The model lives for the whole app session, so the observer is never
    /// removed; it holds `self` weakly.
    init() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didMountNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let mounted = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
            MainActor.assumeIsolated {
                self?.driveMounted(at: mounted)
                self?.refreshKnownDevices()
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didUnmountNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshKnownDevices() }
        }
        adoptMountedDeviceIfDestinationMissing()
        refreshKnownDevices()
    }

    /// Starts a backup. Ignored while one is already running.
    func start(_ request: Request) {
        guard !isRunning else { return }
        isRunning = true
        successMessage = nil
        errorMessage = nil
        deviceNotice = nil

        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try LibraryBackupService.backup(
                        destinationFolderURL: request.destinationFolderURL,
                        mode: request.mode,
                        tracks: request.tracks,
                        crates: request.crates,
                        selectedCrateID: request.selectedCrateID,
                        libraryDirectory: request.libraryDirectory,
                        rootDirectory: request.rootDirectory
                    )
                }.value
                let note = result.note.map { " \($0)" } ?? ""
                if let volume = BackupDeviceMemory.externalVolume(containing: request.destinationFolderURL) {
                    deviceMemory.record(destination: request.destinationFolderURL, on: volume)
                    refreshKnownDevices()
                }
                successMessage = "Backup created at \(result.backupRootURL.path).\(note)"
            } catch {
                errorMessage = error.localizedDescription
            }
            isRunning = false
        }
    }

    /// Stops remembering a drive; it will no longer be switched to on connect.
    func forget(_ device: BackupDeviceMemory.Device) {
        deviceMemory.forget(volumeUUID: device.volumeUUID)
        refreshKnownDevices()
    }

    /// Points the destination at a known drive that is plugged in.
    func use(_ device: BackupDeviceMemory.Device) {
        guard !isRunning, let volume = mountedVolumes().first(where: { $0.uuid == device.volumeUUID }),
              let destination = deviceMemory.destination(for: volume) else { return }
        UserDefaults.standard.set(destination.path, forKey: Self.destinationDefaultsKey)
        deviceNotice = nil
    }

    private func mountedVolumes() -> [BackupDeviceMemory.Volume] {
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]
        ) ?? []
        return urls.compactMap { BackupDeviceMemory.externalVolume(containing: $0) }
    }

    private func refreshKnownDevices() {
        knownDevices = deviceMemory.devices.sorted { $0.lastUsed > $1.lastUsed }
        let known = Set(knownDevices.map(\.volumeUUID))
        connectedDeviceUUIDs = Set(mountedVolumes().map(\.uuid)).intersection(known)
    }

    func dismissDeviceNotice() { deviceNotice = nil }

    /// A drive was plugged in. If it has been used for backups before, point
    /// the destination at it; otherwise leave the last-used destination alone.
    /// Never moves the destination under a running backup.
    private func driveMounted(at mountURL: URL?) {
        guard !isRunning, let mountURL,
              let volume = BackupDeviceMemory.externalVolume(containing: mountURL),
              let destination = deviceMemory.destination(for: volume) else { return }
        guard UserDefaults.standard.string(forKey: Self.destinationDefaultsKey) != destination.path else { return }
        UserDefaults.standard.set(destination.path, forKey: Self.destinationDefaultsKey)
        deviceNotice = "Switched the backup destination to \(volume.name), which you've backed up to before."
    }

    /// At launch the last-used drive may be unplugged while another known drive
    /// is connected. Only acts when the saved destination is unreachable, so a
    /// working choice is never overridden.
    private func adoptMountedDeviceIfDestinationMissing() {
        let saved = UserDefaults.standard.string(forKey: Self.destinationDefaultsKey) ?? ""
        guard !saved.isEmpty, !FileManager.default.fileExists(atPath: saved) else { return }
        let candidates = mountedVolumes().compactMap { volume -> (BackupDeviceMemory.Volume, Date)? in
            guard let device = deviceMemory.device(forVolumeUUID: volume.uuid) else { return nil }
            return (volume, device.lastUsed)
        }
        guard let best = candidates.max(by: { $0.1 < $1.1 })?.0,
              let destination = deviceMemory.destination(for: best) else { return }
        UserDefaults.standard.set(destination.path, forKey: Self.destinationDefaultsKey)
        deviceNotice = "Switched the backup destination to \(best.name), which you've backed up to before."
    }

    /// Dismisses the last result, e.g. when the user reconfigures the backup.
    /// Does nothing mid-run so a result can't be wiped before it arrives.
    func clearResult() {
        guard !isRunning else { return }
        successMessage = nil
        errorMessage = nil
    }
}
