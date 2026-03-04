import Foundation
import Darwin

enum NotesMatrixCLI {
    struct InteractiveState {
        var outputPath: String
        var mode: ExportMode
        var includeAttachments: Bool
        var existingPolicy: ExistingItemPolicy
        var filenameMode: FilenameMode
        var incremental: Bool
        var lastScanCount: Int?
        var lastRunMessage: String?
    }

    static func run() throws {
        if CommandLine.arguments.count > 1 {
            try runNonInteractive(args: Array(CommandLine.arguments.dropFirst()))
        } else {
            try runInteractive()
        }
    }

    static func runInteractive() throws {
        normalizeTerminalMode()
        defer { normalizeTerminalMode() }

        let defaultOutput = NSHomeDirectory() + "/Desktop/NotesExport"
        var state = InteractiveState(
            outputPath: defaultOutput,
            mode: .folderTree,
            includeAttachments: false,
            existingPolicy: .overwrite,
            filenameMode: .unicodeSafe,
            incremental: false,
            lastScanCount: nil,
            lastRunMessage: nil
        )
        var selectedAction = 0

        while true {
            normalizeTerminalMode()
            drawDashboard(state: state, selectedAction: selectedAction)
            switch readDashboardKey() {
            case .up, .left:
                selectedAction = (selectedAction - 1 + dashboardActions.count) % dashboardActions.count
            case .down, .right:
                selectedAction = (selectedAction + 1) % dashboardActions.count
            case .digit(let n):
                if (1...dashboardActions.count).contains(n) {
                    selectedAction = n - 1
                    let shouldExit = try runDashboardAction(index: selectedAction, state: &state)
                    if shouldExit { return }
                }
            case .enter:
                let shouldExit = try runDashboardAction(index: selectedAction, state: &state)
                if shouldExit { return }
            case .quit, .cancel:
                print(ANSI.paint("Bye.", ANSI.dim))
                return
            case .other:
                continue
            }
        }
    }

    private static let dashboardActions: [String] = [
        "Set Output Path",
        "Select Export Mode (tree/zip)",
        "Select Attachments Mode (fast/deep)",
        "Select Existing Item Policy",
        "Select Filename Mode (unicode/ascii)",
        "Select Incremental Mode (off/on)",
        "Run Export",
        "Help",
        "Exit"
    ]

