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

/// On-disk store of extracted fingerprints, so a rescan only pays for files
/// that actually changed.
///
/// Extraction is by far the expensive stage (~56 files/s), so without this a
/// 50k library would re-spend ~15 minutes on every scan. Entries are keyed by
/// path and validated against size + modification date, so editing tags or
/// replacing a file transparently invalidates its fingerprint.
///
/// A value type by design: the scan pipeline hands it across `await`
/// boundaries, and value semantics sidestep shared mutable state entirely.
public struct AudioFingerprintCache: Sendable {
    public struct Entry: Sendable, Hashable {
        public let fileSize: UInt64
        public let modifiedAt: Double
        public let analysisSeconds: Int
        public let fingerprint: AudioFingerprint
    }

    private var entries: [String: Entry]

    public init() {
        entries = [:]
    }

    public var count: Int { entries.count }

    // MARK: - Lookup

    /// The cached fingerprint for `url`, or nil when absent or stale.
    public func fingerprint(for url: URL, analysisSeconds: Int) -> AudioFingerprint? {
        guard let entry = entries[url.path],
              entry.analysisSeconds == analysisSeconds,
              let stamp = Self.fileStamp(for: url),
              entry.fileSize == stamp.size,
              // Modification dates round-trip through a Double, so compare with
              // a tolerance rather than exactly.
              abs(entry.modifiedAt - stamp.modifiedAt) < 0.001
        else {
            return nil
        }
        return entry.fingerprint
    }

    /// Splits `urls` into those already cached and those needing extraction.
    public func partition(
        _ urls: [URL],
        analysisSeconds: Int
    ) -> (cached: [URL: AudioFingerprint], missing: [URL]) {
        var cached: [URL: AudioFingerprint] = [:]
        var missing: [URL] = []
        for url in urls {
            if let fingerprint = fingerprint(for: url, analysisSeconds: analysisSeconds) {
                cached[url] = fingerprint
            } else {
                missing.append(url)
            }
        }
        return (cached, missing)
    }

    // MARK: - Mutation

    public mutating func store(_ fingerprint: AudioFingerprint, for url: URL, analysisSeconds: Int) {
        guard let stamp = Self.fileStamp(for: url) else { return }
        entries[url.path] = Entry(
            fileSize: stamp.size,
            modifiedAt: stamp.modifiedAt,
            analysisSeconds: analysisSeconds,
            fingerprint: fingerprint
        )
    }

    public mutating func store(_ fingerprints: [URL: AudioFingerprint], analysisSeconds: Int) {
        for (url, fingerprint) in fingerprints {
            store(fingerprint, for: url, analysisSeconds: analysisSeconds)
        }
    }

    /// Drops entries for files outside `keeping`, so the cache can't grow
    /// without bound as a library churns.
    public mutating func prune(keeping paths: Set<String>) {
        entries = entries.filter { paths.contains($0.key) }
    }

    // MARK: - Persistence

    public static let defaultFileName = "fingerprints.cache"

    /// `~/Library/Application Support/EZLibrary/fingerprints.cache`
    public static func defaultURL(fileManager: FileManager = .default) -> URL? {
        guard let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return support
            .appendingPathComponent("EZLibrary", isDirectory: true)
            .appendingPathComponent(defaultFileName)
    }

    private static let magic: [UInt8] = Array("EZFP".utf8)
    private static let formatVersion: UInt32 = 1

    /// Loads a cache, returning an empty one when the file is absent,
    /// truncated, or written by a different format version.
    ///
    /// A cache is disposable — a bad read costs a rescan, never an error the
    /// user has to deal with.
    public static func load(from url: URL? = defaultURL()) -> AudioFingerprintCache {
        guard let url, let data = try? Data(contentsOf: url) else {
            return AudioFingerprintCache()
        }
        return decode(data) ?? AudioFingerprintCache()
    }

    public func save(to url: URL? = defaultURL()) throws {
        guard let url else { return }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encode().write(to: url, options: .atomic)
    }

    // MARK: - Binary coding

