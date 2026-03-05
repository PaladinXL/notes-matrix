import Foundation
import Testing
@testable import NotesMatrix

struct IncrementalModeTests {
    @Test
    func changedNotesReturnsAllWhenManifestMissing() {
        let notes = [makeNote(id: "1", title: "A", updatedAt: "2026-01-01T10:00:00Z")]
        let context = NotesMatrixCLI.IncrementalContext(
            includeAttachments: true,
            filenameMode: .unicodeSafe,
            includeFrontmatter: false,
            mode: .folderTree
        )

        let changed = NotesMatrixCLI.changedNotes(metadata: notes, manifest: nil, context: context)
        #expect(changed.count == 1)
        #expect(changed.first?.id == "1")
    }

    @Test
    func changedNotesReturnsEmptyWhenManifestMatches() {
        let notes = [makeNote(id: "1", title: "A", updatedAt: "2026-01-01T10:00:00Z")]
        let manifest = NotesMatrixCLI.ExportManifest(
            version: 1,
            includeAttachments: true,
            filenameMode: .unicodeSafe,
            includeFrontmatter: false,
            mode: .folderTree,
            notes: [
                NotesMatrixCLI.ManifestEntry(
                    id: "1",
                    updatedAt: "2026-01-01T10:00:00Z",
                    account: "On My Mac",
                    folderPath: ["Notes"],
                    title: "A"
                )
            ]
        )
        let context = NotesMatrixCLI.IncrementalContext(
            includeAttachments: true,
            filenameMode: .unicodeSafe,
            includeFrontmatter: false,
            mode: .folderTree
        )

        let changed = NotesMatrixCLI.changedNotes(metadata: notes, manifest: manifest, context: context)
        #expect(changed.isEmpty)
    }

    @Test
    func changedNotesReturnsAllWhenContextDiffers() {
        let notes = [makeNote(id: "1", title: "A", updatedAt: "2026-01-01T10:00:00Z")]
        let manifest = NotesMatrixCLI.ExportManifest(
            version: 1,
            includeAttachments: false,
            filenameMode: .unicodeSafe,
            includeFrontmatter: false,
            mode: .folderTree,
            notes: [
                NotesMatrixCLI.ManifestEntry(
                    id: "1",
                    updatedAt: "2026-01-01T10:00:00Z",
                    account: "On My Mac",
                    folderPath: ["Notes"],
                    title: "A"
                )
            ]
        )
        let context = NotesMatrixCLI.IncrementalContext(
            includeAttachments: true,
            filenameMode: .unicodeSafe,
            includeFrontmatter: false,
            mode: .folderTree
        )

        let changed = NotesMatrixCLI.changedNotes(metadata: notes, manifest: manifest, context: context)
        #expect(changed.count == 1)
    }

    private func makeNote(id: String, title: String, updatedAt: String?) -> ExportNote {
        ExportNote(
            id: id,
            sourceIndex: 0,
            title: title,
            plaintext: "",
            bodyHTML: "",
            attachments: nil,
            account: "On My Mac",
            folderPath: ["Notes"],
            createdAt: nil,
            updatedAt: updatedAt
        )
    }
}
