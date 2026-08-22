import SwiftUI
import EZLibrarySnapshotKit

// MARK: - Detail view

struct TrackDetailView: View {
    let track: SnapshotTrack

    @Environment(SnapshotStore.self) private var store
    @State private var isEditing = false

    var body: some View {
        List {
            Section {
                ForEach(TrackField.allCases, id: \.self) { field in
                    if let value = displayValue(for: field) {
                        LabeledContent(field.displayName, value: value)
                    }
                }
            }

            Section("Details") {
                if let duration = track.duration, duration > 0 {
                    LabeledContent("Length", value: formatted(duration))
                }
                if let bitrate = track.bitrate, !bitrate.isEmpty {
                    LabeledContent("Bitrate", value: bitrate)
                }
                if let plays = track.playCount {
                    LabeledContent("Plays", value: String(plays))
                }
                if let added = track.dateAdded {
                    LabeledContent("Added", value: added.formatted(date: .abbreviated, time: .omitted))
                }
            }

            Section("File") {
                Text(track.storedPath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                if track.isMissing {
                    Label("Serato couldn't find this file", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
            }
        }
        .navigationTitle(track.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Edit") { isEditing = true }
            }
        }
        .sheet(isPresented: $isEditing) {
            TrackEditView(track: track) { changes in
                for (field, newValue) in changes {
                    store.addIntent(.editTrackField(
                        storedPath: track.storedPath,
                        field: field,
                        oldValue: track.value(for: field),
                        newValue: newValue
                    ))
                }
            }
        }
    }

    private func displayValue(for field: TrackField) -> String? {
        if field == .key, let raw = track.key, !raw.isEmpty {
            return KeyFormatter.camelot(from: raw)
        }
        return track.value(for: field)
    }

    private func formatted(_ duration: TimeInterval) -> String {
        let total = Int(duration.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Edit sheet

private struct TrackEditView: View {
    let track: SnapshotTrack
    let onSave: ([TrackField: String]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var values: [TrackField: String] = [:]
    @State private var isSearching = false
    @State private var lookupResults: [AppleMusicLookup.Result] = []
    @State private var showingResults = false
    @State private var lookupError: String? = nil

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        Task { await searchAppleMusic() }
                    } label: {
                        Label("Find on Apple Music", systemImage: "music.note.list")
                    }
                    .disabled(isSearching)
                    .overlay(alignment: .trailing) {
                        if isSearching { ProgressView().padding(.trailing, 4) }
                    }

                    if let error = lookupError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                ForEach(TrackField.allCases, id: \.self) { field in
                    LabeledContent(field.displayName) {
                        TextField(
                            field.displayName,
                            text: Binding(
                                get: { values[field, default: track.value(for: field) ?? ""] },
                                set: { values[field] = $0 }
                            )
                        )
                        .multilineTextAlignment(.trailing)
                        .autocorrectionDisabled(field == .key || field == .bpm)
                    }
                }

                Section {
                    Text("Changes are queued locally and will be applied to your Serato library the next time you sync with your Mac.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Edit Track")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let changed = values.filter { field, newValue in
                            !newValue.isEmpty && newValue != (track.value(for: field) ?? "")
                        }
                        if !changed.isEmpty { onSave(changed) }
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .sheet(isPresented: $showingResults) {
                AppleMusicResultsView(results: lookupResults) { result in
                    apply(result)
                    showingResults = false
                }
            }
        }
    }

    private func searchAppleMusic() async {
        isSearching = true
        lookupError = nil
        defer { isSearching = false }

        let title = values[.title] ?? track.value(for: .title) ?? ""
        let artist = values[.artist] ?? track.value(for: .artist) ?? ""

        do {
            lookupResults = try await AppleMusicLookup.search(title: title, artist: artist)
            showingResults = true
        } catch {
            lookupError = error.localizedDescription
        }
    }

    private func apply(_ result: AppleMusicLookup.Result) {
        values[.title] = result.title
        values[.artist] = result.artistName
        if let album = result.albumTitle { values[.album] = album }
        if let genre = result.genre { values[.genre] = genre }
        if let year = result.year { values[.year] = String(year) }
    }
}

// MARK: - Results picker

private struct AppleMusicResultsView: View {
    let results: [AppleMusicLookup.Result]
    let onSelect: (AppleMusicLookup.Result) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if results.isEmpty {
                    ContentUnavailableView(
                        "No Results",
                        systemImage: "music.note",
                        description: Text("Try editing the title or artist and searching again.")
                    )
                } else {
                    List(results) { result in
                        Button { onSelect(result) } label: {
                            HStack(spacing: 12) {
                                AsyncImage(url: result.artworkURL) { image in
                                    image.resizable().aspectRatio(contentMode: .fill)
                                } placeholder: {
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(.quaternary)
                                }
                                .frame(width: 48, height: 48)
                                .clipShape(RoundedRectangle(cornerRadius: 6))

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(result.title)
                                        .font(.body)
                                        .foregroundStyle(.primary)
                                    Text(result.artistName)
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                    if let album = result.albumTitle {
                                        Text(album)
                                            .font(.caption)
                                            .foregroundStyle(.tertiary)
                                    }
                                }

                                Spacer()

                                if let year = result.year {
                                    Text(String(year))
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Apple Music Results")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
