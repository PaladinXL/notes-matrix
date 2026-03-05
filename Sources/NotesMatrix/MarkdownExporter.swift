import Foundation
import Darwin

struct ExportResult {
    let notesCount: Int
    let destination: URL
    let mode: ExportMode
}

enum ExportError: Error, CustomStringConvertible {
    case createDirectoryFailed(String)
    case writeFailed(String)
    case zipFailed(String)
    case cleanupFailed(String)

    var description: String {
        switch self {
        case .createDirectoryFailed(let message): return "Directory create failed: \(message)"
        case .writeFailed(let message): return "Write failed: \(message)"
        case .zipFailed(let message): return "Zip failed: \(message)"
        case .cleanupFailed(let message): return "Cleanup failed: \(message)"
        }
    }
}

struct MarkdownExporter {
    private let fileManager = FileManager.default

    private struct SaveProgressRenderer {
        let total: Int
        let enabled: Bool
        private var started: Bool = false

        init(total: Int) {
            self.total = max(0, total)
            self.enabled = isatty(STDOUT_FILENO) == 1
        }

        mutating func render(done: Int) {
            guard enabled else { return }
            let safeDone = min(max(0, done), total)
            let percent = total == 0 ? 0 : Int((Double(safeDone) / Double(total)) * 100.0)
            let barWidth = 32
            let filled = total == 0 ? 0 : Int((Double(safeDone) / Double(total)) * Double(barWidth))
            let filledBar = String(repeating: "█", count: filled)
            let emptyBar = String(repeating: "░", count: max(0, barWidth - filled))
            let bar = "\(ANSI.brightGreen)\(filledBar)\(ANSI.dim)\(emptyBar)\(ANSI.reset)"
            let progressLine = "  \(ANSI.brightGreen)Progress:\(ANSI.reset) [\(bar)] \(ANSI.brightGreen)\(percent)%\(ANSI.reset) \(ANSI.dim)(\(safeDone)/\(total))\(ANSI.reset)"

            if !started { started = true }
            fputs("\r\u{001B}[2K\(progressLine)", stdout)
            fflush(stdout)
        }

        mutating func finish(done: Int) {
            guard enabled else { return }
            render(done: done)
            fputs("\n", stdout)
            fflush(stdout)
        }
    }

    private struct InlineImageResult {
        let html: String
        let detected: Int
        let decoded: Int
        let exported: Int
        let linked: Int
        let skipped: Int
        let skipReasons: [String: Int]
    }

    private struct AttachmentExportSummary {
        let imageEmbeds: [String]
        let fileLinks: [String]
        let exportedCount: Int
        let skippedGraphicItems: [String]
    }

