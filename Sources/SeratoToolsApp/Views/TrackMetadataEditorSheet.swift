import SwiftUI
import SeratoToolsCore

struct TrackMetadataEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    let track: Track
    let onSave: (SeratoTrackMetadataUpdate) -> Void

    @State private var title: String
    @State private var artist: String
    @State private var album: String
    @State private var genre: String
    @State private var comment: String
    @State private var key: String
    @State private var bpmText: String
    @State private var yearText: String
    @State private var sourceSelection: OnlineTrackMetadataLookupService.SourceSelection = .all
    @State private var lookupResults: [OnlineTrackMetadataCandidate] = []
    @State private var isSearchingOnline = false
    @State private var lookupErrorMessage: String?

    init(track: Track, onSave: @escaping (SeratoTrackMetadataUpdate) -> Void) {
        self.track = track
        self.onSave = onSave
        _title = State(initialValue: track.title)
        _artist = State(initialValue: track.artist)
        _album = State(initialValue: track.album)
        _genre = State(initialValue: track.genre)
        _comment = State(initialValue: track.comment)
        _key = State(initialValue: track.key ?? "")
        _bpmText = State(initialValue: track.bpm.map { String(format: "%.0f", $0) } ?? "")
        _yearText = State(initialValue: track.year.map(String.init) ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit Track")
                .font(.headline)
            Text(track.fileURL.lastPathComponent)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Picker("Source", selection: $sourceSelection) {
                    ForEach(OnlineTrackMetadataLookupService.SourceSelection.allCases, id: \.self) { source in
                        Text(source.displayName).tag(source)
                    }
                }
                .pickerStyle(.menu)

                Button("Search Online") {
                    searchOnline()
                }
                .disabled(isSearchingOnline)

                if isSearchingOnline {
                    ProgressView()
                        .controlSize(.small)
                }

                Spacer()
            }

            if let lookupErrorMessage {
                Text(lookupErrorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if !lookupResults.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Online Matches")
                        .font(.subheadline.weight(.semibold))

                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(lookupResults.prefix(10)) { candidate in
                                HStack(alignment: .top, spacing: 10) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("\(candidate.source.displayName): \(candidate.title.isEmpty ? "(untitled)" : candidate.title)")
                                            .font(.callout)

                                        Text(summary(for: candidate))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }

                                    Spacer(minLength: 0)

                                    Button("Use") {
                                        apply(candidate: candidate)
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                    .frame(maxHeight: 170)
                }
            }

            Group {
                row("Title", text: $title)
                row("Artist", text: $artist)
                row("Album", text: $album)
                row("Genre", text: $genre)
                row("Key", text: $key)
                row("BPM", text: $bpmText)
                row("Year", text: $yearText)
                row("Comment", text: $comment)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    onSave(
                        SeratoTrackMetadataUpdate(
                            title: title,
                            artist: artist,
                            album: album,
                            genre: genre,
                            comment: comment,
                            key: key,
                            bpm: Double(bpmText.trimmingCharacters(in: .whitespacesAndNewlines)),
                            year: Int(yearText.trimmingCharacters(in: .whitespacesAndNewlines))
                        )
                    )
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 560)
    }

    private func row(_ label: String, text: Binding<String>) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .frame(width: 80, alignment: .trailing)
                .foregroundStyle(.secondary)
            TextField(label, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func searchOnline() {
        lookupErrorMessage = nil
        isSearchingOnline = true

        Task {
            do {
                let results = try await OnlineTrackMetadataLookupService.lookup(
                    query: .init(title: title, artist: artist, album: album),
                    sourceSelection: sourceSelection
                )

                await MainActor.run {
                    lookupResults = results
                    if results.isEmpty {
                        lookupErrorMessage = "No matches found from the selected source(s)."
                    }
                    isSearchingOnline = false
                }
            } catch {
                await MainActor.run {
                    lookupResults = []
                    lookupErrorMessage = error.localizedDescription
                    isSearchingOnline = false
                }
            }
        }
    }

    private func apply(candidate: OnlineTrackMetadataCandidate) {
        if !candidate.title.isEmpty {
            title = candidate.title
        }
        if !candidate.artist.isEmpty {
            artist = candidate.artist
        }
        if !candidate.album.isEmpty {
            album = candidate.album
        }
        if !candidate.genre.isEmpty {
            genre = candidate.genre
        }
        if let year = candidate.year {
            yearText = String(year)
        }
        if let bpm = candidate.bpm {
            bpmText = String(format: "%.0f", bpm)
        }
        if !candidate.comment.isEmpty {
            comment = candidate.comment
        }
    }

    private func summary(for candidate: OnlineTrackMetadataCandidate) -> String {
        [
            candidate.artist,
            candidate.album,
            candidate.genre,
            candidate.year.map(String.init) ?? ""
        ]
        .filter { !$0.isEmpty }
        .joined(separator: " • ")
    }
}
