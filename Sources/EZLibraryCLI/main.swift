// EZLibrary — an open source toolkit for Serato DJ libraries.
// Copyright (C) 2026 Tawaun Lucas
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. It is distributed WITHOUT ANY WARRANTY; see the GNU
// General Public License (LICENSE) for more details.

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
      EZLibraryCLI repair-locations [--library-dir <path>] [--search <path>]... [--apply]

    Options:
      -d, --destination <path>  Main music folder destination (default: ~/Music)
      -c, --crate-prefix <name> Dated crate prefix (default: New Music)
      -m, --mode <move|copy>    Transfer mode (default: move)
      -l, --library-dir <path>  Override Serato _Serato_ directory
      -h, --help                Show help

    repair-locations:
      Re-points Serato's SQLite library (Library/location.sqlite) at where
      files actually live now, for libraries moved by a build that only
      rewrote database V2. Previews by default; pass --apply to write.
      -s, --search <path>  Extra folder to search for the files (repeatable;
                           defaults to the folders database V2 already names)

    Example:
      EZLibraryCLI -d "$HOME/Music" -c "New Music" -- ~/Downloads/incoming ~/Desktop/track.mp3
      EZLibraryCLI repair-locations --apply
    """
    if status == 0 {
        print(usage)
    } else {
        FileHandle.standardError.write(Data((usage + "\n").utf8))
    }
    Foundation.exit(status)
}

struct RepairCLIOptions {
    var libraryDirectory: URL?
    var searchRoots: [URL] = []
    var shouldApply = false

    static func parse(arguments: [String]) throws -> RepairCLIOptions {
        var options = RepairCLIOptions()
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--help", "-h":
                printUsageAndExit(status: 0)
            case "--apply":
                options.shouldApply = true
            case "--library-dir", "-l":
                index += 1
                guard index < arguments.count else {
                    throw CLIError.invalidArgument("Missing value for --library-dir")
                }
                options.libraryDirectory = URL(fileURLWithPath: arguments[index])
            case "--search", "-s":
                index += 1
                guard index < arguments.count else {
                    throw CLIError.invalidArgument("Missing value for --search")
                }
                options.searchRoots.append(URL(fileURLWithPath: arguments[index]))
            default:
                throw CLIError.invalidArgument("Unknown option \(arguments[index])")
            }
            index += 1
        }
        return options
    }
}

func runRepairLocations(arguments: [String]) throws {
    let options = try RepairCLIOptions.parse(arguments: arguments)
    let libraryDirectory = options.libraryDirectory ?? SeratoLibraryLocator.discoverLibraryDirectory()

    print("Library: \(libraryDirectory.path)")
    let plan = try SeratoLocationRepairService.plan(
        libraryDirectory: libraryDirectory,
        searchRoots: options.searchRoots.isEmpty ? nil : options.searchRoots
    )
    print("Portable IDs are relative to: \(plan.baseDirectory.path)")
    for root in plan.searchRoots {
        print("Searched: \(root.path)")
    }
    print("Already correct: \(plan.intactCount)")
    print("Repairable: \(plan.repairs.count)")
    print("Needs review: \(plan.unrepairable.count)")

    for repair in plan.repairs.prefix(10) {
        print("  \(repair.oldPortableID)\n    -> \(repair.newPortableID)")
    }
    if plan.repairs.count > 10 {
        print("  … and \(plan.repairs.count - 10) more")
    }

    var reasonCounts: [String: Int] = [:]
    for entry in plan.unrepairable {
        switch entry.reason {
        case .noCandidate:
            reasonCounts["no matching file on disk", default: 0] += 1
        case .multipleCandidates:
            reasonCounts["several files could match", default: 0] += 1
        case .destinationTaken:
            reasonCounts["another library entry already claims that file", default: 0] += 1
        }
    }
    for (reason, count) in reasonCounts.sorted(by: { $0.value > $1.value }) {
        print("  \(count) × \(reason)")
    }

    // Disconnected locations are where "cannot be located" entries survive a
    // library move: Serato still shows them but never re-syncs them.
    let ghosts = try SeratoLocationRepairService.planDisconnectedLocations(libraryDirectory: libraryDirectory)
    print("\nDisconnected locations (master.sqlite):")
    print("  Repairable: \(ghosts.repairs.count)")
    print("  No file on disk: \(ghosts.unresolvedCount)")
    if ghosts.needsSeratoRuntimeCount > 0 {
        print("  Need renaming inside Serato: \(ghosts.needsSeratoRuntimeCount)")
    }
    for repair in ghosts.repairs.prefix(5) {
        print("  \(repair.oldPortableID)\n    -> \(repair.newPortableID)")
    }
    if ghosts.repairs.count > 5 {
        print("  … and \(ghosts.repairs.count - 5) more")
    }
    if !ghosts.isEmpty {
        print("  Note: re-pointing these leaves the same file indexed under two")
        print("        locations, which Serato shows as a duplicate.")
    }

    guard options.shouldApply else {
        print("\nPreview only. Re-run with --apply to write these changes.")
        return
    }

    let result = try SeratoLocationRepairService.apply(plan)
    print("\nRepaired \(result.repairedCount) library entries.")
    if result.skippedCount > 0 {
        print("Skipped \(result.skippedCount) whose destination was taken since the preview.")
    }

    let ghostResult = try SeratoLocationRepairService.apply(ghosts)
    print("Repaired \(ghostResult.repairedCount) entries in disconnected locations.")
}

func main() {
    do {
        let rawArguments = Array(CommandLine.arguments.dropFirst())

        if rawArguments.first == "repair-locations" {
            try runRepairLocations(arguments: Array(rawArguments.dropFirst()))
            return
        }

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
