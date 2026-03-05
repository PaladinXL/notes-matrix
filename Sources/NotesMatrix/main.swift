import Foundation
import Darwin

enum NotesMatrixCLI {
    static let appVersion = "0.1.10"

    enum ScheduleError: Error, CustomStringConvertible {
        case invalidCommand
        case invalidTimeFormat(String)
        case executablePathNotFound
        case launchctlFailed(String)

        var description: String {
            switch self {
            case .invalidCommand:
                return "schedule command is invalid. Use: schedule install|status|run-now|remove"
            case .invalidTimeFormat(let value):
                return "invalid time '\(value)'. Expected format: HH:MM"
            case .executablePathNotFound:
                return "could not resolve executable path for schedule setup"
            case .launchctlFailed(let message):
                return "launchctl failed: \(message)"
            }
        }
    }

    struct ScheduleDefinition {
        let hour: Int
        let minute: Int
        let exportArgs: [String]
    }

    struct InteractiveState {
        var outputPath: String
        var mode: ExportMode
        var includeAttachments: Bool
        var existingPolicy: ExistingItemPolicy
        var filenameMode: FilenameMode
        var includeFrontmatter: Bool
        var includeSourceHTML: Bool
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
        beginInteractiveScreenIfSupported()
        defer {
            endInteractiveScreenIfSupported()
            normalizeTerminalMode()
        }

        let defaultOutput = NSHomeDirectory() + "/Desktop/NotesExport"
        var state = InteractiveState(
            outputPath: defaultOutput,
            mode: .folderTree,
            includeAttachments: true,
            existingPolicy: .overwrite,
            filenameMode: .unicodeSafe,
            includeFrontmatter: false,
            includeSourceHTML: true,
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
        "Run Export",
        "Settings",
        "Help",
        "Exit"
    ]

    private static func runDashboardAction(index: Int, state: inout InteractiveState) throws -> Bool {
        switch index {
        case 0:
            do {
                try interactiveExport(
                    mode: state.mode,
                    outputPath: state.outputPath,
                    includeAttachments: state.includeAttachments,
                    existingPolicy: state.existingPolicy,
                    filenameMode: state.filenameMode,
                    includeFrontmatter: state.includeFrontmatter,
                    includeSourceHTML: state.includeSourceHTML,
                    incremental: state.incremental
                )
                state.lastRunMessage = "Export completed"
                pausePrompt()
            } catch {
                state.lastRunMessage = "Export failed: \(error)"
                pausePrompt()
            }
        case 1:
            do {
                state.lastRunMessage = try runInteractiveSettings(state: &state)
            } catch {
                state.lastRunMessage = "Settings failed: \(error)"
                pausePrompt()
            }
        case 2:
            printInteractiveHelp()
        case 3:
            print(ANSI.paint("Bye.", ANSI.dim))
            return true
        default:
            state.lastRunMessage = "Unknown action"
        }
        return false
    }

    static func runInteractiveScan() throws -> Int {
        print(ANSI.paint("[stage] 1/3 Searching notes...", ANSI.green))
        print(ANSI.paint("  Requesting Notes data via osascript...", ANSI.green))
        print(ANSI.paint("  [hint] if this is first run, approve macOS Automation permission for Notes.", ANSI.dim))
        let started = Date()
        let notes = try AppleNotesProvider().loadNotes(mode: .scan)
        let elapsed = String(format: "%.2f", Date().timeIntervalSince(started))
        print(ANSI.paint("  Done: searching notes in \(elapsed)s", ANSI.green))
        print(ANSI.paint("  Found \(notes.count) notes", ANSI.brightGreen))
        printSample(notes)
        return notes.count
    }

