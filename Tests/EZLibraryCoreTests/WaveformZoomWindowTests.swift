// EZLibrary — an open source toolkit for Serato DJ libraries.
// Copyright (C) 2026 Tawaun Lucas
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. It is distributed WITHOUT ANY WARRANTY; see the GNU
// General Public License (LICENSE) for more details.

import Testing
import Foundation
@testable import EZLibraryCore

struct WaveformZoomWindowTests {

    private func makeWindow(duration: TimeInterval = 100) -> WaveformZoomWindow {
        WaveformZoomWindow(duration: duration)
    }

    // MARK: - Defaults

    @Test func startsShowingTheWholeTrack() {
        let window = makeWindow()

        #expect(window.zoom == 1)
        #expect(window.start == 0)
        #expect(window.end == 100)
        #expect(window.visibleDuration == 100)
        #expect(!window.canZoomOut)
        #expect(window.canZoomIn)
    }

    @Test func zoomingHalvesTheVisibleSpanEachStep() {
        var window = makeWindow()

        window.zoomIn(anchoredAt: 50)
        #expect(window.visibleDuration == 50)

        window.zoomIn(anchoredAt: 50)
        #expect(window.visibleDuration == 25)
    }

    // MARK: - Invariants

    /// The window must never show past either end of the file, however it got
    /// there — this is the bug that makes a waveform render blank space.
    @Test func windowNeverEscapesTheFile() {
        var window = makeWindow()
        window.setZoom(8)

        window.setStart(-500)
        #expect(window.start == 0)

        window.setStart(500)
        #expect(window.start == window.maximumStart)
        #expect(abs(window.end - 100) < 0.0001)
    }

    @Test func zoomIsClampedToBothEnds() {
        var window = makeWindow()

        window.setZoom(0.01)
        #expect(window.zoom == 1)

        window.setZoom(100_000)
        #expect(window.zoom == window.maximumZoom)
        // 100s at a 0.25s floor.
        #expect(abs(window.visibleDuration - 0.25) < 0.0001)
    }

    /// Zooming out from a window scrolled to the end must pull the start back
    /// rather than leaving a gap past the end of the file.
    @Test func zoomingOutAtTheEndPullsTheWindowBackIntoRange() {
        var window = makeWindow()
        window.setZoom(10)
        window.setStart(1000)
        #expect(abs(window.start - 90) < 0.0001)

        window.zoomOut()

        #expect(window.start + window.visibleDuration <= 100.0001)
        #expect(window.start >= 0)
    }

    @Test func aTrackShorterThanTheMinimumWindowCannotZoom() {
        var window = WaveformZoomWindow(duration: 0.1)

        window.setZoom(10)

        #expect(window.zoom == 1)
        #expect(!window.canZoomIn)
    }

    @Test func aZeroLengthTrackIsInert() {
        var window = WaveformZoomWindow(duration: 0)

        window.setZoom(8)
        window.setStart(5)

        #expect(window.zoom == 1)
        #expect(window.start == 0)
        #expect(window.visibleDuration == 0)
    }

    // MARK: - Anchoring

    /// Zooming should grow the waveform around the point of interest, so the
    /// anchor stays at the same spot on screen.
    @Test func zoomingHoldsTheAnchorAtTheSameFractionOfTheWindow() {
        var window = makeWindow()
        window.setZoom(2)          // showing 0...50
        window.setStart(0)

        // The anchor sits a quarter of the way across the visible window.
        let anchor = 12.5
        window.setZoom(4, anchoredAt: anchor)

        let fraction = (anchor - window.start) / window.visibleDuration
        #expect(abs(fraction - 0.25) < 0.0001)
    }

    /// Anchoring near an edge can't be honoured exactly without leaving the
    /// file; the window clamps instead of drifting out of bounds.
    @Test func anchoringNearAnEdgeStillProducesAnInBoundsWindow() {
        var window = makeWindow()

        window.setZoom(20, anchoredAt: 0)
        #expect(window.start == 0)

        window.setZoom(40, anchoredAt: 100)
        #expect(abs(window.end - 100) < 0.0001)
        #expect(window.start >= 0)
    }

    @Test func zoomingWithoutAnAnchorKeepsTheCentre() {
        var window = makeWindow()
        window.setZoom(2)
        window.setStart(25) // showing 25...75, centred on 50

        window.setZoom(4)

        let centre = window.start + window.visibleDuration / 2
        #expect(abs(centre - 50) < 0.0001)
    }

    // MARK: - Framing a selection

    @Test func framingASelectionShowsItWithAMarginEitherSide() {
        var window = makeWindow()

        window.frame(selectionStart: 40, selectionEnd: 50)

        #expect(window.start < 40)
        #expect(window.end > 50)
        #expect(window.visibleDuration < 100)
    }

    @Test func framingAFullLengthSelectionFallsBackToTheWholeTrack() {
        var window = makeWindow()
        window.setZoom(8)

        window.frame(selectionStart: 0, selectionEnd: 100)

        #expect(window.zoom == 1)
        #expect(window.start == 0)
    }

    @Test func framingAnEmptySelectionDoesNothing() {
        var window = makeWindow()
        window.setZoom(4)
        let before = window

        window.frame(selectionStart: 30, selectionEnd: 30)

        #expect(window == before)
    }

    // MARK: - Following the marker

    @Test func ensureVisibleScrollsAMarkerThatRanOffTheRightEdge() {
        var window = makeWindow()
        window.setZoom(10)
        window.setStart(0) // showing 0...10

        window.ensureVisible(30)

        #expect(window.contains(30))
    }

    @Test func ensureVisibleScrollsBackwardsToo() {
        var window = makeWindow()
        window.setZoom(10)
        window.setStart(50)

        window.ensureVisible(5)

        #expect(window.contains(5))
    }

    /// A marker comfortably inside the window must not move it — otherwise the
    /// waveform would crawl along under a playing marker.
    @Test func ensureVisibleLeavesAnAlreadyVisibleMarkerAlone() {
        var window = makeWindow()
        window.setZoom(10)
        window.setStart(20) // showing 20...30

        window.ensureVisible(25)

        #expect(window.start == 20)
    }

    @Test func ensureVisibleIsANoOpWhenTheWholeTrackIsShowing() {
        var window = makeWindow()

        window.ensureVisible(80)

        #expect(window.start == 0)
        #expect(window.zoom == 1)
    }

    @Test func containsCoversTheInclusiveEdges() {
        var window = makeWindow()
        window.setZoom(4)
        window.setStart(10)

        #expect(window.contains(10))
        #expect(window.contains(35))
        #expect(!window.contains(9.9))
        #expect(!window.contains(35.1))
    }
}
