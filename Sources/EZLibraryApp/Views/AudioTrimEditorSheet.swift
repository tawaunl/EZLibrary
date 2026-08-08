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
import AppKit
import AVFoundation
import UniformTypeIdentifiers
import EZLibraryCore

/// Drives the trim editor: waveform, in/out points, selection preview, and the
/// two ways of committing the edit.
@MainActor
final class AudioTrimEditorModel: ObservableObject {
    @Published var waveform: AudioWaveform?
    @Published var isLoadingWaveform = true
    @Published var loadErrorMessage: String?

    @Published var startSeconds: Double = 0
    @Published var endSeconds: Double = 0
    @Published var duration: Double = 0

    @Published var isPlaying = false
    @Published var playheadSeconds: Double = 0
    /// Playback speed for scanning. 1 is normal; the transport cycles upward.
    @Published private(set) var playbackRate: Double = 1

    /// Which slice of the track the waveform is showing. All the clamping lives
    /// in the value itself (see `WaveformZoomWindow`).
    @Published private(set) var window = WaveformZoomWindow(duration: 0)

    /// A cue the user drops to come back to, independent of the playhead.
    /// Nil until they drop one.
    @Published private(set) var markerSeconds: Double?

    @Published var analysis: SeratoAnalysisSummary = .none
    @Published var isSaving = false
    @Published var errorMessage: String?

    private var player: AVAudioPlayer?
    private let track: Track

    init(track: Track) {
        self.track = track
    }

    var selectionDuration: Double { max(0, endSeconds - startSeconds) }

    // MARK: - Zoom window

    var zoom: Double { window.zoom }
    var windowStart: Double { window.start }
    var windowEnd: Double { window.end }
    var visibleDuration: Double { window.visibleDuration }
    var maximumWindowStart: Double { window.maximumStart }
    var canZoomIn: Bool { window.canZoomIn }
    var canZoomOut: Bool { window.canZoomOut }

    func setZoom(_ newZoom: Double, anchoredAt anchorSeconds: Double? = nil) {
        window.setZoom(newZoom, anchoredAt: anchorSeconds)
    }

    func zoomIn() { window.zoomIn(anchoredAt: playheadSeconds) }

    func zoomOut() { window.zoomOut(anchoredAt: playheadSeconds) }

    func zoomToFit() { window.fit() }

    func zoomToSelection() {
        window.frame(selectionStart: startSeconds, selectionEnd: endSeconds)
    }

    func setWindowStart(_ seconds: Double) { window.setStart(seconds) }

    func ensurePlayheadVisible() { window.ensureVisible(playheadSeconds) }

    var trimmedFromStart: Double { startSeconds }
    var trimmedFromEnd: Double { max(0, duration - endSeconds) }

    /// Nothing to do when the selection still covers the whole file.
    var hasEdits: Bool {
        trimmedFromStart > 0.01 || trimmedFromEnd > 0.01
    }

    var canSave: Bool {
        hasEdits && !isSaving && selectionDuration >= AudioTrimService.minimumDuration
    }

    // MARK: - Loading

    func load() async {
        analysis = TrackAudioEditService.analysisSummary(for: track)

        // Playback is set up from the file itself so the preview works even if
        // waveform decoding fails.
        if let audioPlayer = try? AVAudioPlayer(contentsOf: track.fileURL) {
            // Required before `rate` does anything — it's what makes the
            // fast-forward speeds actually scan rather than play at 1×.
            audioPlayer.enableRate = true
            audioPlayer.prepareToPlay()
            player = audioPlayer
            setDuration(audioPlayer.duration)
        }

        do {
            // Sampled far finer than one screen needs so zooming in reveals
            // real detail rather than stretching the same columns.
            let decoded = try await AudioWaveformSampler.waveform(
                forFileAt: track.fileURL, resolution: .perSecond(400))
            waveform = decoded
            if duration <= 0 {
                setDuration(decoded.duration)
            }
        } catch {
            loadErrorMessage = error.localizedDescription
        }
        isLoadingWaveform = false
    }

    /// The track's length is only known once the file has been opened, and the
    /// zoom window is sized from it, so the two are always set together.
    private func setDuration(_ newDuration: Double) {
        duration = newDuration
        endSeconds = newDuration
        window = WaveformZoomWindow(duration: newDuration)
    }