    static func interactiveExport(
        mode: ExportMode,
        outputPath: String,
        includeAttachments: Bool,
        existingPolicy: ExistingItemPolicy,
        filenameMode: FilenameMode,
        includeFrontmatter: Bool,
        includeSourceHTML: Bool,
        incremental: Bool
    ) throws {
        let overallStarted = Date()
        let output = URL(fileURLWithPath: outputPath, isDirectory: true)
        print("")
        print(ANSI.paint("Export started:", ANSI.cyan))
        print("")
        print(ANSI.paint("[stage] 1/3 Searching notes...", ANSI.green))
        print(ANSI.paint("  Requesting Notes data via osascript...", ANSI.green))
        print(ANSI.paint("  [hint] if no output appears, check for a hidden macOS permission dialog.", ANSI.dim))

        let provider = AppleNotesProvider()
        let notes: [ExportNote]
        var metadataForManifest: [ExportNote]?
        if incremental {
            let metadata = try provider.loadNotes(mode: .scan)
            metadataForManifest = metadata
            print(ANSI.paint("  Found \(metadata.count) notes", ANSI.brightGreen))
            let manifestURL = manifestURL(for: output)
            let previousManifest = loadManifest(at: manifestURL)
            let context = IncrementalContext(
                includeAttachments: includeAttachments,
                filenameMode: filenameMode,
                includeFrontmatter: includeFrontmatter,
                includeSourceHTML: includeSourceHTML,
                mode: mode
            )
            let changedMetadata = changedNotes(metadata: metadata, manifest: previousManifest, context: context)
            if changedMetadata.isEmpty {
                print(ANSI.paint("[done] no changed notes detected; export skipped", ANSI.green))
                saveManifest(from: metadata, context: context, to: manifestURL)
                return
            }
            print(ANSI.paint("  Incremental: changed notes \(changedMetadata.count)/\(metadata.count)", ANSI.cyan))
            print("")
            print(ANSI.paint("[stage] 2/3 Reading note content:", ANSI.green))
            notes = try provider.loadNotesContent(from: changedMetadata, includeAttachments: includeAttachments)
        } else {
            let metadata = try provider.loadNotes(mode: .scan)
            metadataForManifest = metadata
            print(ANSI.paint("  Found \(metadata.count) notes", ANSI.brightGreen))
            print("")
            print(ANSI.paint("[stage] 2/3 Reading note content:", ANSI.green))
            notes = try provider.loadNotesContent(from: metadata, includeAttachments: includeAttachments)
        }
        print("")
        print(ANSI.paint("[stage] 3/3 Saving notes:", ANSI.green))

        let result = try MarkdownExporter().export(
            notes,
            to: output,
            mode: mode,
            existingPolicy: existingPolicy,
            filenameMode: filenameMode,
            includeFrontmatter: includeFrontmatter,
            includeSourceHTML: includeSourceHTML
        )
        let totalElapsed = String(format: "%.2f", Date().timeIntervalSince(overallStarted))
        print("")
        print(ANSI.paint("[DONE] Export completed in \(totalElapsed)s (total)", ANSI.green))
        printSummary(result)

        if incremental {
            let manifestURL = manifestURL(for: output)
            let context = IncrementalContext(
                includeAttachments: includeAttachments,
                filenameMode: filenameMode,
                includeFrontmatter: includeFrontmatter,
                includeSourceHTML: includeSourceHTML,
                mode: mode
            )
            saveManifest(from: metadataForManifest ?? [], context: context, to: manifestURL)
        }
    }

