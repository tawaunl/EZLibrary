import AppKit
import SwiftUI
import EZLibraryCore

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
        case year
        case comment
        case color
        case key
        case bpm
        case duration
        case playCount
    }

    let tracks: [Track]
    let numberingMode: NumberingMode
    let onDeleteRequested: (([Track]) -> Void)?
    let onMetadataEditRequested: ((Track, SeratoTrackMetadataUpdate) -> Void)?
    let onSelectionChanged: (([Track]) -> Void)?
    let onTrackSingleClick: ((Track) -> Void)?
    let onTrackActivated: ((Track, [Track]) -> Void)?

    @State private var searchText = ""
    @State private var selectedTrackKeys: Set<String> = []
    @State private var displayedTracks: [Track] = []
    /// Selection key per row of `displayedTracks`, computed once alongside
    /// it (off the main thread) — deriving the key per track per selection
    /// change did three string transforms across the whole table on every
    /// click.
    @State private var displayedKeys: [String] = []
    @State private var recomputeTask: Task<Void, Never>?
    @State private var sortColumn: SortColumn = .number
    @State private var sortAscending = true

    init(
        tracks: [Track],
        numberingMode: NumberingMode = .metadata,
        onDeleteRequested: (([Track]) -> Void)? = nil,
        onMetadataEditRequested: ((Track, SeratoTrackMetadataUpdate) -> Void)? = nil,
        onSelectionChanged: (([Track]) -> Void)? = nil,
        onTrackSingleClick: ((Track) -> Void)? = nil,
        onTrackActivated: ((Track, [Track]) -> Void)? = nil
    ) {
        self.tracks = tracks
        self.numberingMode = numberingMode
        self.onDeleteRequested = onDeleteRequested
        self.onMetadataEditRequested = onMetadataEditRequested
        self.onSelectionChanged = onSelectionChanged
        self.onTrackSingleClick = onTrackSingleClick
        self.onTrackActivated = onTrackActivated
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
                trackKeys: displayedKeys,
                selectedTrackKeys: $selectedTrackKeys,
                sortColumn: Binding(
                    get: { sortColumn.rawValue },
                    set: { newValue in
                        sortColumn = SortColumn(rawValue: newValue) ?? .number
                    }
                ),
                sortAscending: $sortAscending,
                dragPayloadForRow: { rowIndex, selectedKeys in
                    dragPayload(for: rowIndex, selectedKeys: selectedKeys)
                },
                onMetadataEditRequested: onMetadataEditRequested,
                onTrackSingleClick: onTrackSingleClick,
                onTrackActivated: onTrackActivated
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
        .onChange(of: playCountSignature) {
            scheduleRecompute()
        }
        .onDisappear {
            recomputeTask?.cancel()
            recomputeTask = nil
        }
        .onDeleteCommand {
            guard let onDeleteRequested else { return }
            let selected = selectedDisplayedTracks()
            guard !selected.isEmpty else { return }
            onDeleteRequested(selected)
        }
        .onChange(of: selectedTrackKeys) {
            notifySelectionChanged()
        }
        .onChange(of: displayedTracks) {
            notifySelectionChanged()
        }
    }

    private func notifySelectionChanged() {
        guard let onSelectionChanged else { return }
        onSelectionChanged(selectedDisplayedTracks())
    }

    /// A cheap value that changes whenever any track's play count changes, used
    /// to trigger a recompute when background play-count loading fills them in
    /// (the track identities and count stay the same, so the other `onChange`
    /// hooks wouldn't notice).
    private var playCountSignature: Int {
        var sum = 0
        for track in tracks {
            sum = sum &+ (track.playCount ?? 0)
        }
        return sum
    }

    private func selectedDisplayedTracks() -> [Track] {
        zip(displayedTracks, displayedKeys).compactMap { track, key in
            selectedTrackKeys.contains(key) ? track : nil
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
                displayedTracks = result.tracks
                displayedKeys = result.keys
                selectedTrackKeys = selectedTrackKeys.intersection(Set(result.keys))
            }
        }
    }

    nonisolated private static func computeDisplayedTracksAsync(
        tracks: [Track],
        numberingMode: NumberingMode,
        searchText: String,
        sortColumn: SortColumn,
        sortAscending: Bool
    ) async -> (tracks: [Track], keys: [String]) {
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
    ) -> (tracks: [Track], keys: [String]) {
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

        // Descending swaps the operands rather than negating the ascending
        // result: `!ordered` returned `true` for equal elements on both
        // orderings, which violates strict weak ordering and gives
        // `sorted(by:)` undefined behavior.
        let sorted = filtered.sorted { lhs, rhs in
            sortAscending
                ? areInIncreasingOrder(lhs, rhs, by: sortColumn)
                : areInIncreasingOrder(rhs, lhs, by: sortColumn)
        }
        return (sorted, sorted.map(selectionKey(for:)))
    }

    nonisolated private static func areInIncreasingOrder(_ lhs: Track, _ rhs: Track, by sortColumn: SortColumn) -> Bool {
        switch sortColumn {
        case .number:
            return lhs.numberSortValue < rhs.numberSortValue
        case .title:
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        case .artist:
            return lhs.artist.localizedCaseInsensitiveCompare(rhs.artist) == .orderedAscending
        case .album:
            return lhs.album.localizedCaseInsensitiveCompare(rhs.album) == .orderedAscending
        case .genre:
            return lhs.genre.localizedCaseInsensitiveCompare(rhs.genre) == .orderedAscending
        case .year:
            return lhs.yearSortValue < rhs.yearSortValue
        case .comment:
            return lhs.comment.localizedCaseInsensitiveCompare(rhs.comment) == .orderedAscending
        case .color:
            return lhs.colorSortValue < rhs.colorSortValue
        case .key:
            return lhs.keySortValue.localizedCaseInsensitiveCompare(rhs.keySortValue) == .orderedAscending
        case .bpm:
            return lhs.bpmSortValue < rhs.bpmSortValue
        case .duration:
            return lhs.durationSortValue < rhs.durationSortValue
        case .playCount:
            return lhs.playCountSortValue < rhs.playCountSortValue
        }
    }

    private func dragPayload(for rowIndex: Int, selectedKeys: Set<String>) -> String {
        guard rowIndex >= 0, rowIndex < displayedTracks.count else {
            return ""
        }

        let rowTrack = displayedTracks[rowIndex]
        if rowIndex < displayedKeys.count, selectedKeys.contains(displayedKeys[rowIndex]) {
            let selectedPaths = zip(displayedTracks, displayedKeys)
                .filter { selectedKeys.contains($0.1) }
                .map(\.0.seratoStoredPath)
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

    fileprivate static func formattedPlayCount(_ playCount: Int?) -> String {
        guard let playCount else { return "—" }
        return String(playCount)
    }

    nonisolated fileprivate static func selectionKey(for track: Track) -> String {
        track.seratoStoredPath
            .replacingOccurrences(of: "\\\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
    }
}

private struct TrackNSTableView: NSViewRepresentable {
    let tracks: [Track]
    /// Selection key per row of `tracks`, precomputed by the parent so the
    /// coordinator never re-derives keys during selection syncs.
    let trackKeys: [String]
    @Binding var selectedTrackKeys: Set<String>
    @Binding var sortColumn: String
    @Binding var sortAscending: Bool
    let dragPayloadForRow: (_ rowIndex: Int, _ selectedKeys: Set<String>) -> String
    let onMetadataEditRequested: ((Track, SeratoTrackMetadataUpdate) -> Void)?
    let onTrackSingleClick: ((Track) -> Void)?
    let onTrackActivated: ((Track, [Track]) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView(frame: .zero)
        table.allowsMultipleSelection = true
        table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.allowsColumnReordering = true
        table.allowsColumnResizing = true
        table.intercellSpacing = NSSize(width: 6, height: 4)
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.handleDoubleClick(_:))
        table.registerForDraggedTypes([.string])
        table.setDraggingSourceOperationMask(.copy, forLocal: false)

        for descriptor in ColumnDescriptor.all {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(descriptor.id))
            column.title = descriptor.title
            column.width = descriptor.width
            column.minWidth = descriptor.width
            if descriptor.isSortable {
                column.sortDescriptorPrototype = NSSortDescriptor(key: descriptor.id, ascending: true)
            }
            table.addTableColumn(column)
        }

        let scrollView = NSScrollView(frame: .zero)
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.documentView = table

        // Persist the user's column order and widths across launches. Set after
        // the columns are added so autosave reconciles saved state with them.
        table.autosaveName = "SeratoTracksTable"
        table.autosaveTableColumns = true

        context.coordinator.tableView = table
        context.coordinator.applySortDescriptor(columnID: sortColumn, ascending: sortAscending)

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard context.coordinator.tableView != nil else { return }

        context.coordinator.applySortDescriptor(columnID: sortColumn, ascending: sortAscending)
        context.coordinator.syncTracksAndSelectionIfNeeded()
    }

    private struct ColumnDescriptor {
        let id: String
        let title: String
        let width: CGFloat
        let isSortable: Bool

        static let all: [ColumnDescriptor] = [
            ColumnDescriptor(id: "play", title: "", width: 34, isSortable: false),
            ColumnDescriptor(id: "number", title: "#", width: 50, isSortable: true),
            ColumnDescriptor(id: "title", title: "Title", width: 280, isSortable: true),
            ColumnDescriptor(id: "artist", title: "Artist", width: 190, isSortable: true),
            ColumnDescriptor(id: "album", title: "Album", width: 190, isSortable: true),
            ColumnDescriptor(id: "genre", title: "Genre", width: 150, isSortable: true),
            ColumnDescriptor(id: "year", title: "Year", width: 70, isSortable: true),
            ColumnDescriptor(id: "comment", title: "Comment", width: 240, isSortable: true),
            ColumnDescriptor(id: "color", title: "Color", width: 90, isSortable: true),
            ColumnDescriptor(id: "key", title: "Key", width: 70, isSortable: true),
            ColumnDescriptor(id: "bpm", title: "BPM", width: 70, isSortable: true),
            ColumnDescriptor(id: "duration", title: "Duration", width: 85, isSortable: true),
            ColumnDescriptor(id: "playCount", title: "Plays", width: 70, isSortable: true)
        ]
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
        var parent: TrackNSTableView
        weak var tableView: NSTableView?
        private var applyingSortDescriptor = false
        private let editableColumnIDs: Set<String> = ["title", "artist", "album", "genre", "year", "comment", "key", "bpm"]
        // Last tracks/selection actually applied to the table, so
        // `updateNSView` (called on every SwiftUI update pass of this
        // representable, not just when data changes) can skip `reloadData()`
        // and the O(n) `restoreSelectionIfNeeded()` scan when neither
        // changed since the last sync.
        private var lastAppliedTracks: [Track] = []
        private var lastAppliedSelectionKeys: Set<String> = []

        init(parent: TrackNSTableView) {
            self.parent = parent
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            parent.tracks.count
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard row >= 0, row < parent.tracks.count, let tableColumn else { return nil }
            let track = parent.tracks[row]
            let columnID = tableColumn.identifier.rawValue

            if columnID == "play" {
                let identifier = NSUserInterfaceItemIdentifier("Cell_play")
                let cell: NSTableCellView
                let button: NSButton

                if let reused = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView,
                   let existingButton = reused.subviews.compactMap({ $0 as? NSButton }).first {
                    cell = reused
                    button = existingButton
                } else {
                    let newCell = NSTableCellView(frame: .zero)
                    newCell.identifier = identifier

                    let newButton = NSButton(frame: .zero)
                    newButton.translatesAutoresizingMaskIntoConstraints = false
                    newButton.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Play Track")
                    newButton.isBordered = false
                    newButton.contentTintColor = NSColor.controlAccentColor
                    newButton.target = self
                    newButton.action = #selector(handlePlayButton(_:))
                    newButton.toolTip = "Preview this track in the audio player."

                    newCell.addSubview(newButton)
                    NSLayoutConstraint.activate([
                        newButton.centerXAnchor.constraint(equalTo: newCell.centerXAnchor),
                        newButton.centerYAnchor.constraint(equalTo: newCell.centerYAnchor)
                    ])

                    cell = newCell
                    button = newButton
                }

                button.tag = row
                return cell
            }

            let identifier = NSUserInterfaceItemIdentifier("Cell_\(columnID)")
            let allowsInlineEdit = editableColumnIDs.contains(columnID)

            let cell: NSTableCellView
            if let reused = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView,
               let textField = reused.textField as? EditableTextField {
                cell = reused
                textField.stringValue = Self.stringValue(for: track, columnID: columnID)
                textField.rowIndex = row
                textField.columnID = columnID
                textField.isEditable = false
                textField.isSelectable = allowsInlineEdit
            } else {
                let newCell = NSTableCellView(frame: .zero)
                newCell.identifier = identifier
                let textField = EditableTextField(labelWithString: Self.stringValue(for: track, columnID: columnID))
                textField.translatesAutoresizingMaskIntoConstraints = false
                textField.lineBreakMode = .byTruncatingTail
                textField.rowIndex = row
                textField.columnID = columnID
                textField.isEditable = false
                textField.isSelectable = allowsInlineEdit
                textField.delegate = self
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
            let keys = Set<String>(table.selectedRowIndexes.compactMap { row in
                guard row >= 0, row < parent.trackKeys.count else { return nil }
                return parent.trackKeys[row]
            })
            parent.selectedTrackKeys = keys
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !applyingSortDescriptor, let first = tableView.sortDescriptors.first, let key = first.key else { return }
            parent.sortColumn = key
            parent.sortAscending = first.ascending
        }

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
            let payload = parent.dragPayloadForRow(row, parent.selectedTrackKeys)
            if payload.isEmpty {
                return nil
            }
            return NSString(string: payload)
        }

        @objc func handleDoubleClick(_ sender: Any?) {
            guard let table = tableView else { return }
            let row = table.clickedRow
            let column = table.clickedColumn
            guard row >= 0, row < parent.tracks.count, column >= 0 else { return }

            let columnID = table.tableColumns[column].identifier.rawValue
            guard editableColumnIDs.contains(columnID) else { return }
            beginInlineEdit(row: row, column: column)
        }

        @objc func handlePlayButton(_ sender: NSButton) {
            guard sender.tag >= 0, sender.tag < parent.tracks.count else { return }
            guard let table = tableView else { return }

            let row = sender.tag
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            parent.onTrackActivated?(parent.tracks[row], parent.tracks)
        }

        private func beginInlineEdit(row: Int, column: Int) {
            guard let table = tableView,
                  row >= 0, row < parent.tracks.count,
                  column >= 0, column < table.tableColumns.count
            else { return }

            guard let cell = table.view(atColumn: column, row: row, makeIfNecessary: false) as? NSTableCellView,
                  let textField = cell.textField as? EditableTextField
            else { return }

            // The title cell shows the filename as a display-only fallback when a
            // track has no ID3 title. Start editing from the real (possibly empty)
            // value so pressing return without typing doesn't persist the filename.
            if textField.columnID == "title" {
                textField.stringValue = parent.tracks[row].title
            }

            textField.isEditable = true
            table.window?.makeFirstResponder(textField)
            textField.currentEditor()?.selectAll(nil)
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            guard let textField = obj.object as? EditableTextField else { return }
            defer { textField.isEditable = false }

            let row = textField.rowIndex
            guard row >= 0, row < parent.tracks.count else { return }

            let track = parent.tracks[row]
            let edited = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

            var metadata = SeratoTrackMetadataUpdate(
                title: track.title,
                artist: track.artist,
                album: track.album,
                genre: track.genre,
                comment: track.comment,
                key: track.key ?? "",
                bpm: track.bpm,
                year: track.year
            )

            switch textField.columnID {
            case "title":
                metadata.title = edited
            case "artist":
                metadata.artist = edited
            case "album":
                metadata.album = edited
            case "genre":
                metadata.genre = edited
            case "year":
                metadata.year = Int(edited)
            case "comment":
                metadata.comment = edited
            case "key":
                metadata.key = edited
            case "bpm":
                metadata.bpm = Double(edited)
            default:
                return
            }

            parent.onMetadataEditRequested?(track, metadata)
        }

        /// Applies `parent.tracks`/`parent.selectedTrackKeys` to the table
        /// only when they actually differ from what's already shown, so
        /// SwiftUI update passes unrelated to this table (e.g. typing
        /// elsewhere in the window) don't pay for a full `reloadData()`.
        func syncTracksAndSelectionIfNeeded() {
            guard let table = tableView else { return }

            if tracksDiffer(from: parent.tracks) {
                lastAppliedTracks = parent.tracks
                table.reloadData()
                restoreSelectionIfNeeded()
                lastAppliedSelectionKeys = parent.selectedTrackKeys
            } else if lastAppliedSelectionKeys != parent.selectedTrackKeys {
                lastAppliedSelectionKeys = parent.selectedTrackKeys
                restoreSelectionIfNeeded()
            }
        }

        /// Detects when the rows need re-rendering. `Track`'s `==` only compares
        /// identity, so background play-count updates (same ids, new counts)
        /// wouldn't otherwise be picked up here.
        private func tracksDiffer(from new: [Track]) -> Bool {
            if lastAppliedTracks.count != new.count { return true }
            for index in new.indices {
                if lastAppliedTracks[index].id != new[index].id { return true }
                if lastAppliedTracks[index].playCount != new[index].playCount { return true }
            }
            return false
        }

        func restoreSelectionIfNeeded() {
            guard let table = tableView else { return }
            let targetIndexes = IndexSet(parent.trackKeys.enumerated().compactMap { index, key in
                parent.selectedTrackKeys.contains(key) ? index : nil
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
            case "play":
                return ""
            case "number":
                return track.trackNumber.map(String.init) ?? "—"
            case "title":
                // Fall back to the filename (without extension) when a track has
                // no ID3 title, so rows aren't blank. This is display-only; the
                // underlying empty title is used when editing (see beginInlineEdit).
                let trimmedTitle = track.title.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmedTitle.isEmpty {
                    return track.fileURL.deletingPathExtension().lastPathComponent
                }
                return track.title
            case "artist":
                return track.artist
            case "album":
                return track.album
            case "genre":
                return track.genre
            case "year":
                return track.year.map(String.init) ?? "—"
            case "comment":
                return track.comment
            case "color":
                return track.colorLabel
            case "key":
                return track.key ?? "—"
            case "bpm":
                return TrackTableView.formattedBPM(track.bpm)
            case "duration":
                return TrackTableView.formattedDuration(track.duration)
            case "playCount":
                return TrackTableView.formattedPlayCount(track.playCount)
            default:
                return ""
            }
        }
    }
}

private final class EditableTextField: NSTextField {
    var rowIndex: Int = -1
    var columnID: String = ""
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

    var yearSortValue: Int {
        year ?? Int.min
    }

    var durationSortValue: TimeInterval {
        duration ?? -1
    }

    var playCountSortValue: Int {
        playCount ?? -1
    }

    var colorSortValue: UInt32 {
        colorCode ?? UInt32.max
    }

    var colorLabel: String {
        guard let colorCode else { return "—" }
        return String(format: "#%06X", colorCode & 0x00FF_FFFF)
    }
}
