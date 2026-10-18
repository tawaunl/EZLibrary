// EZLibrary — an open source toolkit for Serato DJ libraries.
// Copyright (C) 2026 Tawaun Lucas
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. It is distributed WITHOUT ANY WARRANTY; see the GNU
// General Public License (LICENSE) for more details.

import Foundation

/// Remembers which drives have been used for backups and where on each, so
/// plugging a known drive back in can point the Backup tab at it.
///
/// A drive is identified by its volume UUID, not its mount path: macOS renames
/// a mount to "Drive 1" when two volumes share a name, and the same drive can
/// land at a different path on every connect. The folder is stored relative to
/// the volume root for the same reason.
public struct BackupDeviceMemory {
    public struct Device: Codable, Equatable, Sendable {
        public var volumeUUID: String
        public var name: String
        /// Folder on the volume, relative to its root. Empty means the root.
        public var relativePath: String
        public var lastUsed: Date
    }

    /// A mounted volume, as far as backup memory cares.
    public struct Volume: Equatable, Sendable {
        public let uuid: String
        public let name: String
        public let mountPoint: URL

        public init(uuid: String, name: String, mountPoint: URL) {
            self.uuid = uuid
            self.name = name
            self.mountPoint = mountPoint
        }
    }

    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "LibraryBackupKnownDevices") {
        self.defaults = defaults
        self.key = key
    }

    public var devices: [Device] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([Device].self, from: data) else { return [] }
        return decoded
    }

    public func device(forVolumeUUID uuid: String) -> Device? {
        devices.first { $0.volumeUUID == uuid }
    }

    /// Notes that `destination` (a folder on `volume`) was used for a backup.
    public func record(destination: URL, on volume: Volume, now: Date = Date()) {
        let entry = Device(
            volumeUUID: volume.uuid,
            name: volume.name,
            relativePath: Self.relativePath(of: destination, in: volume.mountPoint),
            lastUsed: now
        )
        var all = devices.filter { $0.volumeUUID != volume.uuid }
        all.append(entry)
        if let data = try? JSONEncoder().encode(all) {
            defaults.set(data, forKey: key)
        }
    }

    /// Where the remembered folder is now that the drive is mounted at
    /// `volume.mountPoint`. Falls back to the drive's root when that folder no
    /// longer exists, so a switch never points at a missing path.
    public func destination(
        for volume: Volume,
        fileManager: FileManager = .default
    ) -> URL? {
        guard let device = device(forVolumeUUID: volume.uuid) else { return nil }
        let remembered = device.relativePath.isEmpty
            ? volume.mountPoint
            : volume.mountPoint.appendingPathComponent(device.relativePath, isDirectory: true)
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: remembered.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return remembered
        }
        return volume.mountPoint
    }

    static func relativePath(of destination: URL, in mountPoint: URL) -> String {
        let root = mountPoint.standardizedFileURL.path
        let path = destination.standardizedFileURL.path
        guard path.hasPrefix(root) else { return "" }
        return String(path.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// The volume `url` lives on. `nil` for the internal disk, which is not a
    /// backup device, and when macOS can't identify the volume.
    public static func externalVolume(containing url: URL) -> Volume? {
        let keys: Set<URLResourceKey> = [
            .volumeUUIDStringKey, .volumeNameKey, .volumeURLKey, .volumeIsInternalKey
        ]
        guard let values = try? url.resourceValues(forKeys: keys),
              values.volumeIsInternal != true,
              let uuid = values.volumeUUIDString,
              let mountPoint = values.volume else { return nil }
        return Volume(uuid: uuid, name: values.volumeName ?? mountPoint.lastPathComponent, mountPoint: mountPoint)
    }
}
