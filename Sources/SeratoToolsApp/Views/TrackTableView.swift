import AppKit
import SwiftUI
import SeratoToolsCore

/// A sortable, searchable library-style table of tracks — shared by the
/// top-level Tracks section and crate detail views, so both look and
/// behave consistently.
struct TrackTableView: View {
    enum NumberingMode {
        case metadata
        case listOrder
    }

    private enum SortColumn: String, CaseIterable {
        case number
        case title
        case artist
        case album
        case genre
        case color
        case key
        case bpm
        case duration
    }

    let tracks: [Track]
    let numberingMode: NumberingMode
    let onDeleteRequested: (([Track]) -> Void)?

    @State private var searchText = ""
    @State private var selectedTrackIDs: Set<Track.ID> = []
    @State private var displayedTracks: [Track] = []
    @State private var displayedPathByID: [Track.ID: String] = [:]
    @State private var recomputeTask: Task<Void, Never>?
    @State private var sortColumn: SortColumn = .number
    @State private var sortAscending = true

    init(
        tracks: [Track],
        numberingMode: NumberingMode = .metadata,
        onDeleteRequested: (([Track]) -> Void)? = nil
    ) {
        self.tracks = tracks
        self.numberingMode = numberingMode
        self.onDeleteRequested = onDeleteRequested
    }

    var body: some View {
        VStack(spacing: 8) {
            TextField("Search title, artist, genre...", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 8)
                .padding(.top, 8)
                .onTapGesture {
                    NSApp.activate(ignoringOtherApps: true)
                }

            TrackNSTableView(
                tracks: displayedTracks,
                selectedTrackIDs: $selectedTrackIDs,
                sortColumn: Binding(
                    get: { sortColumn.rawValue },
                    set: { newValue in
                        sortColumn = SortColumn(rawValue: newValue) ?? .number
                    }
                ),
                sortAscending: $sortAscending,
                dragPayloadForRow: { rowIndex, selectedIDs in
                    dragPayload(for: rowIndex, selectedIDs: selectedIDs)
                }
            )
        }
        .onAppear {
            scheduleRecompute()
        }
        .onChange(of: searchText) {
            scheduleRecompute(debounce: true)
        }
        .onChange(of: sortColumn) {
            scheduleRecompute()
        }
        .onChange(of: sortAscending) {
            scheduleRecompute()
        }
        .onChange(of: numberingMode) {
            scheduleRecompute()
        }
        .onChange(of: tracks.count) {
            scheduleRecompute()
        }
        .onChange(of: tracks.first?.id) {
            scheduleRecompute()
        }
        .onChange(of: tracks.last?.id) {
            scheduleRecompute()
        }
        .onDisappear {
            recomputeTask?.cancel()
            recomputeTask = nil
        }
        .onDeleteCommand {
            guard let onDeleteRequested else { return }
            let selected = displayedTracks.filter { selectedTrackIDs.contains($0.id) }
            guard !selected.isEmpty else { return }
            onDeleteRequested(selected)
        }
    }