    static func runNonInteractive(args: [String]) throws {
        switch args.first {
        case "scan":
            let verbose = args.contains("--verbose")
            print(ANSI.paint("[stage] 1/3 Searching notes...", ANSI.green))
            print(ANSI.paint("  Requesting Notes data via osascript...", ANSI.green))
            let started = Date()
            let notes = try AppleNotesProvider().loadNotes(mode: .scan, verbose: verbose)
            let elapsed = String(format: "%.2f", Date().timeIntervalSince(started))
            print(ANSI.paint("  Done: searching notes in \(elapsed)s", ANSI.green))
            print(ANSI.paint("  Found \(notes.count) notes", ANSI.brightGreen))
            printSample(notes)
        case "export":
            let overallStarted = Date()
            let output = parseFlag("--output", args: args) ?? FileManager.default.currentDirectoryPath
            let zipEnabled = args.contains("--zip")
            let includeAttachments = args.contains("--with-attachments")
            let includeFrontmatter = args.contains("--with-frontmatter")
            let includeSourceHTML = !args.contains("--no-source-html")
            let incremental = args.contains("--incremental")
            let verbose = args.contains("--verbose")
            let existingPolicy = parseFlag("--on-existing", args: args).flatMap { ExistingItemPolicy(rawValue: $0) } ?? .overwrite
            let filenameMode = parseFlag("--filename-mode", args: args).flatMap { FilenameMode(rawValue: $0) } ?? .unicodeSafe
            let mode: ExportMode = zipEnabled ? .zip : .folderTree
            print("")
            print(ANSI.paint("Export started:", ANSI.cyan))
            print("")
            print(ANSI.paint("[stage] 1/3 Searching notes...", ANSI.green))
            print(ANSI.paint("  Requesting Notes data via osascript...", ANSI.green))
            if !includeAttachments {
                print("[mode] fast export (attachments skipped, source.html kept)")
            }
            let provider = AppleNotesProvider()
            let notes: [ExportNote]
            var metadataForManifest: [ExportNote]?
            if incremental {
                let metadata = try provider.loadNotes(mode: .scan, verbose: verbose)
                metadataForManifest = metadata
                print(ANSI.paint("  Found \(metadata.count) notes", ANSI.brightGreen))
                let manifestURL = manifestURL(for: URL(fileURLWithPath: output, isDirectory: true))
                let previousManifest = loadManifest(at: manifestURL)
                let context = IncrementalContext(
                    includeAttachments: includeAttachments,
                    filenameMode: filenameMode,
                    includeFrontmatter: includeFrontmatter,
                    includeSourceHTML: includeSourceHTML,
                    mode: mode
                )
                let changedMetadata = changedNotes(metadata: metadata, manifest: previousManifest, context: context)
                if changedMetadata.isEmpty {
                    print(ANSI.paint("[done] no changed notes detected; export skipped", ANSI.green))
                    saveManifest(from: metadata, context: context, to: manifestURL)
                    return
                }
                print(ANSI.paint("  Incremental: changed notes \(changedMetadata.count)/\(metadata.count)", ANSI.cyan))
                print("")
                print(ANSI.paint("[stage] 2/3 Reading note content:", ANSI.green))
                notes = try provider.loadNotesContent(
                    from: changedMetadata,
                    includeAttachments: includeAttachments,
                    verbose: verbose
                )
            } else {
                let metadata = try provider.loadNotes(mode: .scan, verbose: verbose)
                metadataForManifest = metadata
                print(ANSI.paint("  Found \(metadata.count) notes", ANSI.brightGreen))
                print("")
                print(ANSI.paint("[stage] 2/3 Reading note content:", ANSI.green))
                notes = try provider.loadNotesContent(
                    from: metadata,
                    includeAttachments: includeAttachments,
                    verbose: verbose
                )
            }
            print("")
            print(ANSI.paint("[stage] 3/3 Saving notes:", ANSI.green))
            let result = try MarkdownExporter().export(
                notes,
                to: URL(fileURLWithPath: output, isDirectory: true),
                mode: mode,
                existingPolicy: existingPolicy,
                filenameMode: filenameMode,
                includeFrontmatter: includeFrontmatter,
                includeSourceHTML: includeSourceHTML
            )
            let totalElapsed = String(format: "%.2f", Date().timeIntervalSince(overallStarted))
            print("")
            print(ANSI.paint("[DONE] Export completed in \(totalElapsed)s (total)", ANSI.green))
            printSummary(result)
            if incremental {
                let context = IncrementalContext(
                    includeAttachments: includeAttachments,
                    filenameMode: filenameMode,
                    includeFrontmatter: includeFrontmatter,
                    includeSourceHTML: includeSourceHTML,
                    mode: mode
                )
                saveManifest(from: metadataForManifest ?? [], context: context, to: manifestURL(for: URL(fileURLWithPath: output, isDirectory: true)))
            }
        case "schedule":
            try runSchedule(args: Array(args.dropFirst()))
        case "version", "--version":
            print("notes-matrix v\(appVersion)")
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
        print("Notes saved: \(result.notesCount)")
        print("Destination: \(result.destination.path)")
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
        print("  frontmatter: \(state.includeFrontmatter ? "on (YAML metadata in .md)" : "off (content only, default)")")
        print("  source HTML snapshot: \(state.includeSourceHTML ? "on (save *.source.html fallback)" : "off (markdown only)")")
        print("  incremental: \(state.incremental ? "on (changed notes only)" : "off (full export)")")
        if let count = state.lastScanCount {
            print("  last scan: \(count) notes")
        }
        if let msg = state.lastRunMessage {
            print(ANSI.paint("  status: \(msg)", ANSI.yellow))
        }
        print("")
        print(ANSI.paint("Tips: use 'fast' for daily export, 'deep' for full attachment pull.", ANSI.dim))
        print(ANSI.paint("maintainer (GitHub): @PaladinXL", ANSI.dim))
        print(ANSI.paint("version: v\(appVersion)", ANSI.dim))
        print(ANSI.paint("Navigate: ↑/↓ move, Enter run selected, q exit. Fallback: w/s or action number (1-4).", ANSI.dim))
    }

    static func printInteractiveHelp() {
        let lines: [String] = [
            ANSI.paint("  Main menu:", ANSI.yellow),
            ANSI.paint("  1) Run Export", ANSI.green),
            ANSI.paint("  2) Settings", ANSI.green),
            ANSI.paint("  3) Help", ANSI.green),
            ANSI.paint("  4) Exit", ANSI.green),
            "",
            ANSI.paint("  Settings menu:", ANSI.yellow),
            ANSI.paint("  1) Set Output Path", ANSI.green),
            "     Directory where export output will be written.",
            "     Output is always created inside: <output>/notes-export",
            "",
            ANSI.paint("  2) Select Export Mode (tree/zip)", ANSI.green),
            "     Opens a selector for export format:",
            "     - tree: standard folder tree with .md files",
            "     - zip: same structure, also packed into notes-export.zip",
            "",
            ANSI.paint("  3) Select Attachments Mode (fast/deep)", ANSI.green),
            "     - fast (recommended): faster, keeps .source.html as reliable fallback",
            "     - deep: attempts full binary attachment/graphics extraction (slower)",
            "",
            ANSI.paint("  4) Select Existing Item Policy", ANSI.green),
            "     Controls behavior when target file/folder already exists:",
            "     - overwrite: replace/reuse existing targets (default)",
            "     - skip: do nothing for conflicting targets",
            "     - uniquify: create new names with suffix (-1, -2, ...)",
            "",
            ANSI.paint("  5) Select Filename Mode (unicode/ascii)", ANSI.green),
            "     Controls cross-platform filename behavior:",
            "     - unicode: keep Cyrillic/Unicode names, sanitize safely",
            "     - ascii: transliterate names to ASCII for max Windows portability",
            "",
            ANSI.paint("  6) Select Frontmatter (off/on)", ANSI.green),
            "     - off (default): export note content only",
            "     - on: add YAML metadata block at top of each .md file",
            "",
            ANSI.paint("  7) Select Source HTML Snapshot (on/off)", ANSI.green),
            "     - on (default): save <note>.source.html fallback",
            "     - off: do not save HTML snapshots",
            "",
            ANSI.paint("  8) Select Incremental Mode (off/on)", ANSI.green),
            "     - off (default): read and export all notes",
            "     - on: compare with manifest and export only changed notes",
            "",
            ANSI.paint("  9) Run Export", ANSI.green),
            "     Runs export using current settings (path/mode/attachments).",
            "",
            ANSI.paint("  10) Schedule (background export)", ANSI.green),
            "     Install/status/run-now/remove daily launchd automation.",
            "",
            ANSI.paint("  Diagnostic:", ANSI.yellow) + " quick scan is available in CLI: `notes-matrix scan`",
            ANSI.paint("  Schedule:", ANSI.yellow) + " use Settings menu item 10 or CLI `notes-matrix schedule ...`",
            ANSI.paint("  Tip:", ANSI.yellow) + " for regular backups, use fast + tree.",
            ANSI.paint("  Maintainer (GitHub):", ANSI.yellow) + " @PaladinXL",
            ANSI.paint("  Disclaimer:", ANSI.yellow) + " provided \"as is\"; use at your own risk and keep backups.",
            ANSI.paint("  Navigation:", ANSI.yellow) + " use ↑/↓ and Enter in selectors (q = cancel)."
        ]
        paginateHelp(lines: lines, title: "HELP")
    }

    private static func paginateHelp(lines: [String], title: String) {
        if !supportsAnsiTerminal() {
            print("")
            print(ANSI.paint(title, ANSI.cyan))
            for line in lines { print(line) }
            pausePrompt()
            return
        }

        let rows = terminalRows()
        let pageSize = max(8, rows - 9)
        var start = 0

        while true {
            clearScreen()
            printMatrixHeader()
            print("")
            print(ANSI.paint(title, ANSI.cyan))
            print("")

            let end = min(start + pageSize, lines.count)
            for idx in start..<end {
                print(lines[idx])
            }
            print("")
            let page = (start / pageSize) + 1
            let pages = max(1, Int(ceil(Double(max(1, lines.count)) / Double(pageSize))))
            print(ANSI.paint("Page \(page)/\(pages)  Enter/↓ next, ↑ previous, q exit", ANSI.dim))

            switch readMenuKey() {
            case .enter, .down, .right:
                if end >= lines.count { return }
                start = end
            case .up, .left:
                if start == 0 { continue }
                start = max(0, start - pageSize)
            case .quit, .cancel:
                return
            case .digit(let n):
                if n == 0 { return }
                continue
            case .other:
                continue
            }
        }
    }

    private static func terminalRows() -> Int {
        guard isatty(STDOUT_FILENO) == 1 else { return 24 }
        var size = winsize()
        let rc = ioctl(STDOUT_FILENO, TIOCGWINSZ, &size)
        if rc == 0, size.ws_row > 0 {
            return Int(size.ws_row)
        }
        return 24
    }

    static func runInteractiveSchedule(state: InteractiveState) throws -> String {
        let options = [
            "Install daily schedule",
            "Schedule status",
            "Run scheduled job now",
            "Remove schedule"
        ]
        var initialIndex = 0
        var lastMessage = "Schedule menu closed"

        while true {
            guard let selected = promptArrowMenu(
                title: "SCHEDULE",
                current: "launchd background export",
                options: options,
                initialIndex: initialIndex
            ) else {
                return lastMessage
            }
            initialIndex = selected

            switch selected {
            case 0:
                print(ANSI.paint("Daily time HH:MM (default 09:00) >", ANSI.brightGreen), terminator: " ")
                let daily = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines)
                let selectedTime = (daily?.isEmpty == false) ? daily! : "09:00"

                print(ANSI.paint("Output path (default current output) >", ANSI.brightGreen), terminator: " ")
                let outputInput = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines)
                let outputPath = (outputInput?.isEmpty == false) ? outputInput! : state.outputPath

                var args = [
                    "install",
                    "--daily", selectedTime,
                    "--output", outputPath,
                    "--on-existing", state.existingPolicy.rawValue,
                    "--filename-mode", state.filenameMode.rawValue
                ]
                if state.mode == .zip { args.append("--zip") }
                if state.includeAttachments { args.append("--with-attachments") }
                if state.includeFrontmatter { args.append("--with-frontmatter") }
                if !state.includeSourceHTML { args.append("--no-source-html") }
                if state.incremental { args.append("--incremental") }
                try runSchedule(args: args)
                lastMessage = "Schedule installed (\(selectedTime))"
            case 1:
                try runSchedule(args: ["status"])
                lastMessage = "Schedule status shown"
            case 2:
                try runSchedule(args: ["run-now"])
                lastMessage = "Scheduled run started"
            case 3:
                try runSchedule(args: ["remove"])
                lastMessage = "Schedule removed"
            default:
                return lastMessage
            }

            pausePrompt()
        }
    }

