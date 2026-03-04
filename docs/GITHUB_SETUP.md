# GitHub Setup

## 0. Confirm current folder is a git repository

```bash
git rev-parse --is-inside-work-tree
```

If command fails with `not a git repository`, run section `1`.

## 1. Initialize git (if needed)

```bash
git init
git add .
git commit -m "chore: prepare project for public release"
```

## 1.1 Standard commit workflow (after you make changes)

```bash
git status -sb
git add -A
git commit -m "chore: <short summary>"
git push
```

Notes:

1. Use concise, meaningful messages (`docs:`, `feat:`, `fix:`, `chore:` are fine).
2. If you touched only docs, prefer `docs: ...`.
3. Before pushing, run quick checks (see section 7).

## 2. Create repository on GitHub

Create an empty repository, for example `notes-matrix`.

- Visibility: `Public`
- Do not auto-add README/.gitignore/license (already present locally)

## 3. Connect remote and push

```bash
git branch -M main
git remote add origin git@github.com:<your-username>/notes-matrix.git
git push -u origin main
```

If `origin` already exists, update it:

```bash
git remote set-url origin git@github.com:<your-username>/notes-matrix.git
git push -u origin main
```

## 4. Update README badges

Replace placeholders in README:

```bash
GITHUB_USER="<your-username>"
REPO_NAME="notes-matrix"
sed -i '' "s|<your-username>|${GITHUB_USER}|g; s|<repo>|${REPO_NAME}|g" README.md
git add README.md
git commit -m "docs: set README badges to actual repository"
git push
```

## 5. Restrict pushes (only you can commit to main)

GitHub -> `Settings` -> `Branches` -> `Add branch protection rule`

Rule for `main`:

1. Enable `Restrict who can push to matching branches`
2. Add only your GitHub user
3. Enable `Require status checks to pass before merging` and select `CI` (recommended)
4. (Optional) Enable `Require a pull request before merging`

Also check:

- `Settings` -> `Collaborators and teams`: only you should have write/admin access.

## 6. Verify publication metadata

1. Confirm `LICENSE` and `README.md` render correctly.
2. Confirm CI workflow passes.
3. Confirm commercial contact link in README works.

## 7. Pre-push sanity checks (recommended)

```bash
git status
git remote -v
git branch --show-current
git ls-files | rg -n "\\.DS_Store|\\.build/" || true
rg -n "(api[_-]?key|token|secret|password|BEGIN (RSA|OPENSSH|EC|PGP) PRIVATE KEY|sk-|ctx7sk-)" -S . || true
```

Expected:

- branch is `main`
- no secrets in output
- `.build/` and `.DS_Store` are not tracked

Also verify local/private artifacts are not tracked (for this workspace, especially `chrome-tabs.md`).

## 7.1 Practical publish checklist

1. `README.md` has real repo badges (no placeholders).
2. `LICENSE` is present and renders on GitHub.
3. Export artifacts (`notes-export`, zip files) are not tracked.
4. Local/private artifacts (for example `chrome-tabs.md`) are not tracked.
5. CI workflow is green on `main`.

## 8. Optional: first release

```bash
git tag v0.1.0
git push origin v0.1.0
```

Create GitHub release from tag and use:

- `CHANGELOG.md`
- `docs/RELEASE_NOTES_TEMPLATE_v0.1.0.md`

## 9. Optional: Homebrew distribution (recommended for macOS CLI)

See full guide: `docs/HOMEBREW.md`

Quick flow:

1. Generate release asset + SHA + formula template:

```bash
./scripts/release-macos.sh v0.1.0
```

2. Upload generated tar.gz to GitHub Release.
3. Create/update your tap repo (`homebrew-notes-matrix`) with:
   - `Formula/notes-matrix.rb` (from generated template)
4. Users install via:

```bash
brew tap <your-username>/notes-matrix
brew install notes-matrix
```