    func export(
        _ notes: [ExportNote],
        to root: URL,
        mode: ExportMode,
        existingPolicy: ExistingItemPolicy = .overwrite,
        filenameMode: FilenameMode = .unicodeSafe,
        includeFrontmatter: Bool = false
    ) throws -> ExportResult {
        let exportRoot = root.appendingPathComponent("notes-export", isDirectory: true)
        try createDirectory(exportRoot)

        var pathCollisions: [String: Int] = [:]
        var folderCache: [String: URL?] = [:]
        var reservedPaths: Set<String> = []
        var saveProgress = SaveProgressRenderer(total: notes.count)
        var processed = 0

        func advanceProgress() {
            processed += 1
            if saveProgress.enabled {
                saveProgress.render(done: processed)
            }
        }

        for (idx, note) in notes.enumerated() {
            let normalizedAccount = repairCommonCyrillicMojibake(note.account)
            let normalizedFolderParts = note.folderPath.map { repairCommonCyrillicMojibake($0) }
            let normalizedTitle = repairCommonCyrillicMojibake(note.title)
            let accountName = safeFileName(normalizedAccount, mode: filenameMode)
            let folderParts = normalizedFolderParts.map { safeFileName($0, mode: filenameMode) }
            guard let folderURL = try resolveFolder(
                exportRoot: exportRoot,
                accountName: accountName,
                folderParts: folderParts,
                policy: existingPolicy,
                cache: &folderCache
            ) else {
                print(ANSI.paint("[skip]", ANSI.dim) + " folder conflict for note '\(note.title)'")
                advanceProgress()
                continue
            }

            let baseName = safeFileName(normalizedTitle.isEmpty ? "Untitled" : normalizedTitle, mode: filenameMode)
            guard let noteURL = resolveNoteURL(
                folderURL: folderURL,
                baseName: baseName,
                accountName: accountName,
                folderParts: folderParts,
                policy: existingPolicy,
                collisions: &pathCollisions,
                reservedPaths: &reservedPaths
            ) else {
                print(ANSI.paint("[skip]", ANSI.dim) + " \(folderURL.path)/\(baseName).md")
                advanceProgress()
                continue
            }
            let noteFileName = noteURL.deletingPathExtension().lastPathComponent

            let htmlSnapshotSaved = writeSourceHTMLIfPresent(note: note, folder: folderURL, noteFileName: noteFileName, policy: existingPolicy)
            let attachmentSummary = exportAttachments(
                note: note,
                baseFolder: folderURL,
                noteFileName: noteFileName,
                policy: existingPolicy,
                filenameMode: filenameMode
            )
            let markdown = buildMarkdown(
                note: note,
                baseFolder: folderURL,
                noteFileName: noteFileName,
                attachmentSummary: attachmentSummary,
                htmlSnapshotSaved: htmlSnapshotSaved,
                includeFrontmatter: includeFrontmatter
            )
            do {
                try markdown.write(to: noteURL, atomically: true, encoding: .utf8)
            } catch {
                throw ExportError.writeFailed(noteURL.path)
            }

            if saveProgress.enabled {
                advanceProgress()
            } else {
                print(ANSI.paint("[\(idx + 1)/\(notes.count)]", ANSI.dim) + " \(noteURL.path)")
                advanceProgress()
            }
        }

        if saveProgress.enabled {
            saveProgress.finish(done: processed)
        }

        if mode == .zip {
            let zipURL = root.appendingPathComponent("notes-export.zip")
            try createZip(from: exportRoot, to: zipURL)
            do {
                try fileManager.removeItem(at: exportRoot)
            } catch {
                throw ExportError.cleanupFailed(exportRoot.path)
            }
            return ExportResult(notesCount: notes.count, destination: zipURL, mode: mode)
        }

        return ExportResult(notesCount: notes.count, destination: exportRoot, mode: mode)
    }

    private func resolveFolder(
        exportRoot: URL,
        accountName: String,
        folderParts: [String],
        policy: ExistingItemPolicy,
        cache: inout [String: URL?]
    ) throws -> URL? {
        var current = exportRoot
        let components = [accountName] + folderParts
        var keyParts: [String] = []

        for component in components {
            keyParts.append(component)
            let key = keyParts.joined(separator: "/")
            if let cached = cache[key] {
                guard let cached else { return nil }
                current = cached
                continue
            }

            let resolved = try resolveDirectoryComponent(parent: current, name: component, policy: policy)
            cache[key] = resolved
            guard let resolved else { return nil }
            current = resolved
        }
        return current
    }

    private func resolveDirectoryComponent(parent: URL, name: String, policy: ExistingItemPolicy) throws -> URL? {
        let target = parent.appendingPathComponent(name, isDirectory: true)
        var isDir: ObjCBool = false
        let exists = fileManager.fileExists(atPath: target.path, isDirectory: &isDir)

        if exists {
            if isDir.boolValue {
                switch policy {
                case .overwrite, .skip:
                    return target
                case .uniquify:
                    return try createUniqueDirectory(parent: parent, baseName: name)
                }
            } else {
                switch policy {
                case .overwrite:
                    try? fileManager.removeItem(at: target)
                    try createDirectory(target)
                    return target
                case .skip:
                    return nil
                case .uniquify:
                    return try createUniqueDirectory(parent: parent, baseName: name)
                }
            }
        } else {
            try createDirectory(target)
            return target
        }
    }

