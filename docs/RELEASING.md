# Releasing

## 1. Prepare release

1. Update `CHANGELOG.md` (`[Unreleased]` -> version section).
2. Verify build:

```bash
swift build -c release
```

3. Smoke test:

```bash
swift run notes-matrix help
swift run notes-matrix scan
swift run notes-matrix export --output /tmp/notes-export-smoke --on-existing overwrite --filename-mode unicode
```

4. Verify metadata consistency:

- `README.md` usage/options match current CLI flags
- `LICENSE` matches intended distribution policy
- commercial contact in `README.md` is valid

## 2. Tag

```bash
git tag v0.1.0
git push origin v0.1.0
```

## 3. GitHub release

Create a GitHub release from the tag and use:

- `CHANGELOG.md`
- `docs/RELEASE_NOTES_TEMPLATE_v0.1.0.md` (as starting point)

## 4. Homebrew (if enabled)

1. Generate/update release artifacts:

```bash
./scripts/release-macos.sh v0.1.0
```

2. Upload generated tarball to GitHub release.
3. Update tap formula (`Formula/notes-matrix.rb`) with new URL + SHA256.
4. Push tap update.
