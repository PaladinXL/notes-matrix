# Notes Matrix

`notes-matrix` is a macOS Swift CLI/TUI that exports Apple Notes to Markdown
while preserving account/folder hierarchy.

> [![CI](https://github.com/PaladinXL/notes-matrix/actions/workflows/ci.yml/badge.svg)](https://github.com/PaladinXL/notes-matrix/actions/workflows/ci.yml)
> ![Platform](https://img.shields.io/badge/platform-macOS-0f172a)
> ![Swift](https://img.shields.io/badge/swift-5.9+-F05138)
> ![License: Non--Commercial](https://img.shields.io/badge/license-non--commercial-red)

## Why

Apple Notes does not provide a direct Markdown export path for full notebooks.
This tool focuses on practical migration and backup workflows for Obsidian-like
vault structures.

## Quick Start

Install via Homebrew (recommended):

```bash
brew tap PaladinXL/notes-matrix
brew install notes-matrix
# after install, command is available globally
notes-matrix help
notes-matrix
```

Build from source:

```bash
swift build
swift run notes-matrix
```

In TUI:

1. `Set Output Path`
2. `Select Attachments Mode` -> choose `deep` if you need graphics extraction
3. `Run Export`

If you prefer CLI:

```bash
swift run notes-matrix export --output /absolute/path --with-attachments
```

## Features

- Interactive TUI dashboard
- Non-interactive CLI commands
- Hierarchy-preserving export:
  - `Account/Folder/Subfolder/Note.md`
- Optional zip packaging
- Inline base64 image extraction
- Optional deep attachment extraction
- Raw HTML sidecar fallback (`Note.source.html`) for visual fidelity
- Existing-target policy controls (`overwrite` / `skip` / `uniquify`)
- Live matrix-style progress UI (spinner + inline progress bar)

## Requirements

- macOS (Apple Notes is required)
- Swift toolchain (Xcode CLT is enough)
- Notes automation permission for terminal app
- Homebrew (optional, for package-manager install)

## Build

```bash
swift build -c release
```

## Run

Interactive:

```bash
swift run notes-matrix
```

Non-interactive:

```bash
swift run notes-matrix scan
swift run notes-matrix export --output /absolute/path
swift run notes-matrix export --output /absolute/path --zip
swift run notes-matrix export --output /absolute/path --with-attachments
swift run notes-matrix export --output /absolute/path --on-existing overwrite
swift run notes-matrix export --output /absolute/path --on-existing skip
swift run notes-matrix export --output /absolute/path --on-existing uniquify
swift run notes-matrix export --output /absolute/path --filename-mode unicode
swift run notes-matrix export --output /absolute/path --filename-mode ascii
swift run notes-matrix export --output /absolute/path --incremental
swift run notes-matrix export --output /absolute/path --with-attachments --incremental
```

CLI reference:

```bash
swift run notes-matrix help
```

Or run binary directly after build:

```bash
.build/debug/notes-matrix export --output /absolute/path
```

## Update

Update Homebrew package:

```bash
brew update
brew upgrade notes-matrix
```

If tap metadata is stale:

```bash
brew update-reset
brew untap PaladinXL/notes-matrix
brew tap PaladinXL/notes-matrix
brew upgrade notes-matrix
```

## Graphics in Markdown

To maximize image transfer from Apple Notes into `.md`, use `deep` mode
(`--with-attachments`).

Expected result:

- Markdown contains `![](...)` image links
- image files are written under `assets/...`
- `*.source.html` stays as fallback for unsupported rich objects

## Performance Notes

`notes-matrix` reads Apple Notes through macOS Automation (`osascript`/JXA).
On large notebooks this can be slow, especially in `deep` mode.

Why it may take longer:

- Apple Notes automation calls are IPC-heavy
- metadata scan may need retries/timeouts before fallback path
- `deep` mode extracts attachments/graphics and processes base64 payloads

Practical recommendation:

- Use `fast` for daily backups
- Use `deep` when you specifically need image/attachment extraction
- Keep Apple Notes app open during export for better stability
- Enable `--incremental` after first full export to process only changed notes
- Metadata folder mapping is cached locally to improve resilience on metadata timeouts

## Modes

- `fast` (default): quicker export, keeps raw HTML sidecar fallback
- `deep` (`--with-attachments`): slower, attempts full binary attachment export

Existing target behavior (`--on-existing`):

- `overwrite` (default): reuse/replace existing files and folders
- `skip`: do nothing for conflicting targets
- `uniquify`: create new names with numeric suffixes (`-1`, `-2`, ...)

Filename behavior (`--filename-mode`):

- `unicode` (default): keep Unicode/Cyrillic names with cross-platform sanitization
- `ascii`: transliterate names to ASCII for maximum portability

Progress UI:

- metadata scan: inline spinner
- content loading: inline matrix-style progress bar with percentage and note counters

Incremental behavior (`--incremental`):

- first run exports all notes and creates `<output>/.notes-matrix-manifest.json`
- next runs compare note metadata (`updatedAt`, folder/account, title) and export only changed notes
- if mode/settings change (attachments, filename mode, export mode), tool performs full export

Metadata cache behavior:

- folder mapping cache is stored in `~/Library/Caches/notes-matrix/metadata-folder-cache.json`
- unresolved placeholder paths (`Unknown/Notes`) are not persisted to cache
- if fast metadata path returns unresolved mapping, exporter falls back to full scan automatically

Reset cache (if you ever see a flat `Unknown/Notes` export):

```bash
rm -f ~/Library/Caches/notes-matrix/metadata-folder-cache.json
```

## Output

- Folder mode:
  - `<output>/notes-export/...`
- Zip mode:
  - `<output>/notes-export.zip`
- Markdown notes include YAML frontmatter metadata.

## Publish to GitHub (From Zero)

If this folder is not yet a git repository:

```bash
git init
git add .
git commit -m "chore: initial public release"
```

Create an empty GitHub repo (for example `notes-matrix`), then:

```bash
git branch -M main
git remote add origin git@github.com:<your-username>/notes-matrix.git
git push -u origin main
```

Before first public push, run:

```bash
git ls-files | rg -n "\\.DS_Store|\\.build/" || true
rg -n "(api[_-]?key|token|secret|password|BEGIN (RSA|OPENSSH|EC|PGP) PRIVATE KEY|sk-|ctx7sk-)" -S . || true
```

For full step-by-step release and protection settings:

- `docs/GITHUB_SETUP.md`
- `docs/HOMEBREW.md`

## Limitations

- Access is based on JXA (`osascript`), not a first-party Notes SDK.
- Some rich constructs may be represented better in `.source.html`.
- Deep attachment extraction depends on what Notes scripting exposes.

## Documentation

- Architecture: `docs/ARCHITECTURE.md`
- Troubleshooting: `docs/TROUBLESHOOTING.md`
- Releasing: `docs/RELEASING.md`
- Homebrew distribution: `docs/HOMEBREW.md`
- GitHub setup: `docs/GITHUB_SETUP.md`
- Changelog: `CHANGELOG.md`

## Contributing

See `CONTRIBUTING.md`.

## Security

See `SECURITY.md`.

## License

This project is licensed under the `Notes Matrix Non-Commercial License v1.0`
(`LICENSE`).

In short:

- free use is allowed;
- commercial use/sale is not allowed without written permission.

Commercial licensing contact:

- Telegram: [@darthlogic](https://t.me/darthlogic)
