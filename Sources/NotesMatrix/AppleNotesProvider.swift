import Foundation
import Darwin

enum NotesProviderError: Error, CustomStringConvertible {
    case scriptFailed(String)
    case decodeFailed(String)
    case emptyResult
    case timeout(seconds: Int)

    var description: String {
        switch self {
        case .scriptFailed(let output):
            return "AppleScript/JXA failed: \(output)"
        case .decodeFailed(let output):
            return "Failed to decode notes JSON: \(output)"
        case .emptyResult:
            return "No notes found."
        case .timeout(let seconds):
            return "Timed out after \(seconds)s while reading Notes. Confirm the macOS permission prompt and retry."
        }
    }
}

private struct ContentBatchItem: Codable {
    let sourceIndex: Int
    let id: String?
    let title: String?
    let plaintext: String
    let bodyHTML: String
    let attachments: [NoteAttachment]?
    let account: String?
    let folderPath: [String]?
}

struct AppleNotesProvider {
    private struct FolderCacheEntry: Codable {
        let account: String
        let folderPath: [String]
    }

    private struct FolderCachePayload: Codable {
        let version: Int
        let savedAt: String
        let map: [String: FolderCacheEntry]
    }

    enum ReadMode {
        case scan
        case fullExport
    }

    private let defaultChunkSize = 24

    func loadNotes(
        mode: ReadMode = .fullExport,
        includeAttachments: Bool = false,
        verbose: Bool = false
    ) throws -> [ExportNote] {
        let notes = try loadMetadata(verbose: verbose)
        if notes.isEmpty { throw NotesProviderError.emptyResult }
        if mode == .scan { return notes }
        return try loadNotesContent(from: notes, includeAttachments: includeAttachments, verbose: verbose)
    }

    func loadNotesContent(
        from metadataNotes: [ExportNote],
        includeAttachments: Bool = false,
        verbose: Bool = false
    ) throws -> [ExportNote] {
        if metadataNotes.isEmpty { return [] }
        return try loadNotesContentInternal(metadataNotes, includeAttachments: includeAttachments, verbose: verbose)
    }