    private func createUniqueDirectory(parent: URL, baseName: String) throws -> URL {
        var suffix = 1
        while true {
            let candidate = parent.appendingPathComponent("\(baseName)-\(suffix)", isDirectory: true)
            if !fileManager.fileExists(atPath: candidate.path) {
                try createDirectory(candidate)
                return candidate
            }
            suffix += 1
        }
    }

    private func resolveNoteURL(
        folderURL: URL,
        baseName: String,
        accountName: String,
        folderParts: [String],
        policy: ExistingItemPolicy,
        collisions: inout [String: Int],
        reservedPaths: inout Set<String>
    ) -> URL? {
        switch policy {
        case .overwrite:
            let relativeKey = ([accountName] + folderParts + [baseName]).joined(separator: "/")
            let uniqueName = uniqueFileName(baseName: baseName, key: relativeKey, collisions: &collisions)
            let url = folderURL.appendingPathComponent("\(uniqueName).md")
            reservedPaths.insert(url.path)
            return url
        case .skip:
            let url = folderURL.appendingPathComponent("\(baseName).md")
            if reservedPaths.contains(url.path) || fileManager.fileExists(atPath: url.path) {
                return nil
            }
            reservedPaths.insert(url.path)
            return url
        case .uniquify:
            var suffix = 0
            while true {
                let stem = suffix == 0 ? baseName : "\(baseName)-\(suffix)"
                let url = folderURL.appendingPathComponent("\(stem).md")
                if !reservedPaths.contains(url.path) && !fileManager.fileExists(atPath: url.path) {
                    reservedPaths.insert(url.path)
                    return url
                }
                suffix += 1
            }
        }
    }

