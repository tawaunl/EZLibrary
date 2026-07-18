import Foundation

public enum YouTubeBatchLinkImportService {
    public enum ImportError: Error, LocalizedError {
        case fileUnreadable(URL)
        case unsupportedFileType(URL)
        case unsupportedExcelFormat(URL)
        case noLinksFound
        case unzipUnavailable
        case unzipFailed(String)
        case invalidSpreadsheet(URL)

        public var errorDescription: String? {
            switch self {
            case let .fileUnreadable(url):
                return "Could not read file: \(url.lastPathComponent)."
            case let .unsupportedFileType(url):
                return "Unsupported link file type: \(url.pathExtension)."
            case let .unsupportedExcelFormat(url):
                return "Excel .xls is not supported. Save \(url.lastPathComponent) as .xlsx first."
            case .noLinksFound:
                return "No YouTube links were found in the provided input."
            case .unzipUnavailable:
                return "Could not read Excel file because the unzip utility is unavailable on this Mac."
            case let .unzipFailed(message):
                return "Could not read Excel file: \(message)"
            case let .invalidSpreadsheet(url):
                return "Could not parse spreadsheet: \(url.lastPathComponent)."
            }
        }

        public var recoverySuggestion: String? {
            switch self {
            case .fileUnreadable:
                return "Check that the file exists and is readable, then try again."
            case .unsupportedFileType:
                return "Use a .csv, .txt, or .xlsx file for batch links."
            case .unsupportedExcelFormat:
                return "Open the file in Excel and export it as .xlsx."
            case .noLinksFound:
                return "Include full YouTube links (youtube.com or youtu.be), one or more per line/cell."
            case .unzipUnavailable, .unzipFailed, .invalidSpreadsheet:
                return "Save the links as CSV and import that file instead."
            }
        }
    }

    public static func parseVideoURLs(from text: String) -> [URL] {
        let directMatches = detectURLs(in: text)
        let tokenMatches = tokenize(text).compactMap(normalizeYouTubeURL(from:))
        let combined = directMatches + tokenMatches
        return deduplicated(combined)
    }

    public static func parseVideoURLs(fromFile fileURL: URL) throws -> [URL] {
        let ext = fileURL.pathExtension.lowercased()

        let urls: [URL]
        switch ext {
        case "csv", "txt":
            let text = try readTextFile(fileURL)
            urls = parseVideoURLs(from: text)
        case "xlsx":
            let values = try extractCellValues(fromXLSX: fileURL)
            urls = parseVideoURLs(from: values.joined(separator: "\n"))
        case "xls":
            throw ImportError.unsupportedExcelFormat(fileURL)
        default:
            throw ImportError.unsupportedFileType(fileURL)
        }

        guard !urls.isEmpty else {
            throw ImportError.noLinksFound
        }

        return urls
    }

    private static func readTextFile(_ fileURL: URL) throws -> String {
        do {
            return try String(contentsOf: fileURL, encoding: .utf8)
        } catch {
            if let fallback = try? String(contentsOf: fileURL, encoding: .unicode) {
                return fallback
            }
            if let fallback = try? String(contentsOf: fileURL, encoding: .isoLatin1) {
                return fallback
            }
            throw ImportError.fileUnreadable(fileURL)
        }
    }