    private func loadNotesContentInternal(
        _ metadataNotes: [ExportNote],
        includeAttachments: Bool,
        verbose: Bool
    ) throws -> [ExportNote] {
        var notes = metadataNotes
        let cachedFolderMap = loadCachedFolderMap()
        let sourceIndices = notes.enumerated().map { idx, note in note.sourceIndex ?? idx }
        var localIndexBySourceIndex: [Int: Int] = [:]
        for (idx, sourceIndex) in sourceIndices.enumerated() {
            localIndexBySourceIndex[sourceIndex] = idx
        }

        var status = InlineStatusRenderer(total: notes.count)
        var warnings = 0
        var cursor = 0
        var currentWaitSeconds = 0
        func mergeAccount(
            current: ExportNote,
            item: ContentBatchItem,
            cacheEntry: FolderCacheEntry?
        ) -> String {
            if let account = item.account?.trimmingCharacters(in: .whitespacesAndNewlines), !account.isEmpty {
                return account
            }
            if !isUnknownPlaceholder(account: current.account, folderPath: current.folderPath) {
                return current.account
            }
            if let cached = cacheEntry?.account.trimmingCharacters(in: .whitespacesAndNewlines), !cached.isEmpty {
                return cached
            }
            return current.account
        }

        func mergeFolderPath(
            current: ExportNote,
            item: ContentBatchItem,
            cacheEntry: FolderCacheEntry?
        ) -> [String] {
            if let path = item.folderPath?
                .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
                .filter({ !$0.isEmpty }), !path.isEmpty {
                return path
            }
            if !isUnknownPlaceholder(account: current.account, folderPath: current.folderPath), !current.folderPath.isEmpty {
                return current.folderPath
            }
            if let cached = cacheEntry?.folderPath
                .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
                .filter({ !$0.isEmpty }), !cached.isEmpty {
                return cached
            }
            return current.folderPath
        }

        func fillSourceIndices(_ batchSourceIndices: [Int]) {
            if batchSourceIndices.isEmpty { return }
            do {
                let items = try loadContentBatch(
                    sourceIndices: batchSourceIndices,
                    timeoutSeconds: includeAttachments ? 45 : 25,
                    includeAttachments: includeAttachments,
                    onWait: { elapsed in
                        currentWaitSeconds = elapsed
                        if status.enabled {
                            status.render(waitSeconds: currentWaitSeconds, done: cursor)
                        } else if verbose {
                            fputs("Processing... \(elapsed)s elapsed\n", stderr)
                        }
                    }
                )
                for item in items {
                    guard let localIndex = localIndexBySourceIndex[item.sourceIndex], localIndex >= 0, localIndex < notes.count else { continue }
                    let n = notes[localIndex]
                    let cacheEntry = (item.id?.isEmpty == false ? cachedFolderMap[item.id!] : nil)
                    let mergedAccount = mergeAccount(current: n, item: item, cacheEntry: cacheEntry)
                    let mergedFolderPath = mergeFolderPath(current: n, item: item, cacheEntry: cacheEntry)
                    notes[localIndex] = ExportNote(
                        id: item.id ?? n.id,
                        sourceIndex: n.sourceIndex,
                        title: (item.title?.isEmpty == false ? item.title! : n.title),
                        plaintext: item.plaintext,
                        bodyHTML: item.bodyHTML,
                        attachments: item.attachments,
                        account: mergedAccount,
                        folderPath: mergedFolderPath,
                        createdAt: n.createdAt,
                        updatedAt: n.updatedAt
                    )
                }
            } catch {
                if batchSourceIndices.count == 1 {
                    warnings += 1
                    let sourceIndex = batchSourceIndices[0]
                    guard let localIndex = localIndexBySourceIndex[sourceIndex], localIndex >= 0, localIndex < notes.count else { return }
                    let n = notes[localIndex]
                    notes[localIndex] = ExportNote(
                        id: n.id,
                        sourceIndex: n.sourceIndex,
                        title: n.title,
                        plaintext: "Content could not be fetched for this note.\nNote ID: \(n.id)\n",
                        bodyHTML: "",
                        attachments: nil,
                        account: n.account,
                        folderPath: n.folderPath,
                        createdAt: n.createdAt,
                        updatedAt: n.updatedAt
                    )
                    fputs("Note \(localIndex + 1): could not load full content, exported fallback text.\n", stderr)
                } else {
                    let leftCount = batchSourceIndices.count / 2
                    let left = Array(batchSourceIndices.prefix(leftCount))
                    let right = Array(batchSourceIndices.dropFirst(leftCount))
                    fillSourceIndices(left)
                    fillSourceIndices(right)
                }
            }
        }

        let chunkSize = includeAttachments ? defaultChunkSize : 56
        while cursor < sourceIndices.count {
            let next = min(chunkSize, sourceIndices.count - cursor)
            let batch = Array(sourceIndices[cursor..<(cursor + next)])
            fillSourceIndices(batch)
            cursor += next
            if status.enabled {
                status.render(waitSeconds: currentWaitSeconds, done: cursor)
            } else {
                fputs("Reading content progress: \(cursor)/\(notes.count)\n", stderr)
            }
        }

        if status.enabled {
            status.finish(done: cursor)
        }

        if warnings > 0 {
            fputs("Completed with fallback text for \(warnings) note(s).\n", stderr)
        }
        return notes
    }