    static func runInteractiveSettings(state: inout InteractiveState) throws -> String {
        let options = [
            "Set Output Path",
            "Select Export Mode (tree/zip)",
            "Select Attachments Mode (fast/deep)",
            "Select Existing Item Policy",
            "Select Filename Mode (unicode/ascii)",
            "Select Frontmatter (off/on)",
            "Select Source HTML Snapshot (on/off)",
            "Select Incremental Mode (off/on)",
            "Run Export",
            "Schedule (background export)"
        ]
        var initialIndex = 0
        var lastMessage = "Settings menu closed"

        while true {
            guard let selected = promptArrowMenu(
                title: "SETTINGS",
                current: "export configuration",
                options: options,
                initialIndex: initialIndex
            ) else {
                return lastMessage
            }
            initialIndex = selected

            switch selected {
            case 0:
                print(ANSI.paint("New output path >", ANSI.brightGreen), terminator: " ")
                if let path = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
                    state.outputPath = path
                    lastMessage = "Output path updated"
                } else {
                    lastMessage = "Output path unchanged"
                }
            case 1:
                if let selectedMode = promptSelectExportMode(current: state.mode) {
                    state.mode = selectedMode
                    lastMessage = "Mode set to \(state.mode.rawValue)"
                } else {
                    lastMessage = "Mode selection cancelled"
                }
            case 2:
                if let selectedAttachments = promptSelectAttachmentsMode(current: state.includeAttachments) {
                    state.includeAttachments = selectedAttachments
                    lastMessage = state.includeAttachments
                        ? "Attachments mode set to deep"
                        : "Attachments mode set to fast"
                } else {
                    lastMessage = "Attachments selection cancelled"
                }
            case 3:
                if let selectedPolicy = promptSelectExistingPolicy(current: state.existingPolicy) {
                    state.existingPolicy = selectedPolicy
                    lastMessage = "Existing item policy: \(selectedPolicy.rawValue)"
                } else {
                    lastMessage = "Existing item policy selection cancelled"
                }
            case 4:
                if let selectedFilenameMode = promptSelectFilenameMode(current: state.filenameMode) {
                    state.filenameMode = selectedFilenameMode
                    lastMessage = "Filename mode: \(selectedFilenameMode.rawValue)"
                } else {
                    lastMessage = "Filename mode selection cancelled"
                }
            case 5:
                if let selectedFrontmatter = promptSelectFrontmatterMode(current: state.includeFrontmatter) {
                    state.includeFrontmatter = selectedFrontmatter
                    lastMessage = "Frontmatter: \(selectedFrontmatter ? "on" : "off")"
                } else {
                    lastMessage = "Frontmatter selection cancelled"
                }
            case 6:
                if let selectedSourceHTML = promptSelectSourceHTMLMode(current: state.includeSourceHTML) {
                    state.includeSourceHTML = selectedSourceHTML
                    lastMessage = "Source HTML snapshot: \(selectedSourceHTML ? "on" : "off")"
                } else {
                    lastMessage = "Source HTML setting cancelled"
                }
            case 7:
                if let selectedIncremental = promptSelectIncrementalMode(current: state.incremental) {
                    state.incremental = selectedIncremental
                    lastMessage = "Incremental mode: \(selectedIncremental ? "on" : "off")"
                } else {
                    lastMessage = "Incremental mode selection cancelled"
                }
            case 8:
                do {
                    try interactiveExport(
                        mode: state.mode,
                        outputPath: state.outputPath,
                        includeAttachments: state.includeAttachments,
                        existingPolicy: state.existingPolicy,
                        filenameMode: state.filenameMode,
                        includeFrontmatter: state.includeFrontmatter,
                        includeSourceHTML: state.includeSourceHTML,
                        incremental: state.incremental
                    )
                    lastMessage = "Export completed"
                    pausePrompt()
                } catch {
                    lastMessage = "Export failed: \(error)"
                    pausePrompt()
                }
            case 9:
                do {
                    lastMessage = try runInteractiveSchedule(state: state)
                } catch {
                    lastMessage = "Schedule failed: \(error)"
                    pausePrompt()
                }
            default:
                return lastMessage
            }
        }
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

