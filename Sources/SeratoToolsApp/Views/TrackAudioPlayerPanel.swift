import SwiftUI
import AppKit
import AVFoundation
import SeratoToolsCore

@MainActor
final class TrackAudioPlayerViewModel: NSObject, ObservableObject {
    @Published var isPlaying = false
    @Published var duration: Double = 0
    @Published var currentTime: Double = 0
    @Published var errorMessage: String?
    @Published var loadedTrackPath: String?

    private var player: AVAudioPlayer?

    func load(track: Track) {
        if loadedTrackPath == track.seratoStoredPath {
            return
        }

        isPlaying = false
        loadedTrackPath = nil
        duration = 0
        currentTime = 0

        guard FileManager.default.fileExists(atPath: track.fileURL.path) else {
            errorMessage = "Track file is missing on disk."
            player = nil
            return
        }

        do {
            let newPlayer = try AVAudioPlayer(contentsOf: track.fileURL)
            newPlayer.prepareToPlay()
            player = newPlayer
            duration = newPlayer.duration
            currentTime = newPlayer.currentTime
            loadedTrackPath = track.seratoStoredPath
            errorMessage = nil
        } catch {
            player = nil
            errorMessage = "Couldn't load audio: \(error.localizedDescription)"
        }
    }

    func startPlayback() {
        guard let player else { return }
        player.play()
        isPlaying = true
        currentTime = player.currentTime
    }

    func stopPlayback() {
        guard let player else { return }
        player.pause()
        player.currentTime = 0
        isPlaying = false
        currentTime = 0
    }

    func handleSpacebarToggle() {
        if isPlaying {
            stopPlayback()
        } else {
            startPlayback()
        }
    }

    func seek(to time: Double) {
        guard let player else { return }
        let clamped = max(0, min(time, duration))
        player.currentTime = clamped
        currentTime = clamped
    }

    func refreshProgress() {
        guard let player else { return }
        currentTime = player.currentTime
        isPlaying = player.isPlaying
    }
}

struct TrackAudioPlayerPanel: View {
    let track: Track
    let activationToken: Int

    @StateObject private var player = TrackAudioPlayerViewModel()
    @State private var keyMonitor: Any?
    @AppStorage("TrackAudioPlayerMiniModeEnabled") private var miniModeEnabled = false

    init(track: Track, activationToken: Int = 0) {
        self.track = track
        self.activationToken = activationToken
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(track.title.isEmpty ? track.fileURL.lastPathComponent : track.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                Text(timeLabel)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)

                Button(miniModeEnabled ? "Full" : "Mini") {
                    miniModeEnabled.toggle()
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }

            Slider(
                value: Binding(
                    get: { player.currentTime },
                    set: { player.seek(to: $0) }
                ),
                in: 0...max(player.duration, 1)
            )
            .controlSize(.small)
            .disabled(player.loadedTrackPath == nil)

            HStack(spacing: 6) {
                Button {
                    player.startPlayback()
                } label: {
                    if miniModeEnabled {
                        Image(systemName: "play.fill")
                    } else {
                        Text("Start")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.mini)
                .disabled(player.loadedTrackPath == nil)

                Button {
                    player.stopPlayback()
                } label: {
                    if miniModeEnabled {
                        Image(systemName: "stop.fill")
                    } else {
                        Text("Stop")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .disabled(player.loadedTrackPath == nil)

                Spacer()

                if !miniModeEnabled {
                    Text("Space: Start/Stop")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if let error = player.errorMessage {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: miniModeEnabled ? 320 : 420)
        .padding(6)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .onAppear {
            player.load(track: track)
            installKeyboardMonitor()
            if activationToken > 0 {
                player.startPlayback()
            }
        }
        .onDisappear {
            removeKeyboardMonitor()
        }
        .onChange(of: track.id) {
            player.load(track: track)
        }
        .onChange(of: activationToken) {
            guard player.loadedTrackPath != nil else { return }
            player.startPlayback()
        }
        .onReceive(Timer.publish(every: 0.12, on: .main, in: .common).autoconnect()) { _ in
            player.refreshProgress()
        }
    }

    private func installKeyboardMonitor() {
        guard keyMonitor == nil else { return }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            if isTextInputActive() {
                return event
            }

            if !event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
                return event
            }

            // Spacebar key code on macOS.
            if event.keyCode == 49 {
                player.handleSpacebarToggle()
                return nil
            }

            return event
        }
    }

    private func removeKeyboardMonitor() {
        guard let keyMonitor else { return }
        NSEvent.removeMonitor(keyMonitor)
        self.keyMonitor = nil
    }

    private func isTextInputActive() -> Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        return responder is NSTextView
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        let minutes = total / 60
        let remainder = total % 60
        return String(format: "%d:%02d", minutes, remainder)
    }

    private var timeLabel: String {
        let current = formatTime(player.currentTime)
        let total = formatTime(player.duration)
        return miniModeEnabled ? "\(current)/\(total)" : "\(current) / \(total)"
    }
}
