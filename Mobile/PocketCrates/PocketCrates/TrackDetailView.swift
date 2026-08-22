import SwiftUI
import FoundationModels
import EZLibrarySnapshotKit

// MARK: - Detail view

struct TrackDetailView: View {
    let track: SnapshotTrack

    @Environment(SnapshotStore.self) private var store
    @State private var isEditing = false
    @State private var isVerifying = false
    @State private var verificationResult: AppleMusicLookup.VerificationResult? = nil
    @State private var showingVerification = false

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
                HStack {
                    if isVerifying {
                        ProgressView()
                    } else {
                        Button {
                            Task { await verifyTags() }
                        } label: {
                            Image(systemName: "checkmark.seal")
                        }
                    }
                    Button("Edit") { isEditing = true }
                }
            }
        }
        .sheet(isPresented: $showingVerification) {
            if let result = verificationResult {
                TagVerificationView(track: track, result: result) { changes in
                    for (field, newValue) in changes {
                        store.addIntent(.editTrackField(
                            track: TrackReference(snapshotTrack: track),
                            field: field,
                            oldValue: track.value(for: field),
                            newValue: newValue
                        ))
                    }
                }
            }
        }
        .sheet(isPresented: $isEditing) {
            TrackEditView(track: track) { changes in
                for (field, newValue) in changes {
                    store.addIntent(.editTrackField(
                        track: TrackReference(snapshotTrack: track),
                        field: field,
                        oldValue: track.value(for: field),
                        newValue: newValue
                    ))
                }
            }
        }
    }

    private func verifyTags() async {
        isVerifying = true
        defer { isVerifying = false }
        if let result = try? await AppleMusicLookup.verify(
            title: track.title,
            artist: track.artist,
            album: track.album,
            genre: track.genre,
            year: track.year.map(String.init) ?? ""
        ) {
            verificationResult = result
            showingVerification = true
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
    @State private var isUsingIntelligence = false
    @State private var lookupResults: [AppleMusicLookup.Result] = []
    @State private var showingResults = false
    @State private var lookupError: String? = nil
    @State private var intelligenceError: String? = nil

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        Task { await searchAppleMusic() }
                    } label: {
                        Label("Find on Apple Music", systemImage: "music.note.list")
                    }
                    .disabled(isSearching || isUsingIntelligence)
                    .overlay(alignment: .trailing) {
                        if isSearching { ProgressView().padding(.trailing, 4) }
                    }

                    if case .available = SystemLanguageModel.default.availability {
                        Button {
                            Task { await autofillWithIntelligence() }
                        } label: {
                            Label("Auto-fill with Apple Intelligence", systemImage: "sparkles")
                        }
                        .disabled(isSearching || isUsingIntelligence)
                        .overlay(alignment: .trailing) {
                            if isUsingIntelligence { ProgressView().padding(.trailing, 4) }
                        }
                    }

                    if let error = lookupError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    if let error = intelligenceError {
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

    private func autofillWithIntelligence() async {
        isUsingIntelligence = true
        intelligenceError = nil
        defer { isUsingIntelligence = false }

        let get: (TrackField) -> String = { values[$0] ?? track.value(for: $0) ?? "" }

        do {
            let suggestion = try await IntelligenceLookup.suggest(
                title: get(.title),
                artist: get(.artist),
                album: get(.album),
                genre: get(.genre),
                comment: get(.comment),
                year: get(.year)
            )
            if !suggestion.title.isEmpty  { values[.title]  = suggestion.title }
            if !suggestion.artist.isEmpty { values[.artist] = suggestion.artist }
            if !suggestion.album.isEmpty  { values[.album]  = suggestion.album }
            if !suggestion.genre.isEmpty  { values[.genre]  = suggestion.genre }
        } catch {
            intelligenceError = error.localizedDescription
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

// MARK: - Tag verification sheet

private struct TagVerificationView: View {
    let track: SnapshotTrack
    let result: AppleMusicLookup.VerificationResult
    let onFix: ([TrackField: String]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var fixes: [TrackField: String] = [:]

    private let verifiableFields: [(TrackField, String, AppleMusicLookup.FieldStatus)] = []

    var body: some View {
        NavigationStack {
            List {
                if let match = result.bestMatch {
                    Section("Matched Against") {
                        HStack(spacing: 12) {
                            AsyncImage(url: match.artworkURL) { image in
                                image.resizable().aspectRatio(contentMode: .fill)
                            } placeholder: {
                                RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                            }
                            .frame(width: 44, height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: 6))

                            VStack(alignment: .leading, spacing: 2) {
                                Text(match.title).font(.body)
                                Text(match.artistName).font(.callout).foregroundStyle(.secondary)
                                if let album = match.albumTitle {
                                    Text(album).font(.caption).foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }

                Section("Tag Status") {
                    fieldRow(.title,  "Title",  result.title)
                    fieldRow(.artist, "Artist", result.artist)
                    fieldRow(.album,  "Album",  result.album)
                    fieldRow(.genre,  "Genre",  result.genre)
                    fieldRow(.year,   "Year",   result.year)
                }

                if !fixes.isEmpty {
                    Section {
                        Text("Selected corrections will be queued as pending changes.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Tag Verification")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                if !fixes.isEmpty {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Apply \(fixes.count) Fix\(fixes.count == 1 ? "" : "es")") {
                            onFix(fixes)
                            dismiss()
                        }
                        .fontWeight(.semibold)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func fieldRow(_ field: TrackField, _ label: String, _ status: AppleMusicLookup.FieldStatus) -> some View {
        switch status {
        case .confirmed:
            HStack {
                Label(label, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Spacer()
                Text(track.value(for: field) ?? "")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }

        case .mismatch(let suggested):
            VStack(alignment: .leading, spacing: 6) {
                Label(label, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Current").font(.caption).foregroundStyle(.tertiary)
                        Text(track.value(for: field) ?? "(empty)").font(.callout)
                    }
                    Spacer()
                    Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Catalog").font(.caption).foregroundStyle(.tertiary)
                        Text(suggested).font(.callout)
                    }
                }

                let isSelected = fixes[field] == suggested
                Button {
                    if isSelected { fixes.removeValue(forKey: field) }
                    else { fixes[field] = suggested }
                } label: {
                    Label(
                        isSelected ? "Correction selected" : "Use catalog value",
                        systemImage: isSelected ? "checkmark.square.fill" : "square"
                    )
                    .font(.footnote)
                    .foregroundStyle(isSelected ? .blue : .secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 2)

        case .unverifiable:
            HStack {
                Label(label, systemImage: "minus.circle")
                    .foregroundStyle(.secondary)
                Spacer()
                Text("No catalog data").font(.caption).foregroundStyle(.tertiary)
            }
        }
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
