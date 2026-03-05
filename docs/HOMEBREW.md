# Homebrew Distribution

This project can be installed via Homebrew from your own tap repository.

Because this project uses a non-commercial custom license, it should be
distributed through a personal tap (not `homebrew/core`).

## 1. Build release artifact

From this repository:

```bash
./scripts/release-macos.sh v0.1.0
```

Or run full automated flow (build + GitHub release + tap update):

```bash
make release VERSION=v0.1.0
```

This creates:

- `dist/notes-matrix-v0.1.0-macos-<arch>.tar.gz`
- `dist/notes-matrix-v0.1.0-macos-<arch>.sha256`
- `dist/homebrew_formula_notes_matrix.rb`

## 2. Create tap repository

Create a new GitHub repo named:

- `homebrew-notes-matrix`

Then add formula file:

- path: `Formula/notes-matrix.rb`
- content: from `dist/homebrew_formula_notes_matrix.rb`

Commit and push.

## 3. Install command for users

```bash
brew tap <your-username>/notes-matrix
brew install notes-matrix
```

## 4. Upgrade flow

For each new release:

1. Run `./scripts/release-macos.sh vX.Y.Z`
2. Publish tarball to GitHub Release in main repo
3. Update formula in tap repo with new URL + SHA256
4. Push formula update

Users then run:

```bash
brew update
brew upgrade notes-matrix
```