    private func createDirectory(_ url: URL) throws {
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw ExportError.createDirectoryFailed(url.path)
        }
    }

    private func uniqueFileName(baseName: String, key: String, collisions: inout [String: Int]) -> String {
        let current = collisions[key, default: 0]
        collisions[key] = current + 1
        return current == 0 ? baseName : "\(baseName)-\(current)"
    }

    private func buildMarkdown(
        note: ExportNote,
        baseFolder: URL,
        noteFileName: String,
        attachmentSummary: AttachmentExportSummary,
        htmlSnapshotSaved: Bool,
        includeFrontmatter: Bool
    ) -> String {
        let inlineImages = note.bodyHTML.isEmpty
            ? InlineImageResult(html: "", detected: 0, decoded: 0, exported: 0, linked: 0, skipped: 0, skipReasons: [:])
            : extractInlineImagesFromHTML(note.bodyHTML, baseFolder: baseFolder, noteFileName: noteFileName)

        let content: String
        if note.bodyHTML.isEmpty {
            content = note.plaintext
        } else {
            content = htmlToMarkdown(inlineImages.html)
        }
        let normalizedTitle = repairCommonCyrillicMojibake(note.title.isEmpty ? "Untitled" : note.title)
        let normalizedAccount = repairCommonCyrillicMojibake(note.account)
        let normalizedFolder = repairCommonCyrillicMojibake(note.folderPath.joined(separator: "/"))
        let normalizedContent = repairCommonCyrillicMojibake(content)
        let allAssets = inlineImages.exported + attachmentSummary.exportedCount

        let frontmatter: String
        if includeFrontmatter {
            frontmatter = """
            ---
            title: "\(escapeYaml(normalizedTitle))"
            source_account: "\(escapeYaml(normalizedAccount))"
            source_folder: "\(escapeYaml(normalizedFolder))"
            created: "\(note.createdAt ?? "")"
            updated: "\(note.updatedAt ?? "")"
            assets_count: \(allAssets)
            images_inline_count: \(inlineImages.exported + inlineImages.linked + attachmentSummary.imageEmbeds.count)
            raw_html_saved: \(htmlSnapshotSaved)
            ---

            """
        } else {
            frontmatter = ""
        }

        let trimmed = normalizedContent.trimmingCharacters(in: .whitespacesAndNewlines)
        var body = trimmed.isEmpty ? "_(empty note)_" : trimmed
        if !attachmentSummary.imageEmbeds.isEmpty {
            body += "\n\n## Graphics\n" + attachmentSummary.imageEmbeds.joined(separator: "\n")
        }
        if !attachmentSummary.fileLinks.isEmpty {
            body += "\n\n## Attachments\n" + attachmentSummary.fileLinks.map { "- \($0)" }.joined(separator: "\n")
        }

        let skippedGraphicsCount = inlineImages.skipped + attachmentSummary.skippedGraphicItems.count
        if skippedGraphicsCount > 0 {
            body += "\n\n## Graphics Export Report"
            body += "\n- detected img tags: \(inlineImages.detected)"
            body += "\n- decoded base64 images: \(inlineImages.decoded)"
            body += "\n- exported graphics: \(inlineImages.exported + attachmentSummary.imageEmbeds.count)"
            body += "\n- linked graphics (source URL/path): \(inlineImages.linked)"
            body += "\n- skipped graphics: \(skippedGraphicsCount)"
            if !inlineImages.skipReasons.isEmpty {
                let reasonLine = inlineImages.skipReasons
                    .sorted { $0.key < $1.key }
                    .map { "\($0.key)=\($0.value)" }
                    .joined(separator: ", ")
                body += "\n- skip reasons: \(reasonLine)"
            }
            if !attachmentSummary.skippedGraphicItems.isEmpty {
                body += "\n- skipped item names: " + attachmentSummary.skippedGraphicItems.joined(separator: ", ")
            }
            if htmlSnapshotSaved {
                let snapshotRef = encodeMarkdownPathComponent("\(noteFileName).source.html")
                body += "\n- fallback: check [Original HTML](\(snapshotRef))"
            }
        }
        if htmlSnapshotSaved {
            let snapshotRef = encodeMarkdownPathComponent("\(noteFileName).source.html")
            body += "\n\n## Source Snapshot\n- [Original HTML](\(snapshotRef))"
        }
        return frontmatter + body + "\n"
    }

    // Heuristic fix for UTF-8 text that was misinterpreted as Windows-1251
    // (typical mojibake patterns like: "РўРµРєСЃС‚ ...").
    private func repairCommonCyrillicMojibake(_ text: String) -> String {
        let markerPattern = #"(Р.|С.|Ð.|Ñ.)"#
        guard let markerRegex = try? NSRegularExpression(pattern: markerPattern) else {
            return text
        }
        let markerCount = markerRegex.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
        let charCount = max(1, text.count)
        let markerDensity = Double(markerCount) / Double(charCount)
        // Keep exporter "as-is" by default; auto-repair only when mojibake signal is strong.
        guard markerCount >= 6, markerDensity >= 0.15 else { return text }

        guard let cp1251Data = text.data(using: .windowsCP1251),
              let decoded = String(data: cp1251Data, encoding: .utf8) else {
            return text
        }
        let decodedHasCyrillic = decoded.range(of: #"[А-Яа-яЁё]"#, options: .regularExpression) != nil
        let decodedMarkerCount = markerRegex.numberOfMatches(in: decoded, range: NSRange(decoded.startIndex..., in: decoded))
        let decodedHasLessMarkers = decodedMarkerCount < markerCount
        if decodedHasCyrillic && decodedHasLessMarkers {
            return decoded
        }
        return text
    }

    private func htmlToMarkdown(_ html: String) -> String {
        var text = html
        let replacements: [(String, String)] = [
            ("<br>", "\n"), ("<br/>", "\n"), ("<br />", "\n"),
            ("</p>", "\n\n"), ("<p>", ""),
            ("</h1>", "\n\n"), ("<h1>", "# "),
            ("</h2>", "\n\n"), ("<h2>", "## "),
            ("</h3>", "\n\n"), ("<h3>", "### "),
            ("<strong>", "**"), ("</strong>", "**"),
            ("<b>", "**"), ("</b>", "**"),
            ("<em>", "*"), ("</em>", "*"),
            ("<i>", "*"), ("</i>", "*"),
            ("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'")
        ]

        for (needle, value) in replacements {
            text = text.replacingOccurrences(of: needle, with: value, options: [.caseInsensitive])
        }

        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return text
    }

    private func extractInlineImagesFromHTML(_ html: String, baseFolder: URL, noteFileName: String) -> InlineImageResult {
        let regex = try? NSRegularExpression(
            pattern: #"<img\b[^>]*>"#,
            options: [.caseInsensitive]
        )
        guard let regex else {
            return InlineImageResult(html: html, detected: 0, decoded: 0, exported: 0, linked: 0, skipped: 0, skipReasons: [:])
        }

        let fullRange = NSRange(location: 0, length: html.utf16.count)
        let matches = regex.matches(in: html, options: [], range: fullRange)
        if matches.isEmpty {
            return InlineImageResult(html: html, detected: 0, decoded: 0, exported: 0, linked: 0, skipped: 0, skipReasons: [:])
        }

        let assetsDir = baseFolder.appendingPathComponent("assets", isDirectory: true).appendingPathComponent(noteFileName, isDirectory: true)
        try? fileManager.createDirectory(at: assetsDir, withIntermediateDirectories: true)

        var rendered = html
        let detected = matches.count
        var decoded = 0
        var exported = 0
        var linked = 0
        var skipped = 0
        var skipReasons: [String: Int] = [:]

        func markSkipped(_ reason: String) {
            skipped += 1
            skipReasons[reason, default: 0] += 1
        }

        for (idx, match) in matches.enumerated().reversed() {
            guard let tagRange = Range(match.range(at: 0), in: rendered) else {
                markSkipped("tag_range")
                continue
            }
            let tag = String(rendered[tagRange])
            guard let src = extractHTMLAttribute("src", fromTag: tag), !src.isEmpty else {
                markSkipped("no_src")
                continue
            }
            let altText = (extractHTMLAttribute("alt", fromTag: tag) ?? "image-\(idx + 1)")
                .replacingOccurrences(of: "\n", with: " ")

            let replacement: String
            if let parsed = parseDataImageSource(src) {
                // Apple Notes can include line wraps/escaped chars inside data:image payload.
                let normalized = normalizeBase64(parsed.base64)
                guard let data = Data(base64Encoded: normalized, options: [.ignoreUnknownCharacters]) else {
                    markSkipped("invalid_base64")
                    continue
                }
                decoded += 1

                let ext = sanitizeImageExtension(parsed.ext.lowercased())
                let imageName = "image-\(idx + 1).\(ext)"
                let imageURL = assetsDir.appendingPathComponent(imageName)
                do {
                    try data.write(to: imageURL)
                } catch {
                    markSkipped("write_failed")
                    continue
                }
                let rel = markdownAssetPath(noteFileName: noteFileName, filename: imageName)
                replacement = "![\(altText)](\(rel))"
                exported += 1
            } else {
                replacement = "![\(altText)](\(src))"
                linked += 1
            }

            rendered.replaceSubrange(tagRange, with: replacement)
        }
        return InlineImageResult(
            html: rendered,
            detected: detected,
            decoded: decoded,
            exported: exported,
            linked: linked,
            skipped: skipped,
            skipReasons: skipReasons
        )
    }

    private func extractHTMLAttribute(_ attribute: String, fromTag tag: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: attribute)
        let quotedPattern = "\\b\(escaped)\\s*=\\s*(['\"])(.*?)\\1"
        guard let quotedRegex = try? NSRegularExpression(
            pattern: quotedPattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return nil }
        let range = NSRange(location: 0, length: tag.utf16.count)
        if let match = quotedRegex.firstMatch(in: tag, options: [], range: range),
           let valueRange = Range(match.range(at: 2), in: tag) {
            return String(tag[valueRange])
        }

        // Fallback for unquoted attributes: src=data:image/... (stop at whitespace or >)
        let unquotedPattern = "\\b\(escaped)\\s*=\\s*([^\\s>]+)"
        guard let unquotedRegex = try? NSRegularExpression(pattern: unquotedPattern, options: [.caseInsensitive]),
              let match = unquotedRegex.firstMatch(in: tag, options: [], range: range),
              let valueRange = Range(match.range(at: 1), in: tag) else { return nil }
        return String(tag[valueRange])
    }

    private func parseDataImageSource(_ src: String) -> (ext: String, base64: String)? {
        let pattern = #"^data:image/([a-zA-Z0-9+.-]+);base64,(.+)$"#
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return nil }
        let decodedSrc = decodeMinimalHTMLEntities(src)
        let decodedRange = NSRange(location: 0, length: decodedSrc.utf16.count)
        guard let match = regex.firstMatch(in: decodedSrc, options: [], range: decodedRange),
              let extRange = Range(match.range(at: 1), in: decodedSrc),
              let dataRange = Range(match.range(at: 2), in: decodedSrc) else {
            return nil
        }
        return (
            ext: String(decodedSrc[extRange]),
            base64: String(decodedSrc[dataRange])
        )
    }

    private func normalizeBase64(_ value: String) -> String {
        value.replacingOccurrences(of: #"[ \t\r\n]+"#, with: "", options: .regularExpression)
    }

    private func decodeMinimalHTMLEntities(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
    }

    private func writeSourceHTMLIfPresent(note: ExportNote, folder: URL, noteFileName: String, policy: ExistingItemPolicy) -> Bool {
        let raw = note.bodyHTML.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { return false }
        let normalizedHTML = repairCommonCyrillicMojibake(raw)
        let documentHTML = sourceSnapshotDocument(from: normalizedHTML)

        let htmlURL = folder.appendingPathComponent("\(noteFileName).source.html")
        if policy == .skip && fileManager.fileExists(atPath: htmlURL.path) {
            return true
        }
        do {
            try documentHTML.write(to: htmlURL, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    private func sourceSnapshotDocument(from htmlFragment: String) -> String {
        let lower = htmlFragment.lowercased()
        if lower.contains("<html") {
            if lower.contains("charset=") { return htmlFragment }
            if let headRange = htmlFragment.range(of: "<head[^>]*>", options: [.regularExpression, .caseInsensitive]) {
                let insertion = "\n<meta charset=\"utf-8\">"
                var out = htmlFragment
                out.insert(contentsOf: insertion, at: headRange.upperBound)
                return out
            }
            if let htmlOpen = htmlFragment.range(of: "<html[^>]*>", options: [.regularExpression, .caseInsensitive]) {
                let insertion = "\n<head><meta charset=\"utf-8\"></head>"
                var out = htmlFragment
                out.insert(contentsOf: insertion, at: htmlOpen.upperBound)
                return out
            }
            return htmlFragment
        }

        return """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>Notes Snapshot</title>
        </head>
        <body>
        \(htmlFragment)
        </body>
        </html>
        """
    }

    private func exportAttachments(
        note: ExportNote,
        baseFolder: URL,
        noteFileName: String,
        policy: ExistingItemPolicy,
        filenameMode: FilenameMode
    ) -> AttachmentExportSummary {
        guard let attachments = note.attachments, !attachments.isEmpty else {
            return AttachmentExportSummary(imageEmbeds: [], fileLinks: [], exportedCount: 0, skippedGraphicItems: [])
        }

        let assetsDir = baseFolder.appendingPathComponent("assets", isDirectory: true).appendingPathComponent(noteFileName, isDirectory: true)
        try? fileManager.createDirectory(at: assetsDir, withIntermediateDirectories: true)

        var imageEmbeds: [String] = []
        var fileLinks: [String] = []
        var exportedCount = 0
        var skippedGraphicItems: [String] = []
        for (idx, attachment) in attachments.enumerated() {
            let ext = preferredExtension(name: attachment.name, mimeType: attachment.mimeType, uti: attachment.uti)
            let base = safeFileName((attachment.name?.isEmpty == false ? attachment.name! : "attachment-\(idx + 1)"), mode: filenameMode)
            let filename = base.hasSuffix(".\(ext)") ? base : "\(base).\(ext)"
            let imageCandidate = isImageAttachment(ext: ext, mimeType: attachment.mimeType, uti: attachment.uti)

            guard let b64 = attachment.base64Data, let data = Data(base64Encoded: b64) else {
                if imageCandidate { skippedGraphicItems.append(filename) }
                continue
            }
            let outURL = assetsDir.appendingPathComponent(filename)

            if policy == .skip && fileManager.fileExists(atPath: outURL.path) {
                let rel = markdownAssetPath(noteFileName: noteFileName, filename: filename)
                if isImageExt(ext) {
                    imageEmbeds.append("![\(filename)](\(rel))")
                } else {
                    fileLinks.append("[\(filename)](\(rel))")
                }
                exportedCount += 1
                continue
            }

            do {
                try data.write(to: outURL)
            } catch {
                if imageCandidate { skippedGraphicItems.append(filename) }
                continue
            }

            let rel = markdownAssetPath(noteFileName: noteFileName, filename: filename)
            if isImageExt(ext) {
                imageEmbeds.append("![\(filename)](\(rel))")
            } else {
                fileLinks.append("[\(filename)](\(rel))")
            }
            exportedCount += 1
        }
        return AttachmentExportSummary(
            imageEmbeds: imageEmbeds,
            fileLinks: fileLinks,
            exportedCount: exportedCount,
            skippedGraphicItems: skippedGraphicItems
        )
    }

    private func preferredExtension(name: String?, mimeType: String?, uti: String?) -> String {
        if let name, let dot = name.lastIndex(of: "."), dot < name.endIndex {
            let ext = String(name[name.index(after: dot)...]).lowercased()
            if !ext.isEmpty && ext.count <= 8 { return ext }
        }
        if let mimeType {
            let map: [String: String] = [
                "image/png": "png",
                "image/jpeg": "jpg",
                "image/jpg": "jpg",
                "image/gif": "gif",
                "image/heic": "heic",
                "application/pdf": "pdf"
            ]
            if let ext = map[mimeType.lowercased()] { return ext }
        }
        if let uti {
            let lower = uti.lowercased()
            if lower.contains("png") { return "png" }
            if lower.contains("jpeg") || lower.contains("jpg") { return "jpg" }
            if lower.contains("gif") { return "gif" }
            if lower.contains("heic") { return "heic" }
            if lower.contains("pdf") { return "pdf" }
        }
        return "bin"
    }

    private func isImageExt(_ ext: String) -> Bool {
        let e = ext.lowercased()
        return e == "png" || e == "jpg" || e == "jpeg" || e == "gif" || e == "heic" || e == "webp"
    }

    private func isImageAttachment(ext: String, mimeType: String?, uti: String?) -> Bool {
        if isImageExt(ext) { return true }
        if let mimeType, mimeType.lowercased().hasPrefix("image/") { return true }
        if let uti, uti.lowercased().contains("image") { return true }
        return false
    }

    private func sanitizeImageExtension(_ ext: String) -> String {
        let cleaned = ext.replacingOccurrences(of: #"[^a-z0-9]"#, with: "", options: .regularExpression)
        return cleaned.isEmpty ? "png" : cleaned
    }

    private func markdownAssetPath(noteFileName: String, filename: String) -> String {
        let base = encodeMarkdownPathComponent(noteFileName)
        let file = encodeMarkdownPathComponent(filename)
        return "assets/\(base)/\(file)"
    }

    private func encodeMarkdownPathComponent(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private func createZip(from sourceDir: URL, to zipURL: URL) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        task.arguments = ["-qry", zipURL.path, "."]
        task.currentDirectoryURL = sourceDir

        let stderr = Pipe()
        task.standardError = stderr

        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            throw ExportError.zipFailed("Unable to start /usr/bin/zip")
        }

        if task.terminationStatus != 0 {
            let err = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw ExportError.zipFailed(err.isEmpty ? "zip exited with \(task.terminationStatus)" : err)
        }
    }

    private func safeFileName(_ raw: String, mode: FilenameMode) -> String {
        let source = mode == .asciiTranslit ? transliterateCyrillic(raw) : raw

        // Replace characters that commonly break file/path creation on macOS and cross-platform tools.
        let forbidden = CharacterSet(charactersIn: "/:\\?%*|\"<>")
            .union(.newlines)
            .union(.controlCharacters)

        var result = ""
        var lastWasUnderscore = false
        for scalar in source.unicodeScalars {
            let isForbidden = forbidden.contains(scalar)
            if isForbidden {
                if !lastWasUnderscore {
                    result.append("_")
                    lastWasUnderscore = true
                }
            } else {
                if mode == .asciiTranslit && !scalar.isASCII {
                    if !lastWasUnderscore {
                        result.append("_")
                        lastWasUnderscore = true
                    }
                } else {
                    result.unicodeScalars.append(scalar)
                    lastWasUnderscore = false
                }
            }
        }

        // Collapse accidental repeated underscores.
        result = result.replacingOccurrences(of: "_{2,}", with: "_", options: .regularExpression)

        // Avoid invisible/edge names and trailing spaces/dots.
        let edgeTrim = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "._"))
        result = result.trimmingCharacters(in: edgeTrim)

        // Normalize Unicode for cross-platform consistency.
        result = result.precomposedStringWithCanonicalMapping

        if isWindowsReservedName(result) {
            result = "_\(result)"
        }

        // Keep names manageable for Windows/macOS path handling.
        let maxLen = 120
        if result.count > maxLen {
            result = String(result.prefix(maxLen)).trimmingCharacters(in: edgeTrim)
        }

        if result.isEmpty || result == "." || result == ".." {
            return "untitled"
        }
        return result
    }

    private func isWindowsReservedName(_ value: String) -> Bool {
        let base = value.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? value
        let upper = base.uppercased()
        let reserved: Set<String> = [
            "CON", "PRN", "AUX", "NUL",
            "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
            "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9"
        ]
        return reserved.contains(upper)
    }

    private func transliterateCyrillic(_ value: String) -> String {
        let map: [Character: String] = [
            "а":"a","б":"b","в":"v","г":"g","д":"d","е":"e","ё":"e","ж":"zh","з":"z","и":"i","й":"y",
            "к":"k","л":"l","м":"m","н":"n","о":"o","п":"p","р":"r","с":"s","т":"t","у":"u","ф":"f",
            "х":"h","ц":"ts","ч":"ch","ш":"sh","щ":"sch","ъ":"","ы":"y","ь":"","э":"e","ю":"yu","я":"ya",
            "А":"A","Б":"B","В":"V","Г":"G","Д":"D","Е":"E","Ё":"E","Ж":"Zh","З":"Z","И":"I","Й":"Y",
            "К":"K","Л":"L","М":"M","Н":"N","О":"O","П":"P","Р":"R","С":"S","Т":"T","У":"U","Ф":"F",
            "Х":"H","Ц":"Ts","Ч":"Ch","Ш":"Sh","Щ":"Sch","Ъ":"","Ы":"Y","Ь":"","Э":"E","Ю":"Yu","Я":"Ya"
        ]

        var out = ""
        for ch in value {
            if let rep = map[ch] {
                out += rep
            } else {
                out.append(ch)
            }
        }
        return out
    }

    private func escapeYaml(_ value: String) -> String {
        value.replacingOccurrences(of: "\"", with: "\\\"")
    }
}