    /// Layout: magic, version, count, then per record — path, size, mtime,
    /// analysis length, duration, hash count, hashes.
    ///
    /// A compact binary form rather than JSON because a fingerprint is ~948
    /// integers; encoding 50k of those as text would be both far larger on
    /// disk and much slower to parse than the scan it is meant to avoid.
    func encode() -> Data {
        var data = Data()
        data.reserveCapacity(entries.count * 4_096)
        data.append(contentsOf: Self.magic)
        data.appendLittleEndian(Self.formatVersion)
        data.appendLittleEndian(UInt32(entries.count))

        for (path, entry) in entries {
            let pathBytes = Array(path.utf8)
            data.appendLittleEndian(UInt32(pathBytes.count))
            data.append(contentsOf: pathBytes)
            data.appendLittleEndian(entry.fileSize)
            data.appendLittleEndian(entry.modifiedAt.bitPattern)
            data.appendLittleEndian(Int32(entry.analysisSeconds))
            data.appendLittleEndian(Int32(entry.fingerprint.duration))
            data.appendLittleEndian(UInt32(entry.fingerprint.hashes.count))
            entry.fingerprint.hashes.withUnsafeBytes { data.append(contentsOf: $0) }
        }

        return data
    }

    static func decode(_ data: Data) -> AudioFingerprintCache? {
        var reader = ByteReader(bytes: [UInt8](data))

        guard let magic = reader.readBytes(magic.count), magic == Self.magic,
              let version = reader.read(UInt32.self), version == formatVersion,
              let count = reader.read(UInt32.self)
        else {
            return nil
        }

        var cache = AudioFingerprintCache()
        cache.entries.reserveCapacity(Int(count))

        for _ in 0..<count {
            guard let pathLength = reader.read(UInt32.self),
                  let pathBytes = reader.readBytes(Int(pathLength)),
                  let path = String(bytes: pathBytes, encoding: .utf8),
                  let fileSize = reader.read(UInt64.self),
                  let modifiedBits = reader.read(UInt64.self),
                  let analysisSeconds = reader.read(Int32.self),
                  let duration = reader.read(Int32.self),
                  let hashCount = reader.read(UInt32.self),
                  let hashes = reader.readUInt32Array(count: Int(hashCount))
            else {
                // Truncated or corrupt: keep whatever parsed cleanly so far.
                return cache
            }

            cache.entries[path] = Entry(
                fileSize: fileSize,
                modifiedAt: Double(bitPattern: modifiedBits),
                analysisSeconds: Int(analysisSeconds),
                fingerprint: AudioFingerprint(duration: Int(duration), hashes: hashes)
            )
        }

        return cache
    }

    /// Stats the file fresh on every call.
    ///
    /// Deliberately `FileManager.attributesOfItem` rather than
    /// `URL.resourceValues`: a `URL` caches the resource values it has already
    /// fetched, so a re-tagged (or deleted) file would keep reporting its old
    /// size and date and the cache would serve a stale fingerprint.
    private static func fileStamp(for url: URL) -> (size: UInt64, modifiedAt: Double)? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date
        else {
            return nil
        }
        return (size.uint64Value, modified.timeIntervalSince1970)
    }
}

// MARK: - Byte helpers

/// All supported platforms are little-endian, so multi-byte values are stored
/// in host order and the bulk hash copy below is a straight memcpy.
private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}

private struct ByteReader {
    let bytes: [UInt8]
    private var offset = 0

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    mutating func readBytes(_ count: Int) -> [UInt8]? {
        guard count >= 0, offset + count <= bytes.count else { return nil }
        defer { offset += count }
        return Array(bytes[offset..<(offset + count)])
    }

    mutating func read<T: FixedWidthInteger>(_ type: T.Type) -> T? {
        let size = MemoryLayout<T>.size
        guard offset + size <= bytes.count else { return nil }
        var value: T = 0
        withUnsafeMutableBytes(of: &value) { destination in
            for index in 0..<size {
                destination[index] = bytes[offset + index]
            }
        }
        offset += size
        return T(littleEndian: value)
    }

    /// Bulk-reads hashes; the per-byte path above would be far too slow for the
    /// ~948 values in every record.
    mutating func readUInt32Array(count: Int) -> [UInt32]? {
        guard count >= 0 else { return nil }
        let byteCount = count * MemoryLayout<UInt32>.size
        guard offset + byteCount <= bytes.count else { return nil }
        guard count > 0 else {
            offset += byteCount
            return []
        }

        var result = [UInt32](repeating: 0, count: count)
        result.withUnsafeMutableBytes { destination in
            bytes.withUnsafeBytes { source in
                destination.copyMemory(
                    from: UnsafeRawBufferPointer(rebasing: source[offset..<(offset + byteCount)])
                )
            }
        }
        offset += byteCount
        return result
    }
}
