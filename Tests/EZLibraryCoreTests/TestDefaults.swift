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

/// Isolated defaults for tests that leave nothing on disk.
///
/// A named suite is a real file in `~/Library/Preferences`, so a helper that
/// mints one per test leaves a plist behind on every run, forever. This
/// repository had accumulated roughly three thousand of them (about 12 MB)
/// before anyone noticed, because nothing about it ever fails.
///
/// `removePersistentDomain(forName:)` is not the fix on its own: it empties the
/// domain but leaves the file, so cleaning up that way still accumulates empty
/// plists. The only way to leave nothing behind is not to create a persistent
/// domain at all.
enum TestDefaults {
    /// Defaults backed by a dictionary. Nothing is written to disk, nothing
    /// needs cleaning up, and tests stay safe to run in parallel.
    ///
    /// Use this for anything that reads and writes keys, which is almost
    /// everything. `stringArray(forKey:)`, `string(forKey:)`, `bool(forKey:)`
    /// and friends are all defined in terms of `object(forKey:)`, so overriding
    /// the three primitives covers the whole typed surface.
    static func inMemory() -> UserDefaults {
        InMemoryDefaults()
    }

}

private final class InMemoryDefaults: UserDefaults {
    private var storage: [String: Any] = [:]

    init() {
        // `suiteName: nil` is the standard domain; nothing is ever written to
        // it because every accessor below is overridden.
        super.init(suiteName: nil)!
    }

    override func object(forKey defaultName: String) -> Any? {
        storage[defaultName]
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        guard let value else {
            storage.removeValue(forKey: defaultName)
            return
        }
        storage[defaultName] = value
    }

    override func removeObject(forKey defaultName: String) {
        storage.removeValue(forKey: defaultName)
    }

    override func synchronize() -> Bool { true }
}
