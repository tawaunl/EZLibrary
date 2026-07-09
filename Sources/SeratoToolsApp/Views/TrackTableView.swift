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
        case year
        case comment
        case color
        case key
        case bpm
        case duration
    }

    let tracks: [Track]
    let numberingMode: NumberingMode
    let onDeleteRequested: (([Track]) -> Void)?
    let onMetadataEditRequested: ((Track, SeratoTrackMetadataUpdate) -> Void)?
    let onSelectionChanged: (([Track]) -> Void)?
    let onTrackSingleClick: ((Track) -> Void)?
    let onTrackActivated: ((Track) -> Void)?

    @State private var searchText = ""
    @State private var selectedTrackKeys: Set<String> = []
    @State private var displayedTracks: [Track] = []
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
        onTrackActivated: ((Track) -> Void)? = nil
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
        .onDisappear {
            recomputeTask?.cancel()
            recomputeTask = nil
        }
        .onDeleteCommand {
            guard let onDeleteRequested else { return }
            let selected = displayedTracks.filter { selectedTrackKeys.contains(selectionKey(for: $0)) }
            guard !selected.isEmpty else { return }
            onDeleteRequested(selected)
        }
        .onChange(of: selectedTrackKeys) {
            notifySelectionChanged()
        }
        .onChange(of: displayedTracks.map(selectionKey(for:))) {
            notifySelectionChanged()
        }
    }

    private func notifySelectionChanged() {
        guard let onSelectionChanged else { return }
        let selected = displayedTracks.filter { selectedTrackKeys.contains(selectionKey(for: $0)) }
        onSelectionChanged(selected)
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
                let validKeys = Set(result.map(selectionKey(for:)))
                selectedTrackKeys = selectedTrackKeys.intersection(validKeys)
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

        return filtered.sorted { (lhs: Track, rhs: Track) in
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
            case .year:
                ordered = lhs.yearSortValue < rhs.yearSortValue
            case .comment:
                ordered = lhs.comment.localizedCaseInsensitiveCompare(rhs.comment) == .orderedAscending
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

    private func dragPayload(for rowIndex: Int, selectedKeys: Set<String>) -> String {
        guard rowIndex >= 0, rowIndex < displayedTracks.count else {
            return ""
        }

        let rowTrack = displayedTracks[rowIndex]
        if selectedKeys.contains(selectionKey(for: rowTrack)) {
            let selectedPaths = displayedTracks
                .filter { selectedKeys.contains(selectionKey(for: $0)) }
                .map(\.seratoStoredPath)
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

    fileprivate func selectionKey(for track: Track) -> String {
        track.seratoStoredPath
            .replacingOccurrences(of: "\\\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
    }
}

private struct TrackNSTableView: NSViewRepresentable {
    let tracks: [Track]
    @Binding var selectedTrackKeys: Set<String>
    @Binding var sortColumn: String
    @Binding var sortAscending: Bool
    let dragPayloadForRow: (_ rowIndex: Int, _ selectedKeys: Set<String>) -> String
    let onMetadataEditRequested: ((Track, SeratoTrackMetadataUpdate) -> Void)?
    let onTrackSingleClick: ((Track) -> Void)?
    let onTrackActivated: ((Track) -> Void)?

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
        table.action = #selector(Coordinator.handleSingleClick(_:))
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.handleDoubleClick(_:))
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
            ColumnDescriptor(id: "year", title: "Year", width: 70),
            ColumnDescriptor(id: "comment", title: "Comment", width: 240),
            ColumnDescriptor(id: "color", title: "Color", width: 90),
            ColumnDescriptor(id: "key", title: "Key", width: 70),
            ColumnDescriptor(id: "bpm", title: "BPM", width: 70),
            ColumnDescriptor(id: "duration", title: "Duration", width: 85)
        ]
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
        var parent: TrackNSTableView
        weak var tableView: NSTableView?
        private var applyingSortDescriptor = false
        private var lastSingleClickedSelectionKey: String?
        private let editableColumnIDs: Set<String> = ["title", "artist", "album", "genre", "year", "comment", "key", "bpm"]

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
                guard row >= 0, row < parent.tracks.count else { return nil }
                return selectionKey(for: parent.tracks[row])
            })
            parent.selectedTrackKeys = keys

            if table.selectedRowIndexes.count != 1 {
                lastSingleClickedSelectionKey = nil
            }
        }

        @objc func handleSingleClick(_ sender: Any?) {
            guard let table = tableView else {
                return
            }

            guard let event = NSApp.currentEvent,
                  event.type == .leftMouseDown || event.type == .leftMouseUp,
                  event.clickCount == 1
            else {
                return
            }

            if !event.modifierFlags.intersection([.shift, .command, .control, .option]).isEmpty {
                return
            }

            let row = table.clickedRow
            guard row >= 0,
                  row < parent.tracks.count,
                  table.selectedRowIndexes.count == 1,
                  table.selectedRowIndexes.contains(row)
            else {
                return
            }

            let track = parent.tracks[row]
            let key = selectionKey(for: track)

            if lastSingleClickedSelectionKey == key {
                let column = table.clickedColumn
                if column >= 0 {
                    let columnID = table.tableColumns[column].identifier.rawValue
                    if editableColumnIDs.contains(columnID) {
                        beginInlineEdit(row: row, column: column)
                    }
                }
            }

            lastSingleClickedSelectionKey = key
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
            guard row >= 0, row < parent.tracks.count else { return }
            lastSingleClickedSelectionKey = selectionKey(for: parent.tracks[row])
            parent.onTrackActivated?(parent.tracks[row])
        }

        private func beginInlineEdit(row: Int, column: Int) {
            guard let table = tableView,
                  row >= 0, row < parent.tracks.count,
                  column >= 0, column < table.tableColumns.count
            else { return }

            guard let cell = table.view(atColumn: column, row: row, makeIfNecessary: false) as? NSTableCellView,
                  let textField = cell.textField as? EditableTextField
            else { return }

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

        func restoreSelectionIfNeeded() {
            guard let table = tableView else { return }
            let targetIndexes = IndexSet(parent.tracks.enumerated().compactMap { index, track in
                parent.selectedTrackKeys.contains(selectionKey(for: track)) ? index : nil
            })

            guard table.selectedRowIndexes != targetIndexes else { return }

            // Avoid stealing keyboard focus from active text input controls.
            if let responder = table.window?.firstResponder, responder is NSTextView, responder !== table {
                return
            }

            table.selectRowIndexes(targetIndexes, byExtendingSelection: false)
        }

        private func selectionKey(for track: Track) -> String {
            track.seratoStoredPath
                .replacingOccurrences(of: "\\\\", with: "/")
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                .lowercased()
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

    var colorSortValue: UInt32 {
        colorCode ?? UInt32.max
    }

    var colorLabel: String {
        guard let colorCode else { return "—" }
        return String(format: "#%06X", colorCode & 0x00FF_FFFF)
    }
}