    static func promptSelectSourceHTMLMode(current: Bool) -> Bool? {
        let options = ["on (save source.html fallback, default)", "off (do not save source.html)"]
        let currentIndex = current ? 0 : 1
        guard let selected = promptArrowMenu(
            title: "SELECT SOURCE HTML SNAPSHOT",
            current: current ? "on" : "off",
            options: options,
            initialIndex: currentIndex
        ) else { return nil }
        return selected == 0
    }

    static func promptSelectFrontmatterMode(current: Bool) -> Bool? {
        let options = ["off (content only, default)", "on (include YAML metadata)"]
        let currentIndex = current ? 1 : 0
        guard let selected = promptArrowMenu(
            title: "SELECT FRONTMATTER MODE",
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
            if input == "q" || input == "й" || input == "quit" || input == "cancel" || input == "b" || input == "back" || input == "0" { return nil }
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
        if ch == 208 {
            var next: UInt8 = 0
            if withNonCanonicalInput({ read(STDIN_FILENO, &next, 1) }) == 1 {
                if next == 185 || next == 153 { return .cancel } // й / Й
            }
            return .other
        }
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
        if ch == 208 {
            var next: UInt8 = 0
            if withNonCanonicalInput({ read(STDIN_FILENO, &next, 1) }) == 1 {
                if next == 185 || next == 153 { return .quit } // й / Й
            }
            return .other
        }
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
        guard isatty(STDIN_FILENO) == 1 else {
            _ = readLine()
            return
        }

        while true {
            switch readMenuKey() {
            case .enter, .quit, .cancel, .up, .down, .left, .right:
                print("")
                return
            case .digit:
                print("")
                return
            case .other:
                continue
            }
        }
    }

    static func printHelp() {
        print(
            """
            notes-matrix - Apple Notes exporter (v\(appVersion))

            Usage:
              notes-matrix                  # interactive matrix-like TUI
              notes-matrix scan
              notes-matrix version
              notes-matrix help
              notes-matrix export --output /path/to/dir [--zip] [--with-attachments] [--on-existing overwrite|skip|uniquify] [--filename-mode unicode|ascii] [--with-frontmatter] [--no-source-html] [--incremental] [--verbose]
              notes-matrix schedule install --daily HH:MM [--output /path] [--zip] [--with-attachments] [--on-existing overwrite|skip|uniquify] [--filename-mode unicode|ascii] [--with-frontmatter] [--no-source-html] [--incremental] [--verbose]
              notes-matrix schedule status
              notes-matrix schedule run-now
              notes-matrix schedule remove

            Commands:
              scan
                Diagnostic metadata scan (no export). CLI-only.

              export
                Export notes to Markdown using current flags.

              schedule
                Manage daily background export via launchd.

              version
                Show current app version.

              help
                Show this help message.

            TUI operations:
              Main menu:
                1) Run Export
                2) Settings
                3) Help
                4) Exit
              Settings menu:
                Set Output Path
                Select Export Mode (tree/zip)
                Select Attachments Mode (fast/deep)
                Select Existing Item Policy
                Select Filename Mode (unicode/ascii)
                Select Frontmatter (off/on)
                Select Source HTML Snapshot (on/off)
                Select Incremental Mode (off/on)
                Run Export
                Schedule (background export)
              Navigation: ↑/↓ move, Enter select, q exit. Number shortcuts support 1-4 in main menu.

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

              --with-frontmatter
                Include YAML metadata block at top of each Markdown note.
                By default frontmatter is disabled.

              --no-source-html
                Disable writing <note>.source.html fallback snapshots.
                By default source HTML snapshots are enabled.

              --incremental
                Export only changed notes using local manifest cache.
                First run exports all notes.

              --verbose
                Show technical scan/fallback details during export.
                Default output is simplified for end users.

            Examples:
              notes-matrix export --output ~/Desktop/NotesExport
              notes-matrix export --output ~/Desktop/NotesExport --zip
              notes-matrix export --output ~/Desktop/NotesExport --with-attachments --on-existing skip
              notes-matrix export --output ~/Desktop/NotesExport --filename-mode ascii
              notes-matrix export --output ~/Desktop/NotesExport --with-frontmatter
              notes-matrix export --output ~/Desktop/NotesExport --no-source-html
              notes-matrix export --output ~/Desktop/NotesExport --with-attachments --incremental
              notes-matrix export --output ~/Desktop/NotesExport --verbose
              notes-matrix schedule install --daily 09:00 --output ~/Desktop/NotesExport --incremental
              notes-matrix schedule status
              notes-matrix schedule run-now
              notes-matrix schedule remove

            Notes:
              - On first run macOS will ask Automation permission for Notes.
              - Export writes Markdown files and local assets.
              - Fast mode skips deep attachment extraction but keeps raw HTML snapshot.
              - Provided "as is". Use at your own risk and keep backups.
            """
        )
    }

    static func runSchedule(args: [String]) throws {
        guard let subcommand = args.first else { throw ScheduleError.invalidCommand }

        switch subcommand {
        case "install":
            guard let daily = parseFlag("--daily", args: args) else {
                throw ScheduleError.invalidTimeFormat("missing --daily")
            }
            let (hour, minute) = try parseDailyTime(daily)
            let output = parseFlag("--output", args: args) ?? NSHomeDirectory() + "/Desktop/NotesExport"
            let includeAttachments = args.contains("--with-attachments")
            let includeFrontmatter = args.contains("--with-frontmatter")
            let includeSourceHTML = !args.contains("--no-source-html")
            let zipEnabled = args.contains("--zip")
            let incremental = args.contains("--incremental")
            let verbose = args.contains("--verbose")
            let existingPolicy = parseFlag("--on-existing", args: args).flatMap { ExistingItemPolicy(rawValue: $0) } ?? .overwrite
            let filenameMode = parseFlag("--filename-mode", args: args).flatMap { FilenameMode(rawValue: $0) } ?? .unicodeSafe

            var exportArgs = ["export", "--output", output, "--on-existing", existingPolicy.rawValue, "--filename-mode", filenameMode.rawValue]
            if zipEnabled { exportArgs.append("--zip") }
            if includeAttachments { exportArgs.append("--with-attachments") }
            if includeFrontmatter { exportArgs.append("--with-frontmatter") }
            if !includeSourceHTML { exportArgs.append("--no-source-html") }
            if incremental { exportArgs.append("--incremental") }
            if verbose { exportArgs.append("--verbose") }

            let executable = try resolveExecutablePath()
            let plistURL = schedulePlistURL()
            let logsDir = scheduleLogsDirURL()
            try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
            let stdoutPath = logsDir.appendingPathComponent("scheduled.log").path
            let stderrPath = logsDir.appendingPathComponent("scheduled.error.log").path
            let plist = renderSchedulePlist(
                label: scheduleLabel(),
                executablePath: executable,
                exportArgs: exportArgs,
                hour: hour,
                minute: minute,
                stdoutPath: stdoutPath,
                stderrPath: stderrPath
            )
            let parent = plistURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            try plist.write(to: plistURL, atomically: true, encoding: .utf8)

            _ = runProcess("/bin/launchctl", ["unload", plistURL.path], allowFailure: true)
            let load = runProcess("/bin/launchctl", ["load", plistURL.path], allowFailure: false)
            if load.status != 0 {
                throw ScheduleError.launchctlFailed(load.err.isEmpty ? load.out : load.err)
            }

            print("Schedule installed.")
            print("time: \(String(format: "%02d:%02d", hour, minute)) daily")
            print("agent: \(plistURL.path)")
            print("logs: \(logsDir.path)")
            print("run-now: notes-matrix schedule run-now")
        case "status":
            let plistURL = schedulePlistURL()
            guard FileManager.default.fileExists(atPath: plistURL.path) else {
                print("Schedule is not installed.")
                return
            }
            let label = scheduleLabel()
            let loaded = runProcess("/bin/launchctl", ["list", label], allowFailure: true).status == 0
            let definition = loadScheduleDefinition(from: plistURL)
            print("Schedule installed: yes")
            print("Schedule loaded: \(loaded ? "yes" : "no")")
            if let definition {
                print("time: \(String(format: "%02d:%02d", definition.hour, definition.minute)) daily")
                print("command: notes-matrix \(definition.exportArgs.joined(separator: " "))")
            }
            print("agent: \(plistURL.path)")
        case "run-now":
            let plistURL = schedulePlistURL()
            guard let definition = loadScheduleDefinition(from: plistURL) else {
                print("Schedule is not installed. Run: notes-matrix schedule install --daily 09:00 --output /path")
                return
            }
            print("Running scheduled export now...")
            try runNonInteractive(args: definition.exportArgs)
        case "remove":
            let plistURL = schedulePlistURL()
            _ = runProcess("/bin/launchctl", ["unload", plistURL.path], allowFailure: true)
            if FileManager.default.fileExists(atPath: plistURL.path) {
                try FileManager.default.removeItem(at: plistURL)
                print("Schedule removed.")
            } else {
                print("Schedule was not installed.")
            }
        default:
            throw ScheduleError.invalidCommand
        }
    }

    static func parseDailyTime(_ value: String) throws -> (Int, Int) {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let hour = Int(parts[0]),
              let minute = Int(parts[1]),
              (0...23).contains(hour),
              (0...59).contains(minute) else {
            throw ScheduleError.invalidTimeFormat(value)
        }
        return (hour, minute)
    }

    static func scheduleLabel() -> String {
        "com.notesmatrix.export"
    }

    static func schedulePlistURL() -> URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(scheduleLabel()).plist")
    }

