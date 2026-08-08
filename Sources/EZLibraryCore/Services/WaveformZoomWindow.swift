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

/// Which slice of a track a waveform view is currently showing.
///
/// Zoom and scroll are coupled — changing the zoom changes how much can be
/// scrolled, and both have to stay inside the file — so they live together in
/// one value that can never represent an out-of-bounds window. Every mutation
/// re-clamps, and the invariants are covered by tests rather than left to the
/// view layer to get right.
public struct WaveformZoomWindow: Sendable, Equatable {
    /// Length of the whole track.
    public let duration: TimeInterval
    /// Shortest window we'll zoom to. Past this the stored envelope has no more
    /// detail to reveal and the drag handles get hard to hit.
    public let minimumVisibleDuration: TimeInterval

    /// 1 shows the whole file; 4 shows a quarter of it.
    public private(set) var zoom: Double
    /// Time at the left edge of the window.
    public private(set) var start: TimeInterval

    public init(duration: TimeInterval, minimumVisibleDuration: TimeInterval = 0.25) {
        self.duration = max(0, duration)
        self.minimumVisibleDuration = max(0.001, minimumVisibleDuration)
        self.zoom = 1
        self.start = 0
    }

    public var visibleDuration: TimeInterval {
        guard duration > 0 else { return 0 }
        return min(duration, duration / zoom)
    }

    public var end: TimeInterval { min(duration, start + visibleDuration) }

    public var maximumZoom: Double {
        guard duration > minimumVisibleDuration else { return 1 }
        return duration / minimumVisibleDuration
    }

    /// Largest `start` that still fills the window with audio.
    public var maximumStart: TimeInterval { max(0, duration - visibleDuration) }

    public var canZoomIn: Bool { zoom < maximumZoom - 0.001 }
    public var canZoomOut: Bool { zoom > 1.001 }

    public func contains(_ seconds: TimeInterval) -> Bool {
        seconds >= start && seconds <= end
    }

    // MARK: - Mutations

    public mutating func setStart(_ seconds: TimeInterval) {
        start = min(max(0, seconds), maximumStart)
    }

    /// Changes the zoom while holding `anchor` at the same fraction across the
    /// window, so the waveform grows around what the user is pointing at
    /// instead of jumping somewhere else. Defaults to the window's centre.
    public mutating func setZoom(_ newZoom: Double, anchoredAt anchor: TimeInterval? = nil) {
        guard duration > 0 else { return }

        let anchorTime = anchor ?? (start + visibleDuration / 2)
        // Captured before the zoom changes, since `visibleDuration` moves with it.
        let anchorFraction = visibleDuration > 0
            ? min(max(0, (anchorTime - start) / visibleDuration), 1)
            : 0.5

        zoom = min(max(1, newZoom), maximumZoom)
        setStart(anchorTime - anchorFraction * visibleDuration)
    }

    public mutating func zoomIn(anchoredAt anchor: TimeInterval? = nil) {
        setZoom(zoom * 2, anchoredAt: anchor)
    }

    public mutating func zoomOut(anchoredAt anchor: TimeInterval? = nil) {
        setZoom(zoom / 2, anchoredAt: anchor)
    }

    public mutating func fit() {
        zoom = 1
        start = 0
    }

    /// Frames `selectionStart...selectionEnd` with a little air either side, so
    /// both trim handles stay on screen and grabbable after the jump.
    public mutating func frame(
        selectionStart: TimeInterval,
        selectionEnd: TimeInterval,
        padding: Double = 1.2
    ) {
        guard duration > 0 else { return }
        let selectionDuration = selectionEnd - selectionStart
        guard selectionDuration > 0 else { return }

        let padded = max(minimumVisibleDuration, selectionDuration * padding)
        zoom = min(maximumZoom, max(1, duration / padded))
        setStart(selectionStart - (visibleDuration - selectionDuration) / 2)
    }

    /// Scrolls just far enough to bring `seconds` back into view, keeping a
    /// margin off each edge. Recentring on every step would make a playing
    /// marker feel like it drags the whole waveform along with it.
    public mutating func ensureVisible(_ seconds: TimeInterval, marginFraction: Double = 0.1) {
        guard canZoomOut else { return }
        let margin = visibleDuration * marginFraction

        if seconds < start + margin {
            setStart(seconds - margin)
        } else if seconds > end - margin {
            setStart(seconds - visibleDuration + margin)
        }
    }
}
