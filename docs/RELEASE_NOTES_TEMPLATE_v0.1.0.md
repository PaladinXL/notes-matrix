# Notes Matrix v0.1.0

First public release of `notes-matrix`.

## Highlights

- Interactive matrix-style TUI dashboard
- Apple Notes scan and export flow
- Markdown export with account/folder hierarchy
- Fast and deep attachment modes
- Optional zip packaging
- Raw HTML sidecar fallback for visual fidelity

## Added

- CLI commands:
  - `scan`
  - `export --output <path>`
  - `export --zip`
  - `export --with-attachments`
- TUI settings:
  - output path
  - export mode (`tree`/`zip`)
  - attachments mode (`fast`/`deep`)
- GitHub project scaffolding:
  - CI workflow
  - issue templates
  - pull request template
  - contributing/security/code of conduct docs

## Known limitations

- Apple Notes access is script-based (JXA/`osascript`), not an official Notes SDK.
- Rich formatting fidelity is best preserved through `.source.html` fallback.

## Upgrade notes

No migration required for first release.

