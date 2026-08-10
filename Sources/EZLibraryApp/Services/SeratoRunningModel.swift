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
import Combine
import EZLibraryCore

/// Tracks whether Serato is running so the UI can say so up front, rather than
/// letting every library write fail one at a time.
///
/// Driven by the workspace's launch/terminate notifications rather than a
/// timer: the state only changes when an app starts or stops, and polling for
/// it would burn cycles for something the system already broadcasts. A refresh
/// on `didBecomeActive` covers the case where Serato quit while EZLibrary was
/// in the background and the notification was missed.
@MainActor
final class SeratoRunningModel: ObservableObject {
    @Published private(set) var isSeratoRunning: Bool

    /// Holds the observer tokens so they are removed when the model goes away.
    /// Kept in its own object because a `@MainActor` type's `deinit` is
    /// nonisolated and so cannot touch the actor-isolated stored properties.
    private final class ObserverBag: @unchecked Sendable {
        var tokens: [NSObjectProtocol] = []

        deinit {
            let workspaceCenter = NSWorkspace.shared.notificationCenter
            for token in tokens {
                workspaceCenter.removeObserver(token)
                NotificationCenter.default.removeObserver(token)
            }
        }
    }

    private let observers = ObserverBag()

    init() {
        isSeratoRunning = SeratoProcessGuard.isSeratoRunning

        let center = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification
        ] {
            observers.tokens.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refresh() }
                }
            )
        }

        observers.tokens.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        )
    }

    func refresh() {
        let running = SeratoProcessGuard.isSeratoRunning
        guard running != isSeratoRunning else { return }
        isSeratoRunning = running
    }
}
