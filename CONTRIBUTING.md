# Contributing

Thanks for considering a contribution.

## Development setup

1. Install Xcode Command Line Tools.
2. Clone the repository.
3. Build:

```bash
swift build
```

4. Run:

```bash
swift run notes-matrix
```

## Before opening a PR

1. Ensure the project builds:

```bash
swift build
```

2. Keep changes focused and small.
3. Update docs if behavior changed.
4. Add or update tests when test targets are introduced.

## Commit style

Use clear commit messages, for example:

- `feat: add export mode selector`
- `fix: handle notes with missing folder metadata`
- `docs: update troubleshooting`

## Pull request checklist

- [ ] Build passes locally
- [ ] Documentation updated
- [ ] No unrelated file changes