    private static func detectURLs(in text: String) -> [URL] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return []
        }

        let range = NSRange(location: 0, length: text.utf16.count)
        var urls: [URL] = []
        detector.enumerateMatches(in: text, options: [], range: range) { result, _, _ in
            guard let candidate = result?.url,
                  let normalized = normalizeYouTubeURL(from: candidate.absoluteString) else {
                return
            }
            urls.append(normalized)
        }

        return urls
    }

    private static func tokenize(_ text: String) -> [String] {
        let separators = CharacterSet.whitespacesAndNewlines.union(
            CharacterSet(charactersIn: ",;|\"'<>[]()")
        )
        return text
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func normalizeYouTubeURL(from rawValue: String) -> URL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let withScheme: String
        if trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://") {
            withScheme = trimmed
        } else {
            withScheme = "https://\(trimmed)"
        }

        guard let url = URL(string: withScheme),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = url.host?.lowercased(),
              host.contains("youtube.com") || host.contains("youtu.be") else {
            return nil
        }

        return url
    }

    private static func deduplicated(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        var output: [URL] = []

        for url in urls {
            let key = url.absoluteString.lowercased()
            if seen.insert(key).inserted {
                output.append(url)
            }
        }

        return output
    }

    private static func extractCellValues(fromXLSX fileURL: URL) throws -> [String] {
        let entries = try unzipListEntries(in: fileURL)
        let worksheetEntries = entries
            .filter { $0.hasPrefix("xl/worksheets/") && $0.hasSuffix(".xml") }
            .sorted()

        guard !worksheetEntries.isEmpty else {
            throw ImportError.invalidSpreadsheet(fileURL)
        }

        let sharedStrings: [String]
        if entries.contains("xl/sharedStrings.xml") {
            let xml = try unzipReadEntry("xl/sharedStrings.xml", in: fileURL)
            sharedStrings = parseSharedStrings(xmlData: xml)
        } else {
            sharedStrings = []
        }

        var collected: [String] = []
        for entry in worksheetEntries {
            let xml = try unzipReadEntry(entry, in: fileURL)
            collected.append(contentsOf: parseWorksheetCells(xmlData: xml, sharedStrings: sharedStrings))
        }

        return collected
    }

    private static func unzipListEntries(in fileURL: URL) throws -> [String] {
        let result = try runProcess(
            executable: "/usr/bin/unzip",
            arguments: ["-Z1", fileURL.path]
        )

        return result.stdout
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func unzipReadEntry(_ entry: String, in fileURL: URL) throws -> Data {
        let result = try runProcess(
            executable: "/usr/bin/unzip",
            arguments: ["-p", fileURL.path, entry],
            allowEmptyStdout: true
        )

        if result.stdoutData.isEmpty {
            return Data()
        }

        return result.stdoutData
    }

    private static func runProcess(
        executable: String,
        arguments: [String],
        allowEmptyStdout: Bool = false
    ) throws -> (stdout: String, stdoutData: Data, stderr: String) {
        let fileManager = FileManager.default
        guard fileManager.isExecutableFile(atPath: executable) else {
            throw ImportError.unzipUnavailable
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw ImportError.unzipFailed(error.localizedDescription)
        }

        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ImportError.unzipFailed(message.isEmpty ? "unzip exited with status \(process.terminationStatus)." : message)
        }

        if !allowEmptyStdout && stdoutData.isEmpty {
            throw ImportError.unzipFailed("Spreadsheet entry was empty.")
        }

        return (stdout, stdoutData, stderr)
    }

    private static func parseSharedStrings(xmlData: Data) -> [String] {
        let parser = XMLParser(data: xmlData)
        let delegate = SharedStringsXMLDelegate()
        parser.delegate = delegate
        guard parser.parse() else { return [] }
        return delegate.values
    }

    private static func parseWorksheetCells(xmlData: Data, sharedStrings: [String]) -> [String] {
        let parser = XMLParser(data: xmlData)
        let delegate = WorksheetXMLDelegate(sharedStrings: sharedStrings)
        parser.delegate = delegate
        guard parser.parse() else { return [] }
        return delegate.values
    }
}

private final class SharedStringsXMLDelegate: NSObject, XMLParserDelegate {
    private(set) var values: [String] = []
    private var isInsideText = false
    private var currentText = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if elementName == "t" {
            isInsideText = true
            currentText = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard isInsideText else { return }
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "t" {
            isInsideText = false
        } else if elementName == "si" {
            values.append(currentText.trimmingCharacters(in: .whitespacesAndNewlines))
            currentText = ""
        }
    }
}

private final class WorksheetXMLDelegate: NSObject, XMLParserDelegate {
    private let sharedStrings: [String]
    private(set) var values: [String] = []

    private var currentCellType: String?
    private var isInsideValue = false
    private var isInsideInlineText = false
    private var currentValue = ""

    init(sharedStrings: [String]) {
        self.sharedStrings = sharedStrings
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if elementName == "c" {
            currentCellType = attributeDict["t"]
            currentValue = ""
            return
        }

        if elementName == "v" {
            isInsideValue = true
            return
        }

        if elementName == "t" {
            isInsideInlineText = true
            return
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if isInsideValue || isInsideInlineText {
            currentValue += string
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "v" {
            isInsideValue = false
            return
        }

        if elementName == "t" {
            isInsideInlineText = false
            return
        }

        if elementName == "c" {
            let resolved = resolveCellValue(type: currentCellType, rawValue: currentValue)
            if let resolved, !resolved.isEmpty {
                values.append(resolved)
            }
            currentCellType = nil
            currentValue = ""
        }
    }

    private func resolveCellValue(type: String?, rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if type == "s", let index = Int(trimmed), sharedStrings.indices.contains(index) {
            return sharedStrings[index]
        }

        return trimmed
    }
}