    private func scheduleRecompute(debounce: Bool = false) {
        recomputeTask?.cancel()

        let inputTracks = tracks
        let inputSearchText = searchText
        let inputSortColumn = sortColumn
        let inputSortAscending = sortAscending
        let inputNumberingMode = numberingMode

        recomputeTask = Task(priority: .userInitiated) {
            if debounce {
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
            guard !Task.isCancelled else { return }

            let result = await Self.computeDisplayedTracksAsync(
                tracks: inputTracks,
                numberingMode: inputNumberingMode,
                searchText: inputSearchText,
                sortColumn: inputSortColumn,
                sortAscending: inputSortAscending
            )

            guard !Task.isCancelled else { return }
            await MainActor.run {
                displayedTracks = result
                displayedPathByID = Dictionary(
                    uniqueKeysWithValues: result.map { ($0.id, $0.seratoStoredPath) }
                )
                let validIDs = Set(result.map(\.id))
                selectedTrackIDs = selectedTrackIDs.intersection(validIDs)
            }
        }
    }

    nonisolated private static func computeDisplayedTracksAsync(
        tracks: [Track],
        numberingMode: NumberingMode,
        searchText: String,
        sortColumn: SortColumn,
        sortAscending: Bool
    ) async -> [Track] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Self.computeDisplayedTracks(
                    tracks: tracks,
                    numberingMode: numberingMode,
                    searchText: searchText,
                    sortColumn: sortColumn,
                    sortAscending: sortAscending
                )
                continuation.resume(returning: result)
            }
        }
    }

    nonisolated private static func computeDisplayedTracks(
        tracks: [Track],
        numberingMode: NumberingMode,
        searchText: String,
        sortColumn: SortColumn,
        sortAscending: Bool
    ) -> [Track] {
        let sourceTracks: [Track]
        switch numberingMode {
        case .metadata:
            sourceTracks = tracks
        case .listOrder:
            sourceTracks = tracks.enumerated().map { index, track in
                var track = track
                track.trackNumber = index + 1
                return track
            }
        }

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let queryLower = query.lowercased()
        let filtered = queryLower.isEmpty ? sourceTracks : sourceTracks.filter { track in
            track.title.lowercased().contains(queryLower)
                || track.artist.lowercased().contains(queryLower)
                || track.genre.lowercased().contains(queryLower)
                || track.album.lowercased().contains(queryLower)
        }

        return filtered.sorted { lhs, rhs in
            let ordered: Bool
            switch sortColumn {
            case .number:
                ordered = lhs.numberSortValue < rhs.numberSortValue
            case .title:
                ordered = lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            case .artist:
                ordered = lhs.artist.localizedCaseInsensitiveCompare(rhs.artist) == .orderedAscending
            case .album:
                ordered = lhs.album.localizedCaseInsensitiveCompare(rhs.album) == .orderedAscending
            case .genre:
                ordered = lhs.genre.localizedCaseInsensitiveCompare(rhs.genre) == .orderedAscending
            case .color:
                ordered = lhs.colorSortValue < rhs.colorSortValue
            case .key:
                ordered = lhs.keySortValue.localizedCaseInsensitiveCompare(rhs.keySortValue) == .orderedAscending
            case .bpm:
                ordered = lhs.bpmSortValue < rhs.bpmSortValue
            case .duration:
                ordered = lhs.durationSortValue < rhs.durationSortValue
            }
            return sortAscending ? ordered : !ordered
        }
    }

    private func dragPayload(for rowIndex: Int, selectedIDs: Set<Track.ID>) -> String {
        guard rowIndex >= 0, rowIndex < displayedTracks.count else {
            return ""
        }

        let rowTrack = displayedTracks[rowIndex]
        if selectedIDs.contains(rowTrack.id) {
            let selectedPaths = selectedIDs.compactMap { displayedPathByID[$0] }
            if !selectedPaths.isEmpty {
                return TrackDragPayload.encodeMany(paths: selectedPaths)
            }
        }

        return TrackDragPayload.encode(path: rowTrack.seratoStoredPath)
    }

    fileprivate static func formattedBPM(_ bpm: Double?) -> String {
        guard let bpm else { return "—" }
        return String(format: "%.0f", bpm)
    }

    fileprivate static func formattedDuration(_ duration: TimeInterval?) -> String {
        guard let duration, duration > 0 else { return "—" }
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

private struct TrackNSTableView: NSViewRepresentable {
    let tracks: [Track]
    @Binding var selectedTrackIDs: Set<Track.ID>
    @Binding var sortColumn: String
    @Binding var sortAscending: Bool
    let dragPayloadForRow: (_ rowIndex: Int, _ selectedIDs: Set<Track.ID>) -> String

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView(frame: .zero)
        table.allowsMultipleSelection = true
        table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.intercellSpacing = NSSize(width: 6, height: 4)
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        table.registerForDraggedTypes([.string])
        table.setDraggingSourceOperationMask(.copy, forLocal: false)

        for descriptor in ColumnDescriptor.all {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(descriptor.id))
            column.title = descriptor.title
            column.width = descriptor.width
            column.minWidth = descriptor.width
            column.sortDescriptorPrototype = NSSortDescriptor(key: descriptor.id, ascending: true)
            table.addTableColumn(column)
        }

        let scrollView = NSScrollView(frame: .zero)
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.documentView = table

        context.coordinator.tableView = table
        context.coordinator.applySortDescriptor(columnID: sortColumn, ascending: sortAscending)

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let table = context.coordinator.tableView else { return }

        context.coordinator.applySortDescriptor(columnID: sortColumn, ascending: sortAscending)
        table.reloadData()
        context.coordinator.restoreSelectionIfNeeded()
    }

    private struct ColumnDescriptor {
        let id: String
        let title: String
        let width: CGFloat

        static let all: [ColumnDescriptor] = [
            ColumnDescriptor(id: "number", title: "#", width: 50),
            ColumnDescriptor(id: "title", title: "Title", width: 280),
            ColumnDescriptor(id: "artist", title: "Artist", width: 190),
            ColumnDescriptor(id: "album", title: "Album", width: 190),
            ColumnDescriptor(id: "genre", title: "Genre", width: 150),
            ColumnDescriptor(id: "color", title: "Color", width: 90),
            ColumnDescriptor(id: "key", title: "Key", width: 70),
            ColumnDescriptor(id: "bpm", title: "BPM", width: 70),
            ColumnDescriptor(id: "duration", title: "Duration", width: 85)
        ]
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: TrackNSTableView
        weak var tableView: NSTableView?
        private var applyingSortDescriptor = false

        init(parent: TrackNSTableView) {
            self.parent = parent
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            parent.tracks.count
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard row >= 0, row < parent.tracks.count, let tableColumn else { return nil }
            let track = parent.tracks[row]
            let identifier = NSUserInterfaceItemIdentifier("Cell_\(tableColumn.identifier.rawValue)")

            let cell: NSTableCellView
            if let reused = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView,
               let textField = reused.textField {
                cell = reused
                textField.stringValue = Self.stringValue(for: track, columnID: tableColumn.identifier.rawValue)
            } else {
                let newCell = NSTableCellView(frame: .zero)
                newCell.identifier = identifier
                let textField = NSTextField(labelWithString: Self.stringValue(for: track, columnID: tableColumn.identifier.rawValue))
                textField.translatesAutoresizingMaskIntoConstraints = false
                textField.lineBreakMode = .byTruncatingTail
                newCell.addSubview(textField)
                newCell.textField = textField
                NSLayoutConstraint.activate([
                    textField.leadingAnchor.constraint(equalTo: newCell.leadingAnchor, constant: 4),
                    textField.trailingAnchor.constraint(equalTo: newCell.trailingAnchor, constant: -4),
                    textField.centerYAnchor.constraint(equalTo: newCell.centerYAnchor)
                ])
                cell = newCell
            }

            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let table = tableView else { return }
            let ids = Set<Track.ID>(table.selectedRowIndexes.compactMap { row in
                guard row >= 0, row < parent.tracks.count else { return nil }
                return parent.tracks[row].id
            })
            parent.selectedTrackIDs = ids
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !applyingSortDescriptor, let first = tableView.sortDescriptors.first, let key = first.key else { return }
            parent.sortColumn = key
            parent.sortAscending = first.ascending
        }

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
            let payload = parent.dragPayloadForRow(row, parent.selectedTrackIDs)
            if payload.isEmpty {
                return nil
            }
            return NSString(string: payload)
        }

        func restoreSelectionIfNeeded() {
            guard let table = tableView else { return }
            let targetIndexes = IndexSet(parent.tracks.enumerated().compactMap { index, track in
                parent.selectedTrackIDs.contains(track.id) ? index : nil
            })

            guard table.selectedRowIndexes != targetIndexes else { return }

            // Avoid stealing keyboard focus from active text input controls.
            if let responder = table.window?.firstResponder, responder is NSTextView, responder !== table {
                return
            }

            table.selectRowIndexes(targetIndexes, byExtendingSelection: false)
        }

        func applySortDescriptor(columnID: String, ascending: Bool) {
            guard let table = tableView else { return }
            applyingSortDescriptor = true
            table.sortDescriptors = [NSSortDescriptor(key: columnID, ascending: ascending)]
            applyingSortDescriptor = false
        }

        private static func stringValue(for track: Track, columnID: String) -> String {
            switch columnID {
            case "number":
                return track.trackNumber.map(String.init) ?? "—"
            case "title":
                return track.title
            case "artist":
                return track.artist
            case "album":
                return track.album
            case "genre":
                return track.genre
            case "color":
                return track.colorLabel
            case "key":
                return track.key ?? "—"
            case "bpm":
                return TrackTableView.formattedBPM(track.bpm)
            case "duration":
                return TrackTableView.formattedDuration(track.duration)
            default:
                return ""
            }
        }
    }
}

private extension Track {
    var numberSortValue: Int {
        trackNumber ?? Int.max
    }

    var keySortValue: String {
        key ?? ""
    }

    var bpmSortValue: Double {
        bpm ?? -1
    }

    var durationSortValue: TimeInterval {
        duration ?? -1
    }

    var colorSortValue: UInt32 {
        colorCode ?? UInt32.max
    }

    var colorLabel: String {
        guard let colorCode else { return "—" }
        return String(format: "#%06X", colorCode & 0x00FF_FFFF)
    }
}