    // MARK: - Selection

    func setStart(_ seconds: Double) {
        let upperBound = max(0, endSeconds - AudioTrimService.minimumDuration)
        startSeconds = min(max(0, seconds), upperBound)
        if playheadSeconds < startSeconds { seek(to: startSeconds) }
    }

    func setEnd(_ seconds: Double) {
        let lowerBound = min(duration, startSeconds + AudioTrimService.minimumDuration)
        endSeconds = max(min(duration, seconds), lowerBound)
        if playheadSeconds > endSeconds { seek(to: startSeconds) }
    }

    func resetSelection() {
        startSeconds = 0
        endSeconds = duration
    }

    /// Makes the playhead's position the new in point, and cues playback there so
    /// the next play starts from the cut the user just made.
    func setInAtPlayhead() {
        setStart(playheadSeconds)
        seek(to: startSeconds)
    }

    /// Makes the playhead's position the new out point.
    func setOutAtPlayhead() {
        setEnd(playheadSeconds)
    }

    /// Steps the playhead by `seconds`, following it with the view when zoomed in.
    /// Stops playback first so the nudge isn't immediately overwritten by the
    /// player's own position on the next tick.
    func nudgePlayhead(by seconds: Double) {
        if isPlaying { stopPreview() }
        seek(to: playheadSeconds + seconds)
        ensurePlayheadVisible()
    }

    /// Jumps the playhead to the in or out point — the two places you usually
    /// want to start listening from.
    func movePlayheadToInPoint() {
        seek(to: startSeconds)
        ensurePlayheadVisible()
    }

    func movePlayheadToOutPoint() {
        seek(to: endSeconds)
        ensurePlayheadVisible()
    }

    /// Snaps the selection to the audio, dropping leading and trailing silence.
    /// Returns false when the file is silent throughout and there is nothing
    /// meaningful to suggest.
    @discardableResult
    func detectSilence() -> Bool {
        guard let waveform,
              let bounds = AudioWaveformSampler.loudBounds(in: waveform) else {
            return false
        }
        // Assigned directly rather than through the clamping setters, which
        // would fight each other while both ends move at once.
        startSeconds = min(bounds.start, max(0, bounds.end - AudioTrimService.minimumDuration))
        endSeconds = max(bounds.end, startSeconds + AudioTrimService.minimumDuration)
        seek(to: startSeconds)
        return true
    }

    // MARK: - Preview

    /// Where the current run of playback should stop.
    ///
    /// Playing from inside the selection stops at the out point, so what you
    /// hear is exactly what you'd keep. Playing from past it runs to the end of
    /// the file instead — that's how you audition the tail you're about to cut
    /// before committing to losing it.
    private var playbackStopSeconds: Double = 0

    func play() {
        guard let player else { return }

        // Parked on a stopping point — the out point, or the end of the file —
        // playing would produce nothing at all. Rewind so play always plays.
        let isParkedAtAStop = playheadSeconds >= duration - 0.01
            || abs(playheadSeconds - endSeconds) < 0.01
        if isParkedAtAStop {
            seek(to: startSeconds)
        }

        playbackStopSeconds = playheadSeconds > endSeconds ? duration : endSeconds
        player.rate = Float(playbackRate)
        player.play()
        isPlaying = true
    }

    func pause() {
        guard let player else { return }
        player.pause()
        isPlaying = false
        playheadSeconds = player.currentTime
    }

    func togglePreview() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    /// Plays the last two seconds before the out point, the quickest way to
    /// check an outro cut lands cleanly.
    func previewOutPoint() {
        seek(to: max(startSeconds, endSeconds - 2))
        play()
    }

    /// Transport skip. Unlike the arrow-key nudge this doesn't interrupt
    /// playback — it's the ⏪/⏩ behaviour of jumping while the audio runs on.
    func skip(by seconds: Double) {
        seek(to: playheadSeconds + seconds)
        // Skipping past the out point extends this run to the end of the file,
        // so fast-forwarding into the trimmed tail doesn't stop dead at the cut.
        if isPlaying, playheadSeconds > playbackStopSeconds {
            playbackStopSeconds = duration
        }
        ensurePlayheadVisible()
    }

