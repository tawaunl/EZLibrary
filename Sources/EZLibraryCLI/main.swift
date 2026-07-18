import Foundation
import EZLibraryCore

enum CLIError: Error, LocalizedError {
    case invalidArgument(String)

    var errorDescription: String? {
        switch self {
        case let .invalidArgument(message):
            return message
        }
    }
}

struct ImportCLIOptions {
    var destinationFolderURL: URL
    var cratePrefix: String
    var transferMode: AddMusicImportService.TransferMode
    var libraryDirectory: URL?
    var inputURLs: [URL]

    static func parse(arguments: [String]) throws -> ImportCLIOptions {
        var destination = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music", isDirectory: true)
        var cratePrefix = "New Music"
        var transferMode: AddMusicImportService.TransferMode = .move
        var libraryDirectory: URL?
        var inputs: [URL] = []

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]

            switch argument {
            case "--help", "-h":
                printUsageAndExit(status: 0)
            case "--destination", "-d":
                index += 1
                guard index < arguments.count else {
                    throw CLIError.invalidArgument("Missing value for --destination")
                }
                destination = URL(fileURLWithPath: arguments[index])
            case "--crate-prefix", "-c":
                index += 1
                guard index < arguments.count else {
                    throw CLIError.invalidArgument("Missing value for --crate-prefix")
                }
                cratePrefix = arguments[index]
            case "--mode", "-m":
                index += 1
                guard index < arguments.count else {
                    throw CLIError.invalidArgument("Missing value for --mode")
                }
                guard let parsed = AddMusicImportService.TransferMode(rawValue: arguments[index].lowercased()) else {
                    throw CLIError.invalidArgument("Invalid --mode value \(arguments[index]). Use move or copy.")
                }
                transferMode = parsed
            case "--library-dir", "-l":
                index += 1
                guard index < arguments.count else {
                    throw CLIError.invalidArgument("Missing value for --library-dir")
                }
                libraryDirectory = URL(fileURLWithPath: arguments[index])
            case "--":
                let remainder = Array(arguments[(index + 1)...])
                inputs.append(contentsOf: remainder.map(URL.init(fileURLWithPath:)))
                index = arguments.count
                continue
            default:
                if argument.hasPrefix("-") {
                    throw CLIError.invalidArgument("Unknown option \(argument)")
                }
                inputs.append(URL(fileURLWithPath: argument))
            }

            index += 1
        }

        guard !inputs.isEmpty else {
            throw CLIError.invalidArgument("No input files/folders provided.")
        }

        return ImportCLIOptions(
            destinationFolderURL: destination,
            cratePrefix: cratePrefix,
            transferMode: transferMode,
            libraryDirectory: libraryDirectory,
            inputURLs: inputs
        )
    }
}

func printUsageAndExit(status: Int32) -> Never {
    let usage = """
    Usage:
      EZLibraryCLI [options] <file-or-folder> [more files/folders...]

    Options:
      -d, --destination <path>  Main music folder destination (default: ~/Music)
      -c, --crate-prefix <name> Dated crate prefix (default: New Music)
      -m, --mode <move|copy>    Transfer mode (default: move)
      -l, --library-dir <path>  Override Serato _Serato_ directory
      -h, --help                Show help

    Example:
      EZLibraryCLI -d "$HOME/Music" -c "New Music" -- ~/Downloads/incoming ~/Desktop/track.mp3
    """
    if status == 0 {
        print(usage)
    } else {
        FileHandle.standardError.write(Data((usage + "\n").utf8))
    }
    Foundation.exit(status)
}

func main() {
    do {
        let rawArguments = Array(CommandLine.arguments.dropFirst())
        let options = try ImportCLIOptions.parse(arguments: rawArguments)

        let resolvedLibraryDirectory: URL
        if let libraryDirectory = options.libraryDirectory {
            resolvedLibraryDirectory = libraryDirectory
        } else {
            resolvedLibraryDirectory = SeratoLibraryLocator.discoverLibraryDirectory()
        }

        let subcratesDirectory = SeratoLibraryLocator.subcratesDirectory(in: resolvedLibraryDirectory)
        let rootDirectory = SeratoLibraryLocator.rootDirectory(for: resolvedLibraryDirectory)

        let result = try AddMusicImportService.importIntoDatedCrate(
            inputURLs: options.inputURLs,
            destinationFolderURL: options.destinationFolderURL,
            crateNamePrefix: options.cratePrefix,
            transferMode: options.transferMode,
            subcratesDirectory: subcratesDirectory,
            rootDirectory: rootDirectory
        )

        print("Imported \(result.importedTrackCount) tracks")
        print("Destination: \(result.destinationFolderURL.path)")
        print("Crate: \(result.crateName)")
        print("Crate File: \(result.crateFileURL.path)")
    } catch {
        FileHandle.standardError.write(Data(("Error: \(error.localizedDescription)\n").utf8))
        if let recovery = (error as? LocalizedError)?.recoverySuggestion {
            FileHandle.standardError.write(Data(("Suggestion: \(recovery)\n").utf8))
        }
        printUsageAndExit(status: 1)
    }
}

main()