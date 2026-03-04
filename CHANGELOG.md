# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- Matrix-style interactive TUI dashboard
- Apple Notes scan and export workflows
- Markdown export preserving folder hierarchy
- Optional zip export mode
- Fast vs deep attachment extraction modes
- Raw HTML snapshot (`*.source.html`) fallback for visual fidelity
- Open-source project docs and GitHub templates
- Existing target policy for export conflicts:
  - `overwrite` (default)
  - `skip`
  - `uniquify` (`-1`, `-2`, ...)
- Filename mode for cross-platform portability:
  - `unicode` (default)
  - `ascii` (Cyrillic transliteration)
- Incremental export mode:
  - CLI flag `--incremental`
  - TUI selector for `off/on`
  - manifest file at `<output>/.notes-matrix-manifest.json`
- Metadata folder cache in `~/Library/Caches/notes-matrix/metadata-folder-cache.json`
  for better resilience and faster repeated exports

### Changed
- TUI now exposes existing-item policy as a first-class menu setting.
- CLI `export` supports `--on-existing overwrite|skip|uniquify`.
- CLI `export` supports `--filename-mode unicode|ascii`.
- Progress feedback redesigned:
  - metadata scan uses inline spinner
  - content load uses inline matrix-style progress bar
- Status coloring tuned for readability (`[stage]`, `[done]`, and wait seconds in green).
- Content loading can read selected source indices (used by incremental export).
- License changed from MIT to a non-commercial license:
  - free use allowed
  - commercial use/sale requires written permission

### Fixed
- Filename/folder sanitization is stricter and safer:
  - invalid path characters replaced with `_`
  - control characters/newlines sanitized
  - edge cases like empty names and `.` / `..` normalized
- Reduced noisy multiline wait/progress output in TTY mode.
- Folder hierarchy recovery is more robust after metadata timeouts:
  - content batches now include account/folder path hints
  - unresolved `Unknown/Notes` mapping is no longer persisted in metadata cache
  - fast metadata path auto-falls back to full scan when folder coverage is unresolved
