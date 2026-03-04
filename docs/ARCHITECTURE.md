# Architecture

## Overview

`notes-matrix` is a Swift CLI/TUI that exports Apple Notes into Markdown files.

Core flow:

1. Read metadata and content from Apple Notes through JXA (`osascript`).
2. Convert note body HTML into lightweight Markdown.
3. Export notes into folder tree:
   - `Account/Folder/Subfolder/Note.md`
   - `assets/<note>/...` for extracted media and attachments
4. Optionally create `notes-export.zip`.

## Modules

- `main.swift`
  - Interactive dashboard
  - Non-interactive commands (`scan`, `export`)
- `AppleNotesProvider.swift`
  - Accesses Apple Notes via JXA scripts
  - Supports `scan` and `fullExport` modes
  - Supports fast/deep attachment extraction behavior
- `MarkdownExporter.swift`
  - Builds Markdown frontmatter and body
  - Extracts inline base64 images
  - Writes source HTML snapshots
  - Writes zip archive
- `Models.swift`
  - Shared data models between provider and exporter
- `Ansi.swift`
  - Terminal styling utilities

## Runtime constraints

- macOS only
- Automation permission to control Notes is required
- Notes API is script-based; behavior may vary across macOS versions