    private static func runDashboardAction(index: Int, state: inout InteractiveState) throws -> Bool {
        switch index {
        case 0:
            print(ANSI.paint("New output path >", ANSI.brightGreen), terminator: " ")
            if let path = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
                state.outputPath = path
                state.lastRunMessage = "Output path updated"
            }
        case 1:
            if let selected = promptSelectExportMode(current: state.mode) {
                state.mode = selected
                state.lastRunMessage = "Mode set to \(state.mode.rawValue)"
            } else {
                state.lastRunMessage = "Mode selection cancelled"
            }
        case 2:
            if let selected = promptSelectAttachmentsMode(current: state.includeAttachments) {
                state.includeAttachments = selected
                state.lastRunMessage = state.includeAttachments
                    ? "Attachments mode set to deep"
                    : "Attachments mode set to fast"
            } else {
                state.lastRunMessage = "Attachments selection cancelled"
            }
        case 3:
            if let selected = promptSelectExistingPolicy(current: state.existingPolicy) {
                state.existingPolicy = selected
                state.lastRunMessage = "Existing item policy: \(selected.rawValue)"
            } else {
                state.lastRunMessage = "Existing item policy selection cancelled"
            }
        case 4:
            if let selected = promptSelectFilenameMode(current: state.filenameMode) {
                state.filenameMode = selected
                state.lastRunMessage = "Filename mode: \(selected.rawValue)"
            } else {
                state.lastRunMessage = "Filename mode selection cancelled"
            }
        case 5:
            if let selected = promptSelectIncrementalMode(current: state.incremental) {
                state.incremental = selected
                state.lastRunMessage = "Incremental mode: \(selected ? "on" : "off")"
            } else {
                state.lastRunMessage = "Incremental mode selection cancelled"
            }
        case 6:
            do {
                try interactiveExport(
                    mode: state.mode,
                    outputPath: state.outputPath,
                    includeAttachments: state.includeAttachments,
                    existingPolicy: state.existingPolicy,
                    filenameMode: state.filenameMode,
                    incremental: state.incremental
                )
                state.lastRunMessage = "Export completed"
                pausePrompt()
            } catch {
                state.lastRunMessage = "Export failed: \(error)"
                pausePrompt()
            }
        case 7:
            printInteractiveHelp()
            pausePrompt()
        case 8:
            print(ANSI.paint("Bye.", ANSI.dim))
            return true
        default:
            state.lastRunMessage = "Unknown action"
        }
        return false
    }

    static func runInteractiveScan() throws -> Int {
        print(ANSI.paint("[stage] 1/2 searching notes...", ANSI.green))
        print(ANSI.paint("Processing: requesting Notes data via osascript...", ANSI.green))
        print(ANSI.paint("[hint] if this is first run, approve macOS Automation permission for Notes.", ANSI.dim))
        let started = Date()
        let notes = try AppleNotesProvider().loadNotes(mode: .scan)
        let elapsed = String(format: "%.2f", Date().timeIntervalSince(started))
        print(ANSI.paint("[done] read completed in \(elapsed)s", ANSI.green))
        print(ANSI.paint("Found \(notes.count) notes.", ANSI.brightGreen))
        printSample(notes)
        return notes.count
    }

    static func interactiveExport(
        mode: ExportMode,
        outputPath: String,
        includeAttachments: Bool,
        existingPolicy: ExistingItemPolicy,
        filenameMode: FilenameMode,
        incremental: Bool
    ) throws {
        let overallStarted = Date()
        let output = URL(fileURLWithPath: outputPath, isDirectory: true)
        print(ANSI.paint("Export started:", ANSI.cyan))
        print(ANSI.paint("[stage] 1/2 searching notes...", ANSI.green))
        print(ANSI.paint("Processing: requesting Notes data via osascript...", ANSI.green))
        print(ANSI.paint("[hint] if no output appears, check for a hidden macOS permission dialog.", ANSI.dim))

        let provider = AppleNotesProvider()
        let readStarted = Date()
        let notes: [ExportNote]
        var metadataForManifest: [ExportNote]?
        if incremental {
            let metadata = try provider.loadNotes(mode: .scan)
            metadataForManifest = metadata
            let manifestURL = manifestURL(for: output)
            let previousManifest = loadManifest(at: manifestURL)
            let context = IncrementalContext(
                includeAttachments: includeAttachments,
                filenameMode: filenameMode,
                mode: mode
            )
            let changedMetadata = changedNotes(metadata: metadata, manifest: previousManifest, context: context)
            if changedMetadata.isEmpty {
                print(ANSI.paint("[done] no changed notes detected; export skipped", ANSI.green))
                saveManifest(from: metadata, context: context, to: manifestURL)
                return
            }
            print(ANSI.paint("[incremental] changed notes: \(changedMetadata.count)/\(metadata.count)", ANSI.cyan))
            notes = try provider.loadNotesContent(from: changedMetadata, includeAttachments: includeAttachments)
        } else {
            notes = try provider.loadNotes(mode: .fullExport, includeAttachments: includeAttachments)
        }
        let readElapsed = String(format: "%.2f", Date().timeIntervalSince(readStarted))
        print(ANSI.paint("[done] read \(notes.count) notes in \(readElapsed)s", ANSI.green))
        print(ANSI.paint("[stage] 2/2 exporting markdown files...", ANSI.green))

        let result = try MarkdownExporter().export(
            notes,
            to: output,
            mode: mode,
            existingPolicy: existingPolicy,
            filenameMode: filenameMode
        )
        let totalElapsed = String(format: "%.2f", Date().timeIntervalSince(overallStarted))
        print(ANSI.paint("[done] export completed in \(totalElapsed)s (total)", ANSI.green))
        printSummary(result)

        if incremental {
            let manifestURL = manifestURL(for: output)
            let context = IncrementalContext(
                includeAttachments: includeAttachments,
                filenameMode: filenameMode,
                mode: mode
            )
            saveManifest(from: metadataForManifest ?? [], context: context, to: manifestURL)
        }
    }

    static func runNonInteractive(args: [String]) throws {
        switch args.first {
        case "scan":
            print(ANSI.paint("[stage] 1/2 searching notes...", ANSI.green))
            print(ANSI.paint("Processing: requesting Notes data via osascript...", ANSI.green))
            let started = Date()
            let notes = try AppleNotesProvider().loadNotes(mode: .scan)
            let elapsed = String(format: "%.2f", Date().timeIntervalSince(started))
            print(ANSI.paint("[done] read completed in \(elapsed)s", ANSI.green))
            print("notes: \(notes.count)")
            printSample(notes)
        case "export":
            let overallStarted = Date()
            let output = parseFlag("--output", args: args) ?? FileManager.default.currentDirectoryPath
            let zipEnabled = args.contains("--zip")
            let includeAttachments = args.contains("--with-attachments")
            let incremental = args.contains("--incremental")
            let existingPolicy = parseFlag("--on-existing", args: args).flatMap { ExistingItemPolicy(rawValue: $0) } ?? .overwrite
            let filenameMode = parseFlag("--filename-mode", args: args).flatMap { FilenameMode(rawValue: $0) } ?? .unicodeSafe
            let mode: ExportMode = zipEnabled ? .zip : .folderTree
            print(ANSI.paint("Export started:", ANSI.cyan))
            print(ANSI.paint("[stage] 1/2 searching notes...", ANSI.green))
            print(ANSI.paint("Processing: requesting Notes data via osascript...", ANSI.green))
            if !includeAttachments {
                print("[mode] fast export (attachments skipped, source.html kept)")
            }
            let provider = AppleNotesProvider()
            let readStarted = Date()
            let notes: [ExportNote]
            var metadataForManifest: [ExportNote]?
            if incremental {
                let metadata = try provider.loadNotes(mode: .scan)
                metadataForManifest = metadata
                let manifestURL = manifestURL(for: URL(fileURLWithPath: output, isDirectory: true))
                let previousManifest = loadManifest(at: manifestURL)
                let context = IncrementalContext(
                    includeAttachments: includeAttachments,
                    filenameMode: filenameMode,
                    mode: mode
                )
                let changedMetadata = changedNotes(metadata: metadata, manifest: previousManifest, context: context)
                if changedMetadata.isEmpty {
                    print(ANSI.paint("[done] no changed notes detected; export skipped", ANSI.green))
                    saveManifest(from: metadata, context: context, to: manifestURL)
                    return
                }
                print("[incremental] changed notes: \(changedMetadata.count)/\(metadata.count)")
                notes = try provider.loadNotesContent(from: changedMetadata, includeAttachments: includeAttachments)
            } else {
                notes = try provider.loadNotes(mode: .fullExport, includeAttachments: includeAttachments)
            }
            let readElapsed = String(format: "%.2f", Date().timeIntervalSince(readStarted))
            print(ANSI.paint("[done] read \(notes.count) notes in \(readElapsed)s", ANSI.green))
            print(ANSI.paint("[stage] 2/2 exporting markdown files...", ANSI.green))
            let result = try MarkdownExporter().export(
                notes,
                to: URL(fileURLWithPath: output, isDirectory: true),
                mode: mode,
                existingPolicy: existingPolicy,
                filenameMode: filenameMode
            )
            let totalElapsed = String(format: "%.2f", Date().timeIntervalSince(overallStarted))
            print(ANSI.paint("[done] export completed in \(totalElapsed)s (total)", ANSI.green))
            printSummary(result)
            if incremental {
                let context = IncrementalContext(
                    includeAttachments: includeAttachments,
                    filenameMode: filenameMode,
                    mode: mode
                )
                saveManifest(from: metadataForManifest ?? [], context: context, to: manifestURL(for: URL(fileURLWithPath: output, isDirectory: true)))
            }
        case "help", "--help", "-h":
            printHelp()
        default:
            printHelp()
        }
    }

    static func parseFlag(_ key: String, args: [String]) -> String? {
        guard let idx = args.firstIndex(of: key), idx + 1 < args.count else { return nil }
        return args[idx + 1]
    }

    static func printSample(_ notes: [ExportNote]) {
        for note in notes.prefix(5) {
            let path = ([note.account] + note.folderPath).joined(separator: "/")
            print(" - \(path) :: \(note.title)")
        }
        if notes.count > 5 {
            print(" ... and \(notes.count - 5) more")
        }
    }

    static func printSummary(_ result: ExportResult) {
        print("")
        print(ANSI.paint("EXPORT COMPLETE", ANSI.brightGreen))
        print("mode: \(result.mode.rawValue)")
        print("notes: \(result.notesCount)")
        print("destination: \(result.destination.path)")
    }

    static func drawDashboard(state: InteractiveState, selectedAction: Int) {
        if supportsAnsiTerminal() { clearScreen() }
        printMatrixHeader()
        print(ANSI.paint("OPERATIONS", ANSI.cyan))
        for (idx, action) in dashboardActions.enumerated() {
            if idx == selectedAction {
                print(ANSI.paint("  > \(action)", ANSI.brightGreen))
            } else {
                print(ANSI.paint("    \(action)", ANSI.green))
            }
        }
        print("")
        print(ANSI.paint("CURRENT CONFIG", ANSI.cyan))
        print("  output: \(state.outputPath)")
        print("  export: \(state.mode.rawValue)")
        print("  attachments: \(state.includeAttachments ? "deep (slower, max extraction)" : "fast (recommended)")")
        print("  existing targets: \(state.existingPolicy.rawValue) (\(state.existingPolicy.summary))")
        print("  filename mode: \(state.filenameMode.rawValue) (\(state.filenameMode.summary))")
        print("  incremental: \(state.incremental ? "on (changed notes only)" : "off (full export)")")
        if let count = state.lastScanCount {
            print("  last scan: \(count) notes")
        }
        if let msg = state.lastRunMessage {
            print(ANSI.paint("  status: \(msg)", ANSI.yellow))
        }
        print("")
        print(ANSI.paint("Tips: use 'fast' for daily export, 'deep' for full attachment pull.", ANSI.dim))
        print(ANSI.paint("maintainer: @darthlogic", ANSI.dim))
        print(ANSI.paint("Navigate: ↑/↓ move, Enter run selected, q exit. Fallback: w/s or action number.", ANSI.dim))
    }

    static func printInteractiveHelp() {
        print("")
        print(ANSI.paint("HELP", ANSI.cyan))
        print(ANSI.paint("  1) Set Output Path", ANSI.green))
        print("     Directory where export output will be written.")
        print("     Output is always created inside: <output>/notes-export")
        print("")
        print(ANSI.paint("  2) Select Export Mode (tree/zip)", ANSI.green))
        print("     Opens a selector for export format:")
        print("     - tree: standard folder tree with .md files")
        print("     - zip: same structure, also packed into notes-export.zip")
        print("")
        print(ANSI.paint("  3) Select Attachments Mode (fast/deep)", ANSI.green))
        print("     - fast (recommended): faster, keeps .source.html as reliable fallback")
        print("     - deep: attempts full binary attachment/graphics extraction (slower)")
        print("")
        print(ANSI.paint("  4) Select Existing Item Policy", ANSI.green))
        print("     Controls behavior when target file/folder already exists:")
        print("     - overwrite: replace/reuse existing targets (default)")
        print("     - skip: do nothing for conflicting targets")
        print("     - uniquify: create new names with suffix (-1, -2, ...)")
        print("")
        print(ANSI.paint("  5) Select Filename Mode (unicode/ascii)", ANSI.green))
        print("     Controls cross-platform filename behavior:")
        print("     - unicode: keep Cyrillic/Unicode names, sanitize safely")
        print("     - ascii: transliterate names to ASCII for max Windows portability")
        print("")
        print(ANSI.paint("  6) Select Incremental Mode (off/on)", ANSI.green))
        print("     - off (default): read and export all notes")
        print("     - on: compare with manifest and export only changed notes")
        print("")
        print(ANSI.paint("  7) Run Export", ANSI.green))
        print("     Runs export using current settings (path/mode/attachments).")
        print("")
        print(ANSI.paint("  8) Help", ANSI.green))
        print("     Opens this help screen.")
        print("")
        print(ANSI.paint("  9) Exit", ANSI.green))
        print("     Exits the application.")
        print("")
        print(ANSI.paint("  Diagnostic:", ANSI.yellow) + " quick scan is available in CLI: `notes-matrix scan`")
        print(ANSI.paint("  Tip:", ANSI.yellow) + " for regular backups, use fast + tree.")
        print(ANSI.paint("  Maintainer:", ANSI.yellow) + " @darthlogic")
        print(ANSI.paint("  Navigation:", ANSI.yellow) + " use ↑/↓ and Enter in selectors (q = cancel).")
    }

    static func promptSelectExportMode(current: ExportMode) -> ExportMode? {
        let options = ["tree", "zip"]
        let currentIndex = (current == .folderTree) ? 0 : 1
        guard let selected = promptArrowMenu(
            title: "SELECT EXPORT MODE",
            current: current.rawValue,
            options: options,
            initialIndex: currentIndex
        ) else { return nil }
        return selected == 0 ? .folderTree : .zip
    }

    static func promptSelectAttachmentsMode(current: Bool) -> Bool? {
        let options = ["fast (recommended)", "deep"]
        let currentIndex = current ? 1 : 0
        guard let selected = promptArrowMenu(
            title: "SELECT ATTACHMENTS MODE",
            current: current ? "deep" : "fast",
            options: options,
            initialIndex: currentIndex
        ) else { return nil }
        return selected == 1
    }

    static func promptSelectExistingPolicy(current: ExistingItemPolicy) -> ExistingItemPolicy? {
        let options = ["overwrite (default)", "skip", "uniquify"]
        let currentIndex: Int = {
            switch current {
            case .overwrite: return 0
            case .skip: return 1
            case .uniquify: return 2
            }
        }()
        guard let selected = promptArrowMenu(
            title: "SELECT EXISTING ITEM POLICY",
            current: current.rawValue,
            options: options,
            initialIndex: currentIndex
        ) else { return nil }
        switch selected {
        case 0: return .overwrite
        case 1: return .skip
        default: return .uniquify
        }
    }

    static func promptSelectFilenameMode(current: FilenameMode) -> FilenameMode? {
        let options = ["unicode (recommended)", "ascii (transliteration)"]
        let currentIndex = (current == .unicodeSafe) ? 0 : 1
        guard let selected = promptArrowMenu(
            title: "SELECT FILENAME MODE",
            current: current.rawValue,
            options: options,
            initialIndex: currentIndex
        ) else { return nil }
        return selected == 0 ? .unicodeSafe : .asciiTranslit
    }

    static func promptSelectIncrementalMode(current: Bool) -> Bool? {
        let options = ["off (full export)", "on (changed notes only)"]
        let currentIndex = current ? 1 : 0
        guard let selected = promptArrowMenu(
            title: "SELECT INCREMENTAL MODE",
            current: current ? "on" : "off",
            options: options,
            initialIndex: currentIndex
        ) else { return nil }
        return selected == 1
    }

    private enum MenuKey {
        case up
        case down
        case left
        case right
        case enter
        case digit(Int)
        case quit
        case cancel
        case other
    }

    private static func promptArrowMenu(
        title: String,
        current: String,
        options: [String],
        initialIndex: Int
    ) -> Int? {
        guard !options.isEmpty else { return nil }
        if !supportsAnsiTerminal() {
            return promptTextMenu(title: title, current: current, options: options)
        }

        // Selection cursor: 0..<options.count are options, options.count is Back button.
        var selected = max(0, min(initialIndex, options.count - 1))
        let backIndex = options.count
        while true {
            clearScreen()
            printMatrixHeader()
            print("")
            print("")
            print(ANSI.paint(title, ANSI.cyan))
            let backLabel = "[← Back to menu]"
            if selected == backIndex {
                print(ANSI.paint(" > \(backLabel)", ANSI.brightCyan))
            } else {
                print(ANSI.paint("   \(backLabel)", ANSI.dim))
            }
            print("")
            print("current: \(current)")
            for (idx, option) in options.enumerated() {
                let marker = idx == selected ? ">" : " "
                let color = idx == selected ? ANSI.brightGreen : ANSI.green
                print(ANSI.paint(" \(marker) \(idx + 1)) \(option)", color))
            }
            print(ANSI.paint("Enter = choose selected, arrows/w/s move, q/b = back", ANSI.dim))

            switch readMenuKey() {
            case .up, .left:
                selected = (selected - 1 + options.count + 1) % (options.count + 1)
            case .down, .right:
                selected = (selected + 1) % (options.count + 1)
            case .digit(let n):
                if n == 0 { return nil }
                if (1...options.count).contains(n) { return n - 1 }
            case .enter:
                if selected == backIndex { return nil }
                return selected
            case .quit, .cancel:
                return nil
            case .other:
                continue
            }
        }
    }

    private static func promptTextMenu(
        title: String,
        current: String,
        options: [String]
    ) -> Int? {
        print("\r")
        print("\r" + ANSI.paint(title, ANSI.cyan))
        print("\rcurrent: \(current)")
        var selected = 0
        while true {
            for (idx, option) in options.enumerated() {
                let marker = idx == selected ? ">" : " "
                let color = idx == selected ? ANSI.brightGreen : ANSI.green
                print("\r" + ANSI.paint(" \(marker) \(idx + 1)) \(option)", color))
            }
            print("\r" + ANSI.paint("  Enter = choose selected, arrows/w/s move, q = cancel", ANSI.dim))
            print("\r" + ANSI.paint("  0) Back", ANSI.dim))
            print("\r" + ANSI.paint("Mode >", ANSI.brightGreen), terminator: " ")
            let input = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            if input.isEmpty { return selected }
            if input == "q" || input == "quit" || input == "cancel" || input == "b" || input == "back" || input == "0" { return nil }
            if let nav = parseLineNavigation(input), nav != 0 {
                if nav < 0 {
                    for _ in 0..<abs(nav) { selected = (selected - 1 + options.count) % options.count }
                } else {
                    for _ in 0..<nav { selected = (selected + 1) % options.count }
                }
                print("\r")
                print("\r" + ANSI.paint(title, ANSI.cyan))
                print("\rcurrent: \(current)")
                continue
            }
            if input == "w" || input == "k" || input == "up" {
                selected = (selected - 1 + options.count) % options.count
                print("\r")
                print("\r" + ANSI.paint(title, ANSI.cyan))
                print("\rcurrent: \(current)")
                continue
            }
            if input == "s" || input == "j" || input == "down" {
                selected = (selected + 1) % options.count
                print("\r")
                print("\r" + ANSI.paint(title, ANSI.cyan))
                print("\rcurrent: \(current)")
                continue
            }
            if let asNumber = Int(input), (1...options.count).contains(asNumber) {
                return asNumber - 1
            }
            for (idx, option) in options.enumerated() {
                let token = option.split(separator: " ").first.map(String.init)?.lowercased() ?? option.lowercased()
                if input == token {
                    return idx
                }
            }
            return nil
        }
    }

    private static func readMenuKey() -> MenuKey {
        var ch: UInt8 = 0
        let n = withNonCanonicalInput { read(STDIN_FILENO, &ch, 1) }
        if n != 1 { return .other }

        if ch == 10 || ch == 13 { return .enter }
        if ch == 3 { return .quit } // Ctrl+C
        if ch == 113 || ch == 81 { return .cancel } // q / Q
        if ch == 98 || ch == 66 { return .cancel } // b / B
        if ch == 119 || ch == 107 || ch == 87 || ch == 75 { return .up }   // w/k
        if ch == 115 || ch == 106 || ch == 83 || ch == 74 { return .down } // s/j
        if ch >= 48 && ch <= 57 { return .digit(Int(ch - 48)) }             // 0...9

        if ch == 27 {
            var next: UInt8 = 0
            if withNonCanonicalInput({ read(STDIN_FILENO, &next, 1) }) == 1, next == 91 {
                var arrow: UInt8 = 0
                if withNonCanonicalInput({ read(STDIN_FILENO, &arrow, 1) }) == 1 {
                    if arrow == 65 { return .up }
                    if arrow == 66 { return .down }
                    if arrow == 67 { return .right }
                    if arrow == 68 { return .left }
                }
            }
            return .other
        }
        return .other
    }

    private static func renderHorizontalSelector(options: [String], selected: Int) -> String {
        let labels = options.map { "[ ] \($0)" }
        let maxLen = labels.map(\.count).max() ?? 0
        return options.enumerated().map { idx, option in
            let marker = idx == selected ? "[x]" : "[ ]"
            let raw = "\(marker) \(option)"
            let padded = raw.padding(toLength: maxLen + 2, withPad: " ", startingAt: 0)
            return ANSI.paint(padded, idx == selected ? ANSI.brightGreen : ANSI.cyan)
        }.joined(separator: " ")
    }

    private static func readDashboardKey() -> MenuKey {
        var ch: UInt8 = 0
        let n = withNonCanonicalInput { read(STDIN_FILENO, &ch, 1) }
        if n != 1 { return .other }

        if ch == 10 || ch == 13 { return .enter }
        if ch == 3 { return .quit } // Ctrl+C
        if ch == 113 || ch == 81 { return .quit } // q / Q
        if ch == 119 || ch == 107 || ch == 87 || ch == 75 { return .up }   // w/k
        if ch == 115 || ch == 106 || ch == 83 || ch == 74 { return .down } // s/j
        if ch >= 49 && ch <= 57 { return .digit(Int(ch - 48)) }             // 1...9

        if ch == 27 {
            var next: UInt8 = 0
            if withNonCanonicalInput({ read(STDIN_FILENO, &next, 1) }) == 1, next == 91 {
                var arrow: UInt8 = 0
                if withNonCanonicalInput({ read(STDIN_FILENO, &arrow, 1) }) == 1 {
                    if arrow == 65 { return .up }
                    if arrow == 66 { return .down }
                    if arrow == 67 { return .right }
                    if arrow == 68 { return .left }
                }
            }
            return .other
        }
        return .other
    }

    static func pausePrompt() {
        print("")
        print(ANSI.paint("Press Enter to continue...", ANSI.dim), terminator: "")
        _ = readLine()
    }

    static func printHelp() {
        print(
            """
            notes-matrix - Apple Notes exporter

            Usage:
              notes-matrix                  # interactive matrix-like TUI
              notes-matrix scan
              notes-matrix help
              notes-matrix export --output /path/to/dir [--zip] [--with-attachments] [--on-existing overwrite|skip|uniquify] [--filename-mode unicode|ascii] [--incremental]

            Commands:
              scan
                Diagnostic metadata scan (no export). CLI-only.

              export
                Export notes to Markdown using current flags.

              help
                Show this help message.

            TUI operations:
              1) Set Output Path
              2) Select Export Mode (tree/zip)
              3) Select Attachments Mode (fast/deep)
              4) Select Existing Item Policy
              5) Select Filename Mode (unicode/ascii)
              6) Select Incremental Mode (off/on)
              7) Run Export
              8) Help
              9) Exit
              Navigation: ↑/↓ move, Enter select, q exit.

            Options (for export):
              --output <path>
                Target directory. Result goes to <path>/notes-export.

              --zip
                Also create notes-export.zip.

              --with-attachments
                Enable deep binary attachment extraction (slower).
                By default, fast mode is used.

              --on-existing overwrite|skip|uniquify
                overwrite  replace/reuse existing targets (default)
                skip       do nothing on conflicts
                uniquify   create new names with suffixes (-1, -2, ...)

              --filename-mode unicode|ascii
                unicode    keep Unicode/Cyrillic names (default)
                ascii      transliterate names to ASCII

              --incremental
                Export only changed notes using local manifest cache.
                First run exports all notes.

            Examples:
              notes-matrix export --output ~/Desktop/NotesExport
              notes-matrix export --output ~/Desktop/NotesExport --zip
              notes-matrix export --output ~/Desktop/NotesExport --with-attachments --on-existing skip
              notes-matrix export --output ~/Desktop/NotesExport --filename-mode ascii
              notes-matrix export --output ~/Desktop/NotesExport --with-attachments --incremental

            Notes:
              - On first run macOS will ask Automation permission for Notes.
              - Export writes Markdown files and local assets.
              - Fast mode skips deep attachment extraction but keeps raw HTML snapshot.
            """
        )
    }

    struct ManifestEntry: Codable {
        let id: String
        let updatedAt: String?
        let account: String
        let folderPath: [String]
        let title: String
    }

    struct ExportManifest: Codable {
        let version: Int
        let includeAttachments: Bool
        let filenameMode: FilenameMode
        let mode: ExportMode
        let notes: [ManifestEntry]
    }

    struct IncrementalContext {
        let includeAttachments: Bool
        let filenameMode: FilenameMode
        let mode: ExportMode
    }

    static func manifestURL(for output: URL) -> URL {
        output.appendingPathComponent(".notes-matrix-manifest.json")
    }

    static func loadManifest(at url: URL) -> ExportManifest? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ExportManifest.self, from: data)
    }

    static func saveManifest(from notes: [ExportNote], context: IncrementalContext, to url: URL) {
        let manifest = ExportManifest(
            version: 1,
            includeAttachments: context.includeAttachments,
            filenameMode: context.filenameMode,
            mode: context.mode,
            notes: notes.map { note in
                ManifestEntry(
                    id: note.id,
                    updatedAt: note.updatedAt,
                    account: note.account,
                    folderPath: note.folderPath,
                    title: note.title
                )
            }
        )

        do {
            let dir = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(manifest)
            try data.write(to: url, options: .atomic)
        } catch {
            fputs("warning: failed to update incremental manifest at \(url.path)\n", stderr)
        }
    }

    static func changedNotes(
        metadata: [ExportNote],
        manifest: ExportManifest?,
        context: IncrementalContext
    ) -> [ExportNote] {
        guard let manifest else { return metadata }
        guard manifest.version == 1,
              manifest.includeAttachments == context.includeAttachments,
              manifest.filenameMode == context.filenameMode,
              manifest.mode == context.mode else {
            return metadata
        }

        let previousByID = Dictionary(uniqueKeysWithValues: manifest.notes.map { ($0.id, $0) })
        return metadata.filter { note in
            guard let previous = previousByID[note.id] else { return true }
            if previous.updatedAt != note.updatedAt { return true }
            if previous.account != note.account { return true }
            if previous.folderPath != note.folderPath { return true }
            if previous.title != note.title { return true }
            return false
        }
    }

    private static func supportsAnsiTerminal() -> Bool {
        guard isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1 else { return false }
        let term = ProcessInfo.processInfo.environment["TERM"]?.lowercased() ?? ""
        if term.isEmpty || term == "dumb" { return false }
        return true
    }

    private static func normalizeTerminalMode() {
        guard isatty(STDIN_FILENO) == 1 else { return }
        var t = termios()
        guard tcgetattr(STDIN_FILENO, &t) == 0 else { return }

        t.c_iflag |= tcflag_t(ICRNL | IXON | BRKINT)
        t.c_oflag |= tcflag_t(OPOST | ONLCR)
        t.c_cflag |= tcflag_t(CREAD)
        t.c_lflag |= tcflag_t(ICANON | ECHO | ISIG | IEXTEN)
        t.c_cc.16 = 1 // VMIN
        t.c_cc.17 = 0 // VTIME

        _ = tcsetattr(STDIN_FILENO, TCSANOW, &t)
    }

    private static func parseLineNavigation(_ input: String) -> Int? {
        // Supports terminals that pass arrows as literal text:
        // ESC[A / ESC[B, ^[[A / ^[[B, and repeated sequences.
        let upTokens = ["\u{1B}[A", "^[ [a", "^[[a", "^[[A", "[A", "esc[a", "\\e[A"]
        let downTokens = ["\u{1B}[B", "^[ [b", "^[[b", "^[[B", "[B", "esc[b", "\\e[B"]

        var up = 0
        var down = 0
        for token in upTokens {
            up += input.components(separatedBy: token.lowercased()).count - 1
        }
        for token in downTokens {
            down += input.components(separatedBy: token.lowercased()).count - 1
        }
        if up == 0 && down == 0 { return nil }
        return down - up
    }

    @discardableResult
    private static func withNonCanonicalInput<T>(_ body: () -> T) -> T {
        var original = termios()
        guard tcgetattr(STDIN_FILENO, &original) == 0 else {
            return body()
        }
        var mode = original
        // Disable canonical line buffering and echo for single-key reads.
        // ISIG is intentionally disabled so Ctrl+C is received as byte 0x03;
        // this guarantees terminal state restoration before exit.
        mode.c_lflag &= ~tcflag_t(ICANON | ECHO | ISIG)
        mode.c_cc.16 = 1 // VMIN
        mode.c_cc.17 = 0 // VTIME
        guard tcsetattr(STDIN_FILENO, TCSANOW, &mode) == 0 else {
            return body()
        }
        defer {
            _ = tcsetattr(STDIN_FILENO, TCSANOW, &original)
        }
        return body()
    }

    private static func normalizeTerminal() {
        guard isatty(STDIN_FILENO) == 1 else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/stty")
        task.arguments = ["sane"]
        task.standardInput = FileHandle.standardInput
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
    }
}

do {
    try NotesMatrixCLI.run()
} catch {
    fputs("error: \(error)\n", stderr)
    exit(1)
}
