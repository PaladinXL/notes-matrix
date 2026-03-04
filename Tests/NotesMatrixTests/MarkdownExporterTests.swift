import Foundation
import Testing
@testable import NotesMatrix

struct MarkdownExporterTests {
    private let account = "On My Mac"
    private let folderPath = ["Notes"]

    @Test
    func dataImageDoubleQuotedSrcExportsMarkdownImage() throws {
        let note = makeNote(
            title: "Quoted PNG",
            bodyHTML: #"<div><img src="data:image/png;base64,aGVsbG8="></div>"#
        )
        let output = try exportSingle(note)

        #expect(output.markdown.contains("!["))
        #expect(output.markdown.contains("assets/"))
        #expect(output.markdown.contains("assets_count: 1"))
        #expect(output.markdown.contains("images_inline_count: 1"))
        #expect(fileExists(output.assetFiles.first))
    }

    @Test
    func dataImageSingleQuotedSrcExportsMarkdownImage() throws {
        let note = makeNote(
            title: "Single Quote JPEG",
            bodyHTML: #"<div><img src='data:image/jpeg;base64,aGVsbG8='></div>"#
        )
        let output = try exportSingle(note)

        #expect(output.markdown.contains("!["))
        #expect(output.markdown.contains(".jpeg"))
        #expect(output.markdown.contains("assets_count: 1"))
    }

    @Test
    func dataImageUnquotedSrcExportsMarkdownImage() throws {
        let note = makeNote(
            title: "Unquoted Source",
            bodyHTML: #"<div><img src=data:image/png;base64,aGVsbG8=></div>"#
        )
        let output = try exportSingle(note)

        #expect(output.markdown.contains("!["))
        #expect(output.markdown.contains("assets_count: 1"))
    }

    @Test
    func multilineAndWhitespaceBase64StillDecodes() throws {
        let multiline = "aGVs\nbG8=\t "
        let note = makeNote(
            title: "Multiline Base64",
            bodyHTML: #"<div><img src="data:image/png;base64,\#(multiline)"></div>"#
        )
        let output = try exportSingle(note)

        #expect(output.markdown.contains("assets_count: 1"))
        #expect(output.markdown.contains("images_inline_count: 1"))
    }

    @Test
    func brokenBase64IsReportedAsSkippedWithReason() throws {
        let note = makeNote(
            title: "Broken Base64",
            bodyHTML: #"<div><img src="data:image/png;base64,%%%NOT_BASE64%%%"></div>"#
        )
        let output = try exportSingle(note)

        #expect(output.markdown.contains("## Graphics Export Report"))
        #expect(output.markdown.contains("detected img tags: 1"))
        #expect(output.markdown.contains("decoded base64 images: 0"))
        #expect(output.markdown.contains("skipped graphics: 1"))
        #expect(output.markdown.contains("skip reasons: invalid_base64=1"))
    }

    @Test
    func externalImageLinkIsKeptAsIs() throws {
        let note = makeNote(
            title: "External URL",
            bodyHTML: #"<div><img src="https://example.com/image.png"></div>"#
        )
        let output = try exportSingle(note)

        #expect(output.markdown.contains("![image-1](https://example.com/image.png)"))
        #expect(output.markdown.contains("images_inline_count: 1"))
    }

    @Test
    func unicodeAndSpaceTitleUsesEncodedAssetPath() throws {
        let note = makeNote(
            title: "Тест заметка 1",
            bodyHTML: #"<div><img src="data:image/png;base64,aGVsbG8="></div>"#
        )
        let output = try exportSingle(note)

        #expect(output.markdown.contains("assets/"))
        #expect(output.markdown.contains("%20"))
        #expect(output.markdown.contains("%"))
    }

    private func makeNote(title: String, bodyHTML: String) -> ExportNote {
        ExportNote(
            id: UUID().uuidString,
            sourceIndex: 0,
            title: title,
            plaintext: "",
            bodyHTML: bodyHTML,
            attachments: nil,
            account: account,
            folderPath: folderPath,
            createdAt: nil,
            updatedAt: nil
        )
    }

    private func exportSingle(_ note: ExportNote) throws -> (markdown: String, assetFiles: [URL]) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notes-matrix-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let exporter = MarkdownExporter()
        _ = try exporter.export([note], to: root, mode: .folderTree, existingPolicy: .overwrite, filenameMode: .unicodeSafe)

        let exportRoot = root.appendingPathComponent("notes-export", isDirectory: true)
        let mdFile = try findFirstFile(withExtension: "md", under: exportRoot)
        let markdown = try String(contentsOf: mdFile, encoding: .utf8)

        let assetsDir = mdFile.deletingPathExtension().deletingLastPathComponent()
            .appendingPathComponent("assets", isDirectory: true)
            .appendingPathComponent(mdFile.deletingPathExtension().lastPathComponent, isDirectory: true)

        let assetFiles: [URL]
        if let enumerator = FileManager.default.enumerator(at: assetsDir, includingPropertiesForKeys: nil) {
            assetFiles = enumerator.compactMap { $0 as? URL }
        } else {
            assetFiles = []
        }

        return (markdown: markdown, assetFiles: assetFiles)
    }

    private func findFirstFile(withExtension ext: String, under root: URL) throws -> URL {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            throw NSError(domain: "MarkdownExporterTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Enumerator failed"])
        }
        for case let url as URL in enumerator {
            if url.pathExtension == ext {
                return url
            }
        }
        throw NSError(domain: "MarkdownExporterTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "No .\(ext) file found"])
    }

    private func fileExists(_ url: URL?) -> Bool {
        guard let url else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }
}
