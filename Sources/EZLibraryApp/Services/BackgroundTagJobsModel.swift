// EZLibrary — an open source toolkit for Serato DJ libraries.
// Copyright (C) 2026 Tawaun Lucas
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. It is distributed WITHOUT ANY WARRANTY; see the GNU
// General Public License (LICENSE) for more details.

import SwiftUI
import EZLibraryCore

/// Owns long-running tag jobs — and the set of tracks they are actively
/// working on — at a level above the Tracks & Tags view.
///
/// The batch tag operations used to be `@State`/`Task` handles inside the view,
/// so switching to another section tore the view down and cancelled the work.
/// Moving ownership here means a bulk search keeps running while the user builds
/// crates or downloads audio, and the tracks it is writing stay locked so a
/// second edit, delete, or rename can't race the job on the same file.
@MainActor
final class BackgroundTagJobsModel: ObservableObject {
    /// Tracks currently being written by a background job. Edit, delete, and
    /// rename actions skip these while they are in flight so two writers never
    /// touch the same file at once.
    @Published private(set) var lockedTrackIDs: Set<UUID> = []

    @Published private(set) var isRunning = false
    /// What the running job is, for the banner ("Filling genre and year…").
    @Published private(set) var label = ""
    @Published private(set) var done = 0
    @Published private(set) var total = 0
    /// The last job's outcome, shown until the next run or dismissal.
    @Published var message: String?
    @Published var errorMessage: String?

    private var task: Task<Void, Never>?
    /// The IDs the *batch* runner locked, so `finish` releases exactly those.
    private var batchJobIDs: Set<UUID> = []

    // MARK: - Lock queries

    func isLocked(_ id: UUID) -> Bool { lockedTrackIDs.contains(id) }

    func anyLocked(_ tracks: [Track]) -> Bool {
        tracks.contains { lockedTrackIDs.contains($0.id) }
    }

    func lockedCount(in tracks: [Track]) -> Int {
        tracks.reduce(0) { $0 + (lockedTrackIDs.contains($1.id) ? 1 : 0) }
    }

    /// The subset that isn't already busy, for skipping locked tracks rather
    /// than refusing the whole action.
    func unlockedTracks(_ tracks: [Track]) -> [Track] {
        tracks.filter { !lockedTrackIDs.contains($0.id) }
    }

    /// Registers/releases a lock held by a job this model does not own itself —
    /// the AI verification run keeps its own task, but its tracks are locked
    /// here so everything reads one registry.
    func lock(_ ids: Set<UUID>) { lockedTrackIDs.formUnion(ids) }
    func release(_ ids: Set<UUID>) { lockedTrackIDs.subtract(ids) }

    // MARK: - Batch job lifecycle

    var canStart: Bool { !isRunning }

    /// Begins a batch job: locks its tracks, resets progress, and clears the
    /// last result. The caller then spawns the work and hands back its task via
    /// `store` so it can be cancelled.
    func begin(label: String, lock tracks: [Track]) {
        let ids = Set(tracks.map(\.id))
        batchJobIDs = ids
        lockedTrackIDs.formUnion(ids)
        self.label = label
        self.message = nil
        self.errorMessage = nil
        self.done = 0
        self.total = tracks.count
        self.isRunning = true
    }

    func report(done: Int, total: Int) {
        self.done = done
        self.total = total
    }

    /// Retains the running task so a Stop button can cancel it. Stored here, not
    /// in the view, so it survives the view being torn down.
    func store(_ task: Task<Void, Never>) {
        self.task = task
    }

    /// Ends the batch job, releasing its locks and recording the outcome.
    func finish(message: String?, error: String? = nil) {
        lockedTrackIDs.subtract(batchJobIDs)
        batchJobIDs = []
        isRunning = false
        task = nil
        self.message = message
        self.errorMessage = error
    }

    func cancel() {
        task?.cancel()
    }

    func dismissMessage() {
        message = nil
        errorMessage = nil
    }
}
