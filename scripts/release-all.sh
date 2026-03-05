#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./scripts/release-all.sh <version-tag-like-v0.1.7> [release-notes]

What it does:
  1) Builds release artifact via ./scripts/release-macos.sh
  2) Creates or updates GitHub release with tarball
  3) Updates Homebrew tap formula and pushes it

Environment overrides:
  MAIN_REPO   default: inferred from git remote origin (e.g. PaladinXL/notes-matrix)
  TAP_REPO    default: <owner>/homebrew-notes-matrix
  TAP_DIR     default: /tmp/homebrew-notes-matrix
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ $# -lt 1 || $# -gt 2 ]]; then
  usage
  exit 1
fi

VERSION="$1"
NOTES="${2:-Automated release ${VERSION}}"

if [[ ! "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "error: version must look like v0.1.7"
  exit 1
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "error: GitHub CLI (gh) is required"
  exit 1
fi

if ! command -v git >/dev/null 2>&1; then
  echo "error: git is required"
  exit 1
fi

if ! command -v swift >/dev/null 2>&1; then
  echo "error: swift is required"
  exit 1
fi

if [[ -n "$(git status --porcelain)" ]]; then
  echo "error: working tree is not clean. Commit or stash changes first."
  exit 1
fi

origin_url="$(git remote get-url origin)"
if [[ "$origin_url" =~ github\.com[:/]([^/]+)/([^/.]+)(\.git)?$ ]]; then
  origin_owner="${BASH_REMATCH[1]}"
  origin_repo="${BASH_REMATCH[2]}"
else
  echo "error: unable to parse GitHub owner/repo from origin: $origin_url"
  exit 1
fi

MAIN_REPO="${MAIN_REPO:-${origin_owner}/${origin_repo}}"
owner="${MAIN_REPO%%/*}"
repo="${MAIN_REPO##*/}"
TAP_REPO="${TAP_REPO:-${owner}/homebrew-notes-matrix}"
TAP_DIR="${TAP_DIR:-/tmp/homebrew-notes-matrix}"

echo "==> Main repo: ${MAIN_REPO}"
echo "==> Tap repo:  ${TAP_REPO}"
echo "==> Version:   ${VERSION}"

./scripts/release-macos.sh "${VERSION}"

ARCH="$(uname -m)"
ASSET_NAME="notes-matrix-${VERSION}-macos-${ARCH}.tar.gz"
ASSET_PATH="dist/${ASSET_NAME}"
FORMULA_SRC="dist/homebrew_formula_notes_matrix.rb"

if [[ ! -f "${ASSET_PATH}" ]]; then
  echo "error: missing asset ${ASSET_PATH}"
  exit 1
fi

if [[ ! -f "${FORMULA_SRC}" ]]; then
  echo "error: missing formula template ${FORMULA_SRC}"
  exit 1
fi

echo "==> Publishing GitHub release ${VERSION}"
if gh release view "${VERSION}" --repo "${MAIN_REPO}" >/dev/null 2>&1; then
  gh release upload "${VERSION}" "${ASSET_PATH}" --repo "${MAIN_REPO}" --clobber
  gh release edit "${VERSION}" --repo "${MAIN_REPO}" --title "${VERSION}" --notes "${NOTES}"
else
  gh release create "${VERSION}" "${ASSET_PATH}" --repo "${MAIN_REPO}" --title "${VERSION}" --notes "${NOTES}"
fi

echo "==> Syncing tap repo ${TAP_REPO}"
if [[ -d "${TAP_DIR}/.git" ]]; then
  git -C "${TAP_DIR}" fetch --all --prune
  git -C "${TAP_DIR}" checkout main
  git -C "${TAP_DIR}" pull --ff-only
else
  rm -rf "${TAP_DIR}"
  git clone "git@github.com:${TAP_REPO}.git" "${TAP_DIR}"
fi

mkdir -p "${TAP_DIR}/Formula"
FORMULA_DST="${TAP_DIR}/Formula/notes-matrix.rb"
cp "${FORMULA_SRC}" "${FORMULA_DST}"
sed -i '' "s|<your-username>|${owner}|g" "${FORMULA_DST}"

git -C "${TAP_DIR}" add Formula/notes-matrix.rb
if git -C "${TAP_DIR}" diff --cached --quiet; then
  echo "==> Tap formula unchanged; nothing to commit"
else
  git -C "${TAP_DIR}" commit -m "notes-matrix ${VERSION}"
  git -C "${TAP_DIR}" push
fi

echo
echo "Done."
echo "Release: https://github.com/${MAIN_REPO}/releases/tag/${VERSION}"
echo "Tap:     https://github.com/${TAP_REPO}"
