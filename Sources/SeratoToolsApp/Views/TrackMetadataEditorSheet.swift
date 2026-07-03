import SwiftUI
import SeratoToolsCore

struct TrackMetadataEditorSheet: View {
    private enum MetadataField: String, CaseIterable, Identifiable {
        case title
        case artist
        case album
        case genre
        case year
        case bpm
        case comment

        var id: String { rawValue }

        var label: String {
            switch self {
            case .title: return "Title"
            case .artist: return "Artist"
            case .album: return "Album"
            case .genre: return "Genre"
            case .year: return "Year"
            case .bpm: return "BPM"
            case .comment: return "Comment"
            }
        }
    }

    @Environment(\.dismiss) private var dismiss

    let track: Track
    let onSave: (SeratoTrackMetadataUpdate) throws -> Void

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
    @State private var fingerprintSuggestions: [AudioFingerprintSuggestion] = []
    @State private var isSearchingOnline = false
    @State private var isScanningFingerprint = false
    @State private var lookupErrorMessage: String?
    @State private var fingerprintErrorMessage: String?
    @State private var saveErrorMessage: String?
    @State private var lockedFields: Set<MetadataField> = []

    init(track: Track, onSave: @escaping (SeratoTrackMetadataUpdate) throws -> Void) {
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

                Button("Audio Fingerprint Scan") {
                    scanFingerprint()
                }
                .disabled(isScanningFingerprint)

                if isSearchingOnline {
                    ProgressView()
                        .controlSize(.small)
                }

                if isScanningFingerprint {
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

            if let fingerprintErrorMessage {
                Text(fingerprintErrorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if let saveErrorMessage {
                Text(saveErrorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if !lookupResults.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Online Matches")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Button("Unlock All") {
                            lockedFields.removeAll()
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                    }

                    FlowLayout(spacing: 6) {
                        ForEach(MetadataField.allCases) { field in
                            lockChip(field: field)
                        }
                    }

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

                                    Button("Use All") {
                                        apply(candidate: candidate)
                                    }
                                }

                                FlowLayout(spacing: 6) {
                                    if !candidate.title.isEmpty {
                                        fieldButton("Title") { apply(field: .title, from: candidate) }
                                    }
                                    if !candidate.artist.isEmpty {
                                        fieldButton("Artist") { apply(field: .artist, from: candidate) }
                                    }
                                    if !candidate.album.isEmpty {
                                        fieldButton("Album") { apply(field: .album, from: candidate) }
                                    }
                                    if !candidate.genre.isEmpty {
                                        fieldButton("Genre") { apply(field: .genre, from: candidate) }
                                    }
                                    if candidate.year != nil {
                                        fieldButton("Year") { apply(field: .year, from: candidate) }
                                    }
                                    if candidate.bpm != nil {
                                        fieldButton("BPM") { apply(field: .bpm, from: candidate) }
                                    }
                                    if !candidate.comment.isEmpty {
                                        fieldButton("Comment") { apply(field: .comment, from: candidate) }
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                    .frame(maxHeight: 170)
                }
            }

            if !fingerprintSuggestions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("External Fingerprint Suggestions")
                        .font(.subheadline.weight(.semibold))

                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(fingerprintSuggestions, id: \.id) { suggestion in
                                HStack(alignment: .top, spacing: 10) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(suggestion.title.isEmpty ? "(untitled)" : suggestion.title)
                                            .font(.callout)

                                        Text(
                                            [
                                                suggestion.artist,
                                                suggestion.album,
                                                suggestion.provider,
                                                suggestion.confidence.map { "confidence \(Int($0.rounded()))" } ?? ""
                                            ]
                                            .filter { !$0.isEmpty }
                                            .joined(separator: " • ")
                                        )
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }

                                    Spacer(minLength: 0)

                                    Button("Use All") {
                                        apply(suggestion: suggestion)
                                    }
                                }

                                FlowLayout(spacing: 6) {
                                    if !suggestion.title.isEmpty {
                                        fieldButton("Title") { applyField(.title, value: suggestion.title) }
                                    }
                                    if !suggestion.artist.isEmpty {
                                        fieldButton("Artist") { applyField(.artist, value: suggestion.artist) }
                                    }
                                    if !suggestion.album.isEmpty {
                                        fieldButton("Album") { applyField(.album, value: suggestion.album) }
                                    }
                                    if !suggestion.genre.isEmpty {
                                        fieldButton("Genre") { applyField(.genre, value: suggestion.genre) }
                                    }
                                    if let year = suggestion.year {
                                        fieldButton("Year") { applyField(.year, value: String(year)) }
                                    }
                                    if !suggestion.comment.isEmpty {
                                        fieldButton("Comment") { applyField(.comment, value: suggestion.comment) }
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
                    do {
                        try onSave(
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
                    } catch {
                        saveErrorMessage = error.localizedDescription
                    }
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

    private func fieldButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(label, action: action)
            .buttonStyle(.bordered)
            .controlSize(.small)
    }

    private func lockChip(field: MetadataField) -> some View {
        let isLocked = lockedFields.contains(field)
        return Button {
            toggleLock(field)
        } label: {
            Label(field.label, systemImage: isLocked ? "lock.fill" : "lock.open")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help("When locked, online apply actions will not change \(field.label).")
    }

    private func toggleLock(_ field: MetadataField) {
        if lockedFields.contains(field) {
            lockedFields.remove(field)
        } else {
            lockedFields.insert(field)
        }
    }

    private func searchOnline() {
        lookupErrorMessage = nil
        saveErrorMessage = nil
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
        apply(field: .title, from: candidate)
        apply(field: .artist, from: candidate)
        apply(field: .album, from: candidate)
        apply(field: .genre, from: candidate)
        apply(field: .year, from: candidate)
        apply(field: .bpm, from: candidate)
        apply(field: .comment, from: candidate)
    }

    private func scanFingerprint() {
        isScanningFingerprint = true
        fingerprintErrorMessage = nil
        saveErrorMessage = nil

        Task {
            do {
                let suggestions = try await AudioFingerprintService.suggestMetadata(
                    for: track
                )

                await MainActor.run {
                    fingerprintSuggestions = suggestions
                    if suggestions.isEmpty {
                        fingerprintErrorMessage = "No external fingerprint suggestions were returned for this track."
                    }
                    isScanningFingerprint = false
                }
            } catch {
                await MainActor.run {
                    fingerprintSuggestions = []
                    fingerprintErrorMessage = error.localizedDescription
                    isScanningFingerprint = false
                }
            }
        }
    }

    private func apply(suggestion: AudioFingerprintSuggestion) {
        applyField(.title, value: suggestion.title)
        applyField(.artist, value: suggestion.artist)
        applyField(.album, value: suggestion.album)
        applyField(.genre, value: suggestion.genre)
        if let year = suggestion.year {
            applyField(.year, value: String(year))
        }
        applyField(.comment, value: suggestion.comment)
    }

    private func applyField(_ field: MetadataField, value: String) {
        guard !lockedFields.contains(field) else { return }
        switch field {
        case .title:
            if !value.isEmpty { title = value }
        case .artist:
            if !value.isEmpty { artist = value }
        case .album:
            if !value.isEmpty { album = value }
        case .genre:
            if !value.isEmpty { genre = value }
        case .year:
            if !value.isEmpty { yearText = value }
        case .bpm:
            if !value.isEmpty { bpmText = value }
        case .comment:
            if !value.isEmpty { comment = value }
        }
    }

    private func apply(field: MetadataField, from candidate: OnlineTrackMetadataCandidate) {
        guard !lockedFields.contains(field) else { return }

        switch field {
        case .title:
            if !candidate.title.isEmpty { title = candidate.title }
        case .artist:
            if !candidate.artist.isEmpty { artist = candidate.artist }
        case .album:
            if !candidate.album.isEmpty { album = candidate.album }
        case .genre:
            if !candidate.genre.isEmpty { genre = candidate.genre }
        case .year:
            if let year = candidate.year { yearText = String(year) }
        case .bpm:
            if let bpm = candidate.bpm { bpmText = String(format: "%.0f", bpm) }
        case .comment:
            if !candidate.comment.isEmpty { comment = candidate.comment }
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

private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var usedWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX > 0 && currentX + size.width > maxWidth {
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }

            usedWidth = max(usedWidth, currentX + size.width)
            currentX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }

        return CGSize(width: usedWidth, height: currentY + lineHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }

            subview.place(
                at: CGPoint(x: x, y: y),
                proposal: ProposedViewSize(width: size.width, height: size.height)
            )

            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