    /// Cycles the scan speed. Applied live so holding ⏩ down while playing
    /// speeds up what you're already hearing.
    func cyclePlaybackRate() {
        let rates: [Double] = [1, 1.5, 2, 4]
        let next = rates.firstIndex(of: playbackRate).map { (($0 + 1) % rates.count) } ?? 0
        playbackRate = rates[next]
        if isPlaying { player?.rate = Float(playbackRate) }
    }

    func resetPlaybackRate() {
        playbackRate = 1
        if isPlaying { player?.rate = 1 }
    }

    // MARK: - Jumps

    func jumpToFileStart() {
        seek(to: 0)
        ensurePlayheadVisible()
    }

    func jumpToFileEnd() {
        seek(to: duration)
        ensurePlayheadVisible()
    }

    /// Drops a cue at the playhead — somewhere to wander away from and come
    /// back to while hunting for a cut point.
    func dropMarker() {
        markerSeconds = playheadSeconds
    }

    func clearMarker() {
        markerSeconds = nil
    }

    func jumpToMarker() {
        guard let markerSeconds else { return }
        seek(to: markerSeconds)
        ensurePlayheadVisible()
    }

    func seek(to seconds: Double) {
        let clamped = min(max(0, seconds), duration)
        player?.currentTime = clamped
        playheadSeconds = clamped
    }

    func stopPreview() {
        player?.pause()
        isPlaying = false
    }

    /// Called on the UI tick: advances the playhead and stops at the out point
    /// so preview never runs past the selection.
    func refreshPlayhead() {
        guard let player, isPlaying else { return }
        playheadSeconds = player.currentTime
        if player.currentTime >= playbackStopSeconds || !player.isPlaying {
            player.pause()
            isPlaying = false
            playheadSeconds = min(playheadSeconds, playbackStopSeconds)
        }
        ensurePlayheadVisible()
    }

    // MARK: - Saving

    /// Trims the file in place. Returns a summary line on success.
    func saveInPlace() async -> String? {
        stopPreview()
        isSaving = true
        defer { isSaving = false }

        let (start, end) = (startSeconds, endSeconds)
        let editedTrack = track
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try TrackAudioEditService.saveInPlace(
                    track: editedTrack, startSeconds: start, endSeconds: end)
            }.value
            return "Trimmed \(editedTrack.fileURL.lastPathComponent) to "
                + "\(formatTime(result.trimmedDuration)). The original was backed up."
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Trims into `destination` and registers it with Serato.
    func saveAsNewFile(destination: URL, libraryDirectory: URL, addToCrates: Bool) async -> String? {
        stopPreview()
        isSaving = true
        defer { isSaving = false }

        let (start, end) = (startSeconds, endSeconds)
        let editedTrack = track
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try TrackAudioEditService.saveAsNewFile(
                    track: editedTrack,
                    startSeconds: start,
                    endSeconds: end,
                    destinationURL: destination,
                    libraryDirectory: libraryDirectory,
                    addToCratesContainingOriginal: addToCrates
                )
            }.value

            var summary = "Saved \(result.outputURL.lastPathComponent) "
                + "(\(formatTime(result.trimmedDuration))) and added it to your library."
            if !result.cratesUpdated.isEmpty {
                summary += " Added to \(result.cratesUpdated.joined(separator: ", "))."
            }
            return summary
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    var suggestedDestination: URL {
        AudioTrimService.suggestedEditURL(for: track.fileURL)
    }
}

/// Formats a position as `m:ss.t`, precise enough to judge a trim by eye.
private func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00.0" }
    let minutes = Int(seconds) / 60
    let remainder = seconds - Double(minutes * 60)
    return String(format: "%d:%04.1f", minutes, remainder)
}

// MARK: - Sheet

struct AudioTrimEditorSheet: View {
    let track: Track
    let libraryDirectory: URL
    /// Called after a successful save with a summary line for the caller to
    /// surface, so the library can be reloaded.
    let onSaved: (String) -> Void

    @StateObject private var model: AudioTrimEditorModel
    @Environment(\.dismiss) private var dismiss

