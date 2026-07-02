import Foundation

enum TrackDragPayload {
    private static let prefix = "seratotools-track-path:"

    static func encode(path: String) -> String {
        "\(prefix)\(path)"
    }

    static func decode(_ value: String) -> String? {
        guard value.hasPrefix(prefix) else { return nil }
        return String(value.dropFirst(prefix.count))
    }

    static func decodeMany(_ value: String) -> [String] {
        value
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { decode(String($0)) }
    }

    static func encodeMany(paths: [String]) -> String {
        paths
            .map(encode(path:))
            .joined(separator: "\n")
    }
}