    static func scheduleLogsDirURL() -> URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("notes-matrix", isDirectory: true)
    }

    static func resolveExecutablePath() throws -> String {
        let fm = FileManager.default
        let arg0 = CommandLine.arguments.first ?? ""
        let basePath: String
        if arg0.hasPrefix("/") {
            basePath = arg0
        } else {
            basePath = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent(arg0).path
        }
        let resolved = URL(fileURLWithPath: basePath).standardizedFileURL.path
        if fm.isExecutableFile(atPath: resolved) {
            return resolved
        }
        if let bundlePath = Bundle.main.executablePath, fm.isExecutableFile(atPath: bundlePath) {
            return bundlePath
        }
        throw ScheduleError.executablePathNotFound
    }

    static func renderSchedulePlist(
        label: String,
        executablePath: String,
        exportArgs: [String],
        hour: Int,
        minute: Int,
        stdoutPath: String,
        stderrPath: String
    ) -> String {
        let argsXML = ([executablePath] + exportArgs)
            .map { "      <string>\(xmlEscape($0))</string>" }
            .joined(separator: "\n")

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key>
          <string>\(xmlEscape(label))</string>
          <key>ProgramArguments</key>
          <array>
          \(argsXML)
          </array>
          <key>StartCalendarInterval</key>
          <dict>
            <key>Hour</key>
            <integer>\(hour)</integer>
            <key>Minute</key>
            <integer>\(minute)</integer>
          </dict>
          <key>StandardOutPath</key>
          <string>\(xmlEscape(stdoutPath))</string>
          <key>StandardErrorPath</key>
          <string>\(xmlEscape(stderrPath))</string>
        </dict>
        </plist>
        """
    }

    static func xmlEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    static func runProcess(_ executable: String, _ arguments: [String], allowFailure: Bool) -> (status: Int32, out: String, err: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        task.standardOutput = out
        task.standardError = err
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            if allowFailure {
                return (1, "", String(describing: error))
            }
            return (1, "", String(describing: error))
        }
        let stdout = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return (task.terminationStatus, stdout.trimmingCharacters(in: .whitespacesAndNewlines), stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func loadScheduleDefinition(from plistURL: URL) -> ScheduleDefinition? {
        guard let data = try? Data(contentsOf: plistURL) else { return nil }
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        guard let args = plist["ProgramArguments"] as? [String], args.count >= 2 else { return nil }
        guard let interval = plist["StartCalendarInterval"] as? [String: Any] else { return nil }
        guard let hour = interval["Hour"] as? Int, let minute = interval["Minute"] as? Int else { return nil }
        return ScheduleDefinition(hour: hour, minute: minute, exportArgs: Array(args.dropFirst()))
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
        let includeFrontmatter: Bool?
        let includeSourceHTML: Bool?
        let mode: ExportMode
        let notes: [ManifestEntry]
    }

    struct IncrementalContext {
        let includeAttachments: Bool
        let filenameMode: FilenameMode
        let includeFrontmatter: Bool
        let includeSourceHTML: Bool
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
            includeFrontmatter: context.includeFrontmatter,
            includeSourceHTML: context.includeSourceHTML,
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
              (manifest.includeFrontmatter ?? false) == context.includeFrontmatter,
              (manifest.includeSourceHTML ?? true) == context.includeSourceHTML,
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

    private static func beginInteractiveScreenIfSupported() {
        guard supportsAnsiTerminal() else { return }
        // Use alternate buffer to avoid polluting terminal scrollback during TUI redraws.
        fputs("\u{001B}[?1049h\u{001B}[H", stdout)
        fflush(stdout)
    }

    private static func endInteractiveScreenIfSupported() {
        guard supportsAnsiTerminal() else { return }
        fputs("\u{001B}[?1049l", stdout)
        fflush(stdout)
    }
}

do {
    try NotesMatrixCLI.run()
} catch {
    fputs("error: \(error)\n", stderr)
    exit(1)
}