    private func loadMetadata(verbose: Bool) throws -> [ExportNote] {
        let fullScript = #"""
        function safeDate(x) {
          try { return x ? x.toISOString() : null; } catch (_) { return null; }
        }

        function folderPathFor(note) {
          var path = [];
          var folder = null;
          try { folder = note.folder(); } catch (_) {}
          var guardCount = 0;

          while (folder && guardCount < 32) {
            try {
              var fname = String(folder.name());
              if (fname) { path.unshift(fname); }
            } catch (_) {}

            var parent = null;
            try { parent = folder.container(); } catch (_) {}
            if (!parent) { break; }

            var parentClass = "";
            try { parentClass = String(parent.class()).toLowerCase(); } catch (_) {}
            if (parentClass.indexOf("folder") >= 0) {
              folder = parent;
            } else {
              break;
            }
            guardCount += 1;
          }

          return path;
        }

        function collectFolderMap(accountName, folder, path, map) {
          var currentPath = path.slice();
          try { currentPath.push(String(folder.name())); } catch (_) {}

          var notesInFolder = [];
          try { notesInFolder = folder.notes(); } catch (_) {}
          for (var i = 0; i < notesInFolder.length; i++) {
            var nid = "";
            try { nid = String(notesInFolder[i].id()); } catch (_) {}
            if (nid) {
              map[nid] = { account: accountName, folderPath: currentPath };
            }
          }

          var subfolders = [];
          try { subfolders = folder.folders(); } catch (_) {}
          for (var j = 0; j < subfolders.length; j++) {
            collectFolderMap(accountName, subfolders[j], currentPath, map);
          }
        }

        var app = Application("Notes");
        var out = [];
        var notes = [];
        var folderMap = {};
        var accounts = [];
        try { accounts = app.accounts(); } catch (_) {}
        for (var a = 0; a < accounts.length; a++) {
          var account = accounts[a];
          var accountName = "Unknown";
          try { accountName = String(account.name()); } catch (_) {}
          var rootFolders = [];
          try { rootFolders = account.folders(); } catch (_) {}
          for (var r = 0; r < rootFolders.length; r++) {
            collectFolderMap(accountName, rootFolders[r], [], folderMap);
          }
        }

        try { notes = app.notes(); } catch (_) {}

        for (var i = 0; i < notes.length; i++) {
          var n = notes[i];
          var note = {
            id: "",
            sourceIndex: i,
            title: "",
            plaintext: "",
            bodyHTML: "",
            attachments: [],
            account: "Unknown",
            folderPath: [],
            createdAt: null,
            updatedAt: null
          };

          try { note.id = String(n.id()); } catch (_) {}
          try { note.title = String(n.name()); } catch (_) {}
          try { note.createdAt = safeDate(n.creationDate()); } catch (_) {}
          try { note.updatedAt = safeDate(n.modificationDate()); } catch (_) {}
          var mapped = null;
          try { mapped = folderMap[note.id]; } catch (_) {}
          if (mapped) {
            try { note.account = String(mapped.account); } catch (_) {}
            try { note.folderPath = mapped.folderPath; } catch (_) {}
          } else {
            try { note.folderPath = folderPathFor(n); } catch (_) {}
            try { note.account = String(n.account().name()); } catch (_) {}
          }
          out.push(note);
        }

        JSON.stringify(out);
        """#

        let fallbackScript = #"""
        function safeDate(x) {
          try { return x ? x.toISOString() : null; } catch (_) { return null; }
        }

        function folderPathFor(note) {
          var path = [];
          var folder = null;
          try { folder = note.folder(); } catch (_) {}
          var guardCount = 0;

          while (folder && guardCount < 32) {
            try {
              var fname = String(folder.name());
              if (fname) { path.unshift(fname); }
            } catch (_) {}

            var parent = null;
            try { parent = folder.container(); } catch (_) {}
            if (!parent) { break; }

            var parentClass = "";
            try { parentClass = String(parent.class()).toLowerCase(); } catch (_) {}
            if (parentClass.indexOf("folder") >= 0) {
              folder = parent;
            } else {
              break;
            }
            guardCount += 1;
          }

          return path;
        }

        var app = Application("Notes");
        var out = [];
        var notes = [];
        try { notes = app.notes(); } catch (_) {}

        for (var i = 0; i < notes.length; i++) {
          var n = notes[i];
          var note = {
            id: "",
            sourceIndex: i,
            title: "",
            plaintext: "",
            bodyHTML: "",
            attachments: [],
            account: "Unknown",
            folderPath: [],
            createdAt: null,
            updatedAt: null
          };

          try { note.id = String(n.id()); } catch (_) {}
          try { note.title = String(n.name()); } catch (_) {}
          try { note.createdAt = safeDate(n.creationDate()); } catch (_) {}
          try { note.updatedAt = safeDate(n.modificationDate()); } catch (_) {}
          try { note.folderPath = folderPathFor(n); } catch (_) {}
          try { note.account = String(n.account().name()); } catch (_) {}
          out.push(note);
        }

        JSON.stringify(out);
        """#

        // Warm up Notes bridge first. On some systems the first JXA call after app wake-up is
        // slow/unstable and may return timeout or empty data.
        let warmedNoteCount = warmUpNotesBridge()
        let timeoutConfig = metadataTimeoutConfig(noteCount: warmedNoteCount)
        let hasCachedFolders = !loadCachedFolderMap().isEmpty
        func hasMeaningfulFolderCoverage(_ notes: [ExportNote]) -> Bool {
            guard !notes.isEmpty else { return false }
            let resolved = notes.reduce(into: 0) { partial, note in
                if !isUnknownPlaceholder(account: note.account, folderPath: note.folderPath) {
                    partial += 1
                }
            }
            return resolved > 0
        }

        func decodeWithRetryIfEmpty(
            _ raw: String,
            retryLabel: String,
            retryScript: String,
            timeoutSeconds: Int
        ) throws -> [ExportNote] {
            let decoded = try decodeNotes(raw)
            if !decoded.isEmpty { return decoded }

            // Notes can briefly return an empty set right after wake-up/sync.
            if verbose {
                fputs("  Notes sync in progress, retrying...\n", stderr)
            }
            Thread.sleep(forTimeInterval: 2.0)

            var retrySpinner = InlineSpinnerRenderer(label: retryLabel, enabled: verbose)
            let retryOutput = try runOsaScript(
                language: "JavaScript",
                script: retryScript,
                timeoutSeconds: timeoutSeconds,
                    onWait: { elapsed in
                        if retrySpinner.enabled {
                            retrySpinner.render(elapsed: elapsed)
                        } else if verbose {
                            fputs("\(retryLabel)... \(elapsed)s elapsed\n", stderr)
                        }
                    }
                )
            if retrySpinner.enabled { retrySpinner.finish(success: true) }
            return try decodeNotes(retryOutput)
        }

        func runMetadataScriptWithRetry(
            label: String,
            script: String,
            timeoutSeconds: Int,
            attempts: Int
        ) throws -> String {
            let totalAttempts = max(1, attempts)
            var lastError: Error?

            for attempt in 1...totalAttempts {
                var spinner = InlineSpinnerRenderer(
                    label: totalAttempts == 1 ? label : "\(label) [\(attempt)/\(totalAttempts)]",
                    enabled: verbose
                )
                do {
                    let output = try runOsaScript(
                        language: "JavaScript",
                        script: script,
                        timeoutSeconds: timeoutSeconds,
                        onWait: { elapsed in
                            if spinner.enabled {
                                spinner.render(elapsed: elapsed)
                        } else if verbose {
                            fputs("\(label)... \(elapsed)s elapsed\n", stderr)
                        }
                    }
                )
                    if spinner.enabled { spinner.finish(success: true) }
                    return output
                } catch {
                    lastError = error
                    if spinner.enabled { spinner.finish(success: false, details: String(describing: error)) }
                    let shouldRetry: Bool
                    switch error {
                    case NotesProviderError.timeout, NotesProviderError.scriptFailed:
                        shouldRetry = true
                    default:
                        shouldRetry = false
                    }
                    if shouldRetry && attempt < totalAttempts {
                        if verbose {
                            fputs("  Temporary issue, retrying...\n", stderr)
                        }
                        Thread.sleep(forTimeInterval: 1.5)
                        continue
                    }
                    throw error
                }
            }
            throw lastError ?? NotesProviderError.scriptFailed("Unknown metadata read failure")
        }

        if hasCachedFolders {
            do {
                let fastOutput = try runMetadataScriptWithRetry(
                    label: "notes search (quick)",
                    script: fallbackScript,
                    timeoutSeconds: timeoutConfig.fallbackSeconds,
                    attempts: 2
                )
                let decodedFast = try decodeWithRetryIfEmpty(
                    fastOutput,
                    retryLabel: "notes search (quick)",
                    retryScript: fallbackScript,
                    timeoutSeconds: timeoutConfig.fallbackSeconds
                )
                guard hasMeaningfulFolderCoverage(decodedFast) else {
                    throw NotesProviderError.scriptFailed("fast path produced unresolved folder mapping")
                }
                saveMetadataFolderCache(decodedFast)
                return decodedFast
            } catch {
                if verbose {
                    fputs("  Quick scan unavailable, switching to full scan...\n", stderr)
                }
            }
        }

        let output: String
        do {
            output = try runMetadataScriptWithRetry(
                label: "notes search",
                script: fullScript,
                timeoutSeconds: timeoutConfig.fullScanSeconds,
                attempts: 2
            )
        } catch {
            let shouldFallback: Bool
            switch error {
            case NotesProviderError.timeout, NotesProviderError.scriptFailed:
                shouldFallback = true
            default:
                shouldFallback = false
            }

            guard shouldFallback else { throw error }
            if verbose {
                fputs("  Using compatibility scan (folder mapping may be less precise).\n", stderr)
            }

            let fallbackOutput: String
            do {
                fallbackOutput = try runMetadataScriptWithRetry(
                    label: "notes search (compatibility)",
                    script: fallbackScript,
                    timeoutSeconds: timeoutConfig.fallbackSeconds,
                    attempts: 2
                )
            } catch {
                if let emergency = emergencyMetadataFromCount(warmedNoteCount), !emergency.isEmpty {
                    fputs("Emergency scan enabled. Export will use simplified folders.\n", stderr)
                    return emergency
                }
                throw error
            }
            let decodedFallback = try decodeWithRetryIfEmpty(
                fallbackOutput,
                retryLabel: "notes search (compatibility)",
                retryScript: fallbackScript,
                timeoutSeconds: timeoutConfig.fallbackSeconds
            )
            if hasMeaningfulFolderCoverage(decodedFallback) {
                saveMetadataFolderCache(decodedFallback)
            }
            return decodedFallback
        }
        let decoded = try decodeWithRetryIfEmpty(
            output,
            retryLabel: "notes search",
            retryScript: fallbackScript,
            timeoutSeconds: timeoutConfig.fallbackSeconds
        )
        if hasMeaningfulFolderCoverage(decoded) {
            saveMetadataFolderCache(decoded)
        }
        return decoded
    }

    private func decodeNotes(_ raw: String) throws -> [ExportNote] {
        guard let data = raw.data(using: .utf8) else {
            throw NotesProviderError.decodeFailed("No UTF-8 data")
        }
        do {
            return try JSONDecoder().decode([ExportNote].self, from: data)
        } catch {
            throw NotesProviderError.decodeFailed(raw)
        }
    }

    private func metadataTimeoutConfig(noteCount: Int?) -> (fullScanSeconds: Int, fallbackSeconds: Int) {
        guard let n = noteCount, n > 0 else {
            return (120, 180)
        }
        if n >= 800 { return (480, 600) }
        if n >= 400 { return (300, 420) }
        if n >= 200 { return (210, 300) }
        return (120, 180)
    }

    private func warmUpNotesBridge() -> Int? {
        let script = #"var app = Application("Notes"); String(app.notes().length);"#
        let attempts = 2
        for attempt in 1...attempts {
            do {
                let output = try runOsaScript(language: "JavaScript", script: script, timeoutSeconds: 20)
                let count = Int(output.trimmingCharacters(in: .whitespacesAndNewlines))
                return count
            } catch {
                if attempt < attempts {
                    fputs("Preparing Notes connection. Retrying...\n", stderr)
                    Thread.sleep(forTimeInterval: 1.0)
                } else {
                    fputs("Proceeding without warm-up. Full scan may take longer.\n", stderr)
                }
            }
        }
        return nil
    }

    private func emergencyMetadataFromCount(_ count: Int?) -> [ExportNote]? {
        guard let count, count > 0 else { return nil }
        var out: [ExportNote] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            out.append(
                ExportNote(
                    id: "pending-\(i)",
                    sourceIndex: i,
                    title: "Note \(i + 1)",
                    plaintext: "",
                    bodyHTML: "",
                    attachments: nil,
                    account: "Unknown",
                    folderPath: ["Notes"],
                    createdAt: nil,
                    updatedAt: nil
                )
            )
        }
        return out
    }

    private func loadContentBatch(
        sourceIndices: [Int],
        timeoutSeconds: Int,
        includeAttachments: Bool,
        onWait: ((Int) -> Void)?
    ) throws -> [ContentBatchItem] {
        let attachmentsBlock = includeAttachments ? #"""
          var atts = [];
          try { atts = n.attachments(); } catch (_) {}
          for (var j = 0; j < atts.length; j++) {
            var a = atts[j];
            var item = { name: null, uti: null, mimeType: null, base64Data: null };
            try { item.name = String(a.name()); } catch (_) {}
            try { item.uti = String(a.typeIdentifier()); } catch (_) {}
            try { item.mimeType = String(a.mimeType()); } catch (_) {}

            var d = null;
            try { d = a.data(); } catch (_) {}
            if (d) {
              try {
                item.base64Data = ObjC.unwrap(d.base64EncodedStringWithOptions(0));
              } catch (_) {
                try {
                  var nsData = $.NSData.dataWithData(d);
                  item.base64Data = ObjC.unwrap(nsData.base64EncodedStringWithOptions(0));
                } catch (_) {}
              }
            }

            if (item.base64Data && item.base64Data.length > 0) {
              result.attachments.push(item);
            }
          }
        """# : ""

        let script = #"""
        var indices = __INDICES__;
        __IMPORT_FOUNDATION__

        function folderPathFor(note) {
          var path = [];
          var folder = null;
          try { folder = note.folder(); } catch (_) {}
          var guardCount = 0;

          while (folder && guardCount < 32) {
            try {
              var fname = String(folder.name());
              if (fname) { path.unshift(fname); }
            } catch (_) {}

            var parent = null;
            try { parent = folder.container(); } catch (_) {}
            if (!parent) { break; }

            var parentClass = "";
            try { parentClass = String(parent.class()).toLowerCase(); } catch (_) {}
            if (parentClass.indexOf("folder") >= 0) {
              folder = parent;
            } else {
              break;
            }
            guardCount += 1;
          }

          return path;
        }

        function readContent(n, i) {
          var result = { sourceIndex: i, id: null, title: null, plaintext: "", bodyHTML: "", attachments: [], account: null, folderPath: [] };
          try { result.id = String(n.id()); } catch (_) {}
          try { result.title = String(n.name()); } catch (_) {}
          try { result.plaintext = String(n.plaintext()); } catch (_) {}
          try { result.bodyHTML = String(n.body()); } catch (_) {}
          try { result.account = String(n.account().name()); } catch (_) {}
          try { result.folderPath = folderPathFor(n); } catch (_) {}
          __ATTACHMENTS_BLOCK__
          return result;
        }

        var app = Application("Notes");
        var notes = [];
        try { notes = app.notes(); } catch (_) {}

        var out = [];
        for (var k = 0; k < indices.length; k++) {
          var i = indices[k];
          if (typeof i !== "number") { continue; }
          if (i < 0 || i >= notes.length) { continue; }
          out.push(readContent(notes[i], i));
        }

        JSON.stringify(out);
        """#

        let indicesLiteral = "[" + sourceIndices.map(String.init).joined(separator: ",") + "]"
        let rendered = script
            .replacingOccurrences(of: "__INDICES__", with: indicesLiteral)
            .replacingOccurrences(of: "__IMPORT_FOUNDATION__", with: includeAttachments ? "ObjC.import('Foundation');" : "")
            .replacingOccurrences(of: "__ATTACHMENTS_BLOCK__", with: attachmentsBlock)

        let output = try runOsaScript(language: "JavaScript", script: rendered, timeoutSeconds: timeoutSeconds, onWait: onWait)
        guard let data = output.data(using: .utf8) else {
            throw NotesProviderError.decodeFailed("No UTF-8 data for batch content")
        }
        do {
            return try JSONDecoder().decode([ContentBatchItem].self, from: data)
        } catch {
            throw NotesProviderError.decodeFailed(output)
        }
    }

    private func isUnknownPlaceholder(account: String, folderPath: [String]) -> Bool {
        if account != "Unknown" { return false }
        return folderPath == ["Notes"] || folderPath.isEmpty
    }

    private func metadataCacheURL() -> URL? {
        guard let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        return base.appendingPathComponent("notes-matrix", isDirectory: true)
            .appendingPathComponent("metadata-folder-cache.json")
    }

    private func saveMetadataFolderCache(_ notes: [ExportNote]) {
        guard let cacheURL = metadataCacheURL() else { return }

        var map: [String: FolderCacheEntry] = [:]
        map.reserveCapacity(notes.count)
        for note in notes {
            guard !note.id.isEmpty else { continue }
            guard !note.account.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            guard !note.folderPath.isEmpty else { continue }
            guard !isUnknownPlaceholder(account: note.account, folderPath: note.folderPath) else { continue }
            map[note.id] = FolderCacheEntry(account: note.account, folderPath: note.folderPath)
        }
        if map.isEmpty {
            try? FileManager.default.removeItem(at: cacheURL)
            return
        }

        let payload = FolderCachePayload(
            version: 1,
            savedAt: ISO8601DateFormatter().string(from: Date()),
            map: map
        )
        do {
            let parent = cacheURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(payload)
            try data.write(to: cacheURL, options: .atomic)
        } catch {
            // Non-fatal: export should continue even if cache write fails.
        }
    }

    private func loadCachedFolderMap() -> [String: FolderCacheEntry] {
        guard let cacheURL = metadataCacheURL() else { return [:] }
        guard let data = try? Data(contentsOf: cacheURL) else { return [:] }
        guard let payload = try? JSONDecoder().decode(FolderCachePayload.self, from: data) else { return [:] }
        return payload.map.filter { _, entry in
            !isUnknownPlaceholder(account: entry.account, folderPath: entry.folderPath)
        }
    }

    private func runOsaScript(
        language: String,
        script: String,
        timeoutSeconds: Int,
        onWait: ((Int) -> Void)? = nil
    ) throws -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-l", language, "-e", script]

        let stdout = Pipe()
        let stderrPipe = Pipe()
        task.standardOutput = stdout
        task.standardError = stderrPipe

        let outHandle = stdout.fileHandleForReading
        let errHandle = stderrPipe.fileHandleForReading
        let outLock = NSLock()
        let errLock = NSLock()
        var outData = Data()
        var errData = Data()

        outHandle.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            outLock.lock()
            outData.append(chunk)
            outLock.unlock()
        }
        errHandle.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            errLock.lock()
            errData.append(chunk)
            errLock.unlock()
        }

        try task.run()

        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        var lastHeartbeat = Date()
        while task.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
            if Date().timeIntervalSince(lastHeartbeat) >= 5 {
                let elapsed = Int(Date().timeIntervalSince(deadline.addingTimeInterval(TimeInterval(-timeoutSeconds))))
                onWait?(elapsed)
                lastHeartbeat = Date()
            }
        }
        if task.isRunning {
            task.terminate()
            outHandle.readabilityHandler = nil
            errHandle.readabilityHandler = nil
            throw NotesProviderError.timeout(seconds: timeoutSeconds)
        }

        outHandle.readabilityHandler = nil
        errHandle.readabilityHandler = nil

        outLock.lock()
        let finalOut = outData
        outLock.unlock()
        errLock.lock()
        let finalErr = errData
        errLock.unlock()

        let outString = String(decoding: finalOut, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let errString = String(decoding: finalErr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)

        if task.terminationStatus != 0 {
            throw NotesProviderError.scriptFailed(errString.isEmpty ? outString : errString)
        }

        return outString
    }
}

private struct InlineSpinnerRenderer {
    let label: String
    let enabled: Bool
    private var frameIndex: Int = 0
    private let frames = ["|", "/", "-", "\\"]

    init(label: String, enabled: Bool = true) {
        self.label = label
        self.enabled = enabled && isatty(STDERR_FILENO) == 1
    }

    mutating func render(elapsed: Int) {
        guard enabled else { return }
        let frame = frames[frameIndex % frames.count]
        frameIndex += 1
        let line = "\(ANSI.brightGreen)Searching:\(ANSI.reset) \(ANSI.green)\(frame)\(ANSI.reset) \(ANSI.dim)\(label)\(ANSI.reset) \(ANSI.green)\(max(0, elapsed))s\(ANSI.reset)"
        fputs("\r\u{001B}[2K\(line)", stderr)
        fflush(stderr)
    }

    mutating func finish(success: Bool, details: String? = nil) {
        guard enabled else { return }
        let mark = success ? "Done" : "Retrying"
        var line = success
            ? "  \(ANSI.brightGreen)\(mark):\(ANSI.reset) \(ANSI.dim)\(label)\(ANSI.reset)"
            : "\(ANSI.yellow)\(mark):\(ANSI.reset) \(ANSI.dim)\(label)\(ANSI.reset)"
        if let details, !details.isEmpty, !success {
            line += " \(ANSI.yellow)\(details)\(ANSI.reset)"
        }
        fputs("\r\u{001B}[2K\(line)\n", stderr)
        fflush(stderr)
    }
}

private struct InlineStatusRenderer {
    let total: Int
    let enabled: Bool

    init(total: Int) {
        self.total = max(0, total)
        self.enabled = isatty(STDERR_FILENO) == 1
    }

    mutating func render(waitSeconds: Int, done: Int) {
        guard enabled else { return }
        let safeDone = min(max(0, done), total)
        let percent = total == 0 ? 0 : Int((Double(safeDone) / Double(total)) * 100.0)
        let barWidth = 32
        let filled = total == 0 ? 0 : Int((Double(safeDone) / Double(total)) * Double(barWidth))
        let filledBar = String(repeating: "█", count: filled)
        let emptyBar = String(repeating: "░", count: max(0, barWidth - filled))
        let bar = "\(ANSI.brightGreen)\(filledBar)\(ANSI.dim)\(emptyBar)\(ANSI.reset)"
        let progressLine = "  \(ANSI.brightGreen)Progress:\(ANSI.reset) [\(bar)] \(ANSI.brightGreen)\(percent)%\(ANSI.reset) \(ANSI.dim)(\(safeDone)/\(total))\(ANSI.reset)"
        _ = waitSeconds
        fputs("\r\u{001B}[2K\(progressLine)", stderr)
        fflush(stderr)
    }

    mutating func finish(done: Int) {
        guard enabled else { return }
        render(waitSeconds: 0, done: done)
        fputs("\n", stderr)
        fflush(stderr)
    }
}