    @AppStorage("AudioTrimAddEditToCratesOfOriginal") private var addToCrates = true
    @State private var showInPlaceConfirmation = false
    @State private var keyMonitor: Any?

    init(track: Track, libraryDirectory: URL, onSaved: @escaping (String) -> Void) {
        self.track = track
        self.libraryDirectory = libraryDirectory
        self.onSaved = onSaved
        _model = StateObject(wrappedValue: AudioTrimEditorModel(track: track))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            waveformSection
            zoomRow
            transportRow
            editingRow
            selectionFields
            keyboardHintRow

            if let warning = model.analysis.trimWarning {
                analysisWarning(warning)
            }

            Divider()
            saveRow
        }
        .padding(18)
        .frame(minWidth: 720, idealWidth: 820, minHeight: 520)
        .task { await model.load() }
        .onAppear { installKeyboardMonitor() }
        .onDisappear {
            removeKeyboardMonitor()
            model.stopPreview()
        }
        .onReceive(Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()) { _ in
            model.refreshPlayhead()
        }
        .alert(
            "Couldn't Save the Edit",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } })
        ) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .confirmationDialog(
            "Overwrite \(track.fileURL.lastPathComponent)?",
            isPresented: $showInPlaceConfirmation,
            titleVisibility: .visible
        ) {
            Button("Trim and Overwrite", role: .destructive) {
                Task {
                    if let summary = await model.saveInPlace() {
                        onSaved(summary)
                        dismiss()
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(inPlaceConfirmationMessage)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(track.title.isEmpty ? track.fileURL.lastPathComponent : track.title)
                .font(.headline)
            Text(track.fileURL.path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    // MARK: - Waveform

    @ViewBuilder
    private var waveformSection: some View {
        ZStack {
            if model.isLoadingWaveform {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading audio…").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 160)
            } else if let waveform = model.waveform {
                TrimWaveformView(
                    waveform: waveform,
                    startSeconds: model.startSeconds,
                    endSeconds: model.endSeconds,
                    playheadSeconds: model.playheadSeconds,
                    markerSeconds: model.markerSeconds,
                    windowStart: model.windowStart,
                    windowEnd: model.windowEnd,
                    onScrub: { model.seek(to: $0) },
                    onDragStart: { model.setStart($0) },
                    onDragEnd: { model.setEnd($0) },
                    onZoomBy: { factor, anchor in
                        model.setZoom(model.zoom * factor, anchoredAt: anchor)
                    }
                )
                .frame(height: 160)
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "waveform.slash").font(.title2).foregroundStyle(.secondary)
                    Text(model.loadErrorMessage ?? "Couldn't read this file's audio.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 160)
            }
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Zoom

    private var zoomRow: some View {
        HStack(spacing: 8) {
            Button {
                model.zoomOut()
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .controlSize(.small)
            .disabled(!model.canZoomOut)
            .help("Zoom out (−).")

            Button {
                model.zoomIn()
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .controlSize(.small)
            .disabled(!model.canZoomIn)
            .help("Zoom in around the playhead (+).")

            Button("Fit") { model.zoomToFit() }
                .controlSize(.small)
                .disabled(!model.canZoomOut)
                .help("Show the whole track.")

            Button("Zoom to Selection") { model.zoomToSelection() }
                .controlSize(.small)
                .disabled(model.selectionDuration <= 0)
                .help("Frame the part you're keeping.")

            Text(zoomLabel)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .leading)

            // Only meaningful once part of the track is off-screen.
            if model.canZoomOut {
                Slider(
                    value: Binding(
                        get: { model.windowStart },
                        set: { model.setWindowStart($0) }
                    ),
                    in: 0...max(0.0001, model.maximumWindowStart)
                )
                .controlSize(.small)
                .help("Scroll through the track.")
            }

            Spacer(minLength: 0)
        }
    }

    private var zoomLabel: String {
        model.zoom < 10
            ? String(format: "%.1f×", model.zoom)
            : String(format: "%.0f×", model.zoom)
    }

    // MARK: - Transport

    private var transportRow: some View {
        HStack(spacing: 6) {
            transportButton(
                "backward.end.fill",
                help: "Jump to the start of the track (Home)."
            ) { model.jumpToFileStart() }

            transportButton(
                "gobackward.5",
                help: "Skip back 5 seconds."
            ) { model.skip(by: -5) }

            Button {
                model.togglePreview()
            } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 22)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(model.duration <= 0)
            .help(model.isPlaying ? "Pause (Space)." : "Play from the playhead (Space).")

            transportButton(
                "goforward.5",
                help: "Skip forward 5 seconds."
            ) { model.skip(by: 5) }

            transportButton(
                "forward.end.fill",
                help: "Jump to the end of the track (End)."
            ) { model.jumpToFileEnd() }

            Button(speedLabel) { model.cyclePlaybackRate() }
                .controlSize(.small)
                .disabled(model.duration <= 0)
                .help("Fast-forward speed. Click to cycle 1× → 1.5× → 2× → 4×.")

            Divider().frame(height: 14)

            Button("Preview Out Point") {
                model.previewOutPoint()
            }
            .controlSize(.small)
            .disabled(model.duration <= 0)
            .help("Play the last two seconds before the out point, to check the cut lands cleanly.")

            Spacer()

            Text("\(formatTime(model.playheadSeconds)) / \(formatTime(model.duration))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var speedLabel: String {
        model.playbackRate == 1.5 ? "1.5×" : String(format: "%.0f×", model.playbackRate)
    }

    private func transportButton(
        _ systemImage: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage).frame(width: 22)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(model.duration <= 0)
        .help(help)
    }

    // MARK: - Jumps and selection editing

    private var editingRow: some View {
        HStack(spacing: 8) {
            Button("To In") { model.movePlayheadToInPoint() }
                .controlSize(.small)
                .disabled(model.duration <= 0)
                .help("Move the playhead to the in point (⌘←).")

            Button("To Out") { model.movePlayheadToOutPoint() }
                .controlSize(.small)
                .disabled(model.duration <= 0)
                .help("Move the playhead to the out point (⌘→).")

            Divider().frame(height: 14)

            Button("Drop Marker") { model.dropMarker() }
                .controlSize(.small)
                .disabled(model.duration <= 0)
                .help("Leave a cue at the playhead to come back to (M).")

            Button(markerJumpLabel) { model.jumpToMarker() }
                .controlSize(.small)
                .disabled(model.markerSeconds == nil)
                .help("Jump back to the dropped marker (⇧M).")

            if model.markerSeconds != nil {
                Button("Clear") { model.clearMarker() }
                    .controlSize(.small)
                    .help("Remove the dropped marker.")
            }

            Divider().frame(height: 14)

            Button("Detect Silence") {
                if !model.detectSilence() {
                    model.errorMessage = "This file is quiet from start to finish, "
                        + "so there's no silence to trim."
                }
            }
            .controlSize(.small)
            .disabled(model.waveform == nil)
            .help("Set the in and out points just inside the leading and trailing silence.")

            Button("Reset") { model.resetSelection() }
                .controlSize(.small)
                .disabled(!model.hasEdits)
                .help("Restore the selection to the whole track.")

            Divider().frame(height: 14)

            Button("Set In Here") { model.setInAtPlayhead() }
                .controlSize(.small)
                .disabled(model.duration <= 0)
                .help("Start the trimmed track at the playhead (I). Playback then starts from there.")

            Button("Set Out Here") { model.setOutAtPlayhead() }
                .controlSize(.small)
                .disabled(model.duration <= 0)
                .help("End the trimmed track at the playhead (O).")

            Spacer(minLength: 0)
        }
    }

    private var markerJumpLabel: String {
        guard let markerSeconds = model.markerSeconds else { return "To Marker" }
        return "To Marker (\(formatTime(markerSeconds)))"
    }

    private var keyboardHintRow: some View {
        Text("Space play/pause · ← → move playhead (⇧ 1s, ⌥ 0.01s) · I/O set in/out · "
            + "⌘← ⌘→ to in/out · Home/End to track start/end · M drop marker, ⇧M return · + − zoom")
            .font(.caption2)
            .foregroundStyle(.secondary)
    }

    // MARK: - Numeric fields

    private var selectionFields: some View {
        HStack(spacing: 16) {
            timeField(
                label: "In",
                seconds: model.startSeconds,
                help: "Where the trimmed track starts.",
                onChange: { model.setStart($0) }
            )
            timeField(
                label: "Out",
                seconds: model.endSeconds,
                help: "Where the trimmed track ends.",
                onChange: { model.setEnd($0) }
            )

            VStack(alignment: .leading, spacing: 2) {
                Text("Keeping").font(.caption).foregroundStyle(.secondary)
                Text(formatTime(model.selectionDuration))
                    .font(.body.monospacedDigit().weight(.semibold))
            }

            if model.hasEdits {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Removing").font(.caption).foregroundStyle(.secondary)
                    Text(removalSummary)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.orange)
                }
            }

            Spacer()
        }
    }

    private func timeField(
        label: String,
        seconds: Double,
        help: String,
        onChange: @escaping (Double) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                Text(formatTime(seconds))
                    .font(.body.monospacedDigit())
                    .frame(width: 66, alignment: .leading)
                Stepper(label) { onChange(seconds + 0.1) } onDecrement: { onChange(seconds - 0.1) }
                    .labelsHidden()
            }
        }
        .help(help)
    }

    private var removalSummary: String {
        var parts: [String] = []
        if model.trimmedFromStart > 0.01 {
            parts.append("\(formatTime(model.trimmedFromStart)) from the start")
        }
        if model.trimmedFromEnd > 0.01 {
            parts.append("\(formatTime(model.trimmedFromEnd)) from the end")
        }
        return parts.joined(separator: ", ")
    }

    // MARK: - Warning

    private func analysisWarning(_ warning: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(warning)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(Color.orange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Saving

    private var saveRow: some View {
        HStack(spacing: 10) {
            Toggle("Add the new file to the original's crates", isOn: $addToCrates)
                .toggleStyle(.checkbox)
                .font(.caption)
                .help("Files the edit alongside the original in every crate that holds it.")

            Spacer()

            if model.isSaving {
                ProgressView().controlSize(.small)
            }

            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(model.isSaving)

            Button("Save In Place…") {
                showInPlaceConfirmation = true
            }
            .disabled(!model.canSave)
            .help("Overwrite this file with the trimmed audio, keeping a backup of the original.")

            Button("Save As New File…") { presentSavePanel() }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canSave)
                .help("Write the trimmed audio to a new file and add it to your library.")
        }
    }

    private var inPlaceConfirmationMessage: String {
        var message = "This replaces the file on disk with the \(formatTime(model.selectionDuration)) "
            + "selection, removing \(removalSummary). "
        if let warning = model.analysis.trimWarning {
            message += warning + " "
        }
        message += "A copy of the original is saved to EZLibrary's backup folder first."
        return message
    }

    // MARK: - Keyboard

    /// macOS virtual key codes for the keys the editor drives.
    private enum Key {
        static let space: UInt16 = 49
        static let leftArrow: UInt16 = 123
        static let rightArrow: UInt16 = 124
        static let letterI: UInt16 = 34
        static let letterO: UInt16 = 31
        static let minus: UInt16 = 27
        static let equal: UInt16 = 24
        static let keypadMinus: UInt16 = 78
        static let keypadPlus: UInt16 = 69
        static let letterM: UInt16 = 46
        static let home: UInt16 = 115
        static let end: UInt16 = 119
    }

    private func installKeyboardMonitor() {
        guard keyMonitor == nil else { return }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            // Never steal keys from a text field or from another window — the
            // save panel runs modally on top of this sheet.
            guard let window = NSApp.keyWindow, window.isSheet else { return event }
            if window.firstResponder is NSTextView { return event }

            return handleKeyDown(event) ? nil : event
        }
    }

    private func removeKeyboardMonitor() {
        guard let keyMonitor else { return }
        NSEvent.removeMonitor(keyMonitor)
        self.keyMonitor = nil
    }

    /// Returns true when the editor consumed the event.
    private func handleKeyDown(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags
        let isCommand = modifiers.contains(.command)

        switch event.keyCode {
        case Key.space where !isCommand:
            model.togglePreview()
        case Key.home:
            model.jumpToFileStart()
        case Key.end:
            model.jumpToFileEnd()
        case Key.letterM where modifiers.contains(.shift):
            model.jumpToMarker()
        case Key.letterM where !isCommand:
            model.dropMarker()
        case Key.leftArrow where isCommand:
            model.movePlayheadToInPoint()
        case Key.rightArrow where isCommand:
            model.movePlayheadToOutPoint()
        case Key.leftArrow:
            model.nudgePlayhead(by: -nudgeStep(for: modifiers))
        case Key.rightArrow:
            model.nudgePlayhead(by: nudgeStep(for: modifiers))
        case Key.letterI where !isCommand:
            model.setInAtPlayhead()
        case Key.letterO where !isCommand:
            model.setOutAtPlayhead()
        case Key.minus, Key.keypadMinus:
            model.zoomOut()
        case Key.equal, Key.keypadPlus:
            model.zoomIn()
        default:
            return false
        }
        return true
    }

    /// Coarse by default, with modifiers for the two magnitudes either side —
    /// a second for finding the spot, a hundredth for landing on it.
    private func nudgeStep(for modifiers: NSEvent.ModifierFlags) -> Double {
        if modifiers.contains(.shift) { return 1.0 }
        if modifiers.contains(.option) { return 0.01 }
        return 0.1
    }

    private func presentSavePanel() {
        let suggested = model.suggestedDestination
        let panel = NSSavePanel()
        panel.title = "Save Trimmed Track"
        panel.prompt = "Save"
        panel.nameFieldStringValue = suggested.lastPathComponent
        panel.directoryURL = suggested.deletingLastPathComponent()
        panel.canCreateDirectories = true
        // The trim is a stream copy, so the output must keep the source
        // container; letting the user change it here would just fail in ffmpeg.
        if let type = UTType(filenameExtension: track.fileURL.pathExtension) {
            panel.allowedContentTypes = [type]
        }

        guard panel.runModal() == .OK, let destination = panel.url else { return }

        Task {
            let summary = await model.saveAsNewFile(
                destination: destination,
                libraryDirectory: libraryDirectory,
                addToCrates: addToCrates
            )
            if let summary {
                onSaved(summary)
                dismiss()
            }
        }
    }
}

// MARK: - Waveform canvas

/// Draws the peak envelope with the kept range highlighted and the trimmed
/// ends dimmed, plus draggable in/out handles.
private struct TrimWaveformView: View {
    let waveform: AudioWaveform
    let startSeconds: Double
    let endSeconds: Double
    let playheadSeconds: Double
    /// A dropped cue, drawn distinctly from the playhead so the two don't read
    /// as the same thing when they happen to sit near each other.
    let markerSeconds: Double?
    /// The slice of the track currently on screen. At zoom 1 this is the whole
    /// file; zoomed in, everything below maps against this window instead.
    let windowStart: Double
    let windowEnd: Double
    let onScrub: (Double) -> Void
    let onDragStart: (Double) -> Void
    let onDragEnd: (Double) -> Void
    let onZoomBy: (Double, Double) -> Void

    private var windowDuration: Double { max(0.0001, windowEnd - windowStart) }

    /// How close to a handle a drag must begin to grab it rather than scrub.
    private let handleGrabDistance: CGFloat = 14

    @State private var activeHandle: Handle?
    @State private var hoverX: CGFloat?

    private enum Handle { case start, end, playhead }

    private func clamp(_ x: CGFloat, to width: CGFloat) -> CGFloat {
        min(max(0, x), width)
    }

    private func isVisible(_ seconds: Double) -> Bool {
        seconds >= windowStart && seconds <= windowEnd
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let startX = xPosition(for: startSeconds, width: width)
            let endX = xPosition(for: endSeconds, width: width)

            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    drawPeaks(in: context, size: size, startX: startX, endX: endX)
                }

                // Dim what's being cut away. Clamped to the visible window so a
                // handle scrolled off-screen still dims the right side.
                Rectangle()
                    .fill(Color.black.opacity(0.35))
                    .frame(width: clamp(startX, to: width))
                Rectangle()
                    .fill(Color.black.opacity(0.35))
                    .frame(width: width - clamp(endX, to: width))
                    .offset(x: clamp(endX, to: width))

                if isVisible(startSeconds) {
                    handle(at: startX, height: height, systemImage: "arrow.right.to.line")
                }
                if isVisible(endSeconds) {
                    handle(at: endX, height: height, systemImage: "arrow.left.to.line")
                }

                if let markerSeconds, isVisible(markerSeconds) {
                    Rectangle()
                        .fill(Color.orange)
                        .frame(width: 1, height: height)
                        .offset(x: xPosition(for: markerSeconds, width: width))
                    Image(systemName: "mappin")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Color.orange)
                        .offset(x: xPosition(for: markerSeconds, width: width) - 3, y: height - 14)
                }

                if isVisible(playheadSeconds) {
                    Rectangle()
                        .fill(Color.primary.opacity(0.85))
                        .frame(width: 1, height: height)
                        .offset(x: xPosition(for: playheadSeconds, width: width))
                }
            }
            .contentShape(Rectangle())
            // Trackpad/mouse zoom over the waveform, anchored under the pointer.
            .onContinuousHover { phase in
                if case let .active(location) = phase { hoverX = location.x }
            }
            .gesture(
                MagnifyGesture()
                    .onChanged { value in
                        let anchor = time(for: hoverX ?? width / 2, width: width)
                        onZoomBy(1 + (value.magnification - 1) * 0.15, anchor)
                    }
            )
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let time = self.time(for: value.location.x, width: width)
                        // The handle is chosen once, when the drag starts, so a
                        // fast drag past the other handle can't hand off to it
                        // mid-gesture.
                        if activeHandle == nil {
                            activeHandle = nearestHandle(
                                toX: value.startLocation.x, startX: startX, endX: endX)
                        }
                        switch activeHandle {
                        case .start: onDragStart(time)
                        case .end: onDragEnd(time)
                        case .playhead, nil: onScrub(time)
                        }
                    }
                    .onEnded { _ in activeHandle = nil }
            )
        }
    }

    private func handle(at x: CGFloat, height: CGFloat, systemImage: String) -> some View {
        ZStack {
            Rectangle()
                .fill(Color.accentColor)
                .frame(width: 2, height: height)
            Image(systemName: systemImage)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Color.white)
                .padding(2)
                .background(Circle().fill(Color.accentColor))
                .offset(y: -height / 2 + 9)
        }
        .offset(x: x - 1)
    }

    private func drawPeaks(in context: GraphicsContext, size: CGSize, startX: CGFloat, endX: CGFloat) {
        // One column per ~1.5pt of width, resampled from the stored envelope
        // over just the visible window — that's what makes zoom show detail.
        let columnCount = max(1, Int(size.width / 1.5))
        let peaks = waveform.peaks(from: windowStart, to: windowEnd, bucketCount: columnCount)
        guard !peaks.isEmpty else { return }

        let midY = size.height / 2
        let columnWidth = size.width / CGFloat(peaks.count)
        var kept = Path()
        var removed = Path()

        for (index, peak) in peaks.enumerated() {
            let x = CGFloat(index) * columnWidth
            // A floor keeps quiet passages visible as a line rather than a gap.
            let barHeight = max(1, CGFloat(peak) * (size.height - 8))
            let bar = CGRect(
                x: x,
                y: midY - barHeight / 2,
                width: max(0.5, columnWidth * 0.85),
                height: barHeight)

            if x >= startX, x <= endX {
                kept.addRect(bar)
            } else {
                removed.addRect(bar)
            }
        }

        context.fill(removed, with: .color(.secondary.opacity(0.45)))
        context.fill(kept, with: .color(.accentColor))
    }

    private func nearestHandle(toX x: CGFloat, startX: CGFloat, endX: CGFloat) -> Handle {
        let startDistance = abs(x - startX)
        let endDistance = abs(x - endX)
        guard min(startDistance, endDistance) <= handleGrabDistance else { return .playhead }
        return startDistance <= endDistance ? .start : .end
    }

    private func xPosition(for seconds: Double, width: CGFloat) -> CGFloat {
        CGFloat((seconds - windowStart) / windowDuration) * width
    }

    private func time(for x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return windowStart }
        let fraction = min(max(0, Double(x / width)), 1)
        return windowStart + fraction * windowDuration
    }
}
