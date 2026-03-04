#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <version-tag-like-v0.1.0>"
  exit 1
fi

VERSION="$1"
VERSION_NO_V="${VERSION#v}"
ARCH="$(uname -m)"
OUT_DIR="dist"
BIN_NAME="notes-matrix"
ASSET_NAME="${BIN_NAME}-${VERSION}-macos-${ARCH}.tar.gz"
ASSET_PATH="${OUT_DIR}/${ASSET_NAME}"
SHA_PATH="${OUT_DIR}/${ASSET_NAME}.sha256"

mkdir -p "${OUT_DIR}"

echo "==> Building release binary"
swift build -c release

echo "==> Packaging ${ASSET_NAME}"
tar -C ".build/release" -czf "${ASSET_PATH}" "${BIN_NAME}"

echo "==> Calculating SHA256"
shasum -a 256 "${ASSET_PATH}" | awk '{print $1}' > "${SHA_PATH}"
SHA256="$(cat "${SHA_PATH}")"

FORMULA_PATH="${OUT_DIR}/homebrew_formula_notes_matrix.rb"

cat > "${FORMULA_PATH}" <<EOF
class NotesMatrix < Formula
  desc "Apple Notes to Markdown exporter (TUI/CLI)"
  homepage "https://github.com/<your-username>/notes-matrix"
  url "https://github.com/<your-username>/notes-matrix/releases/download/${VERSION}/${ASSET_NAME}"
  sha256 "${SHA256}"
  license :cannot_represent

  def install
    bin.install "notes-matrix"
  end

  test do
    assert_match "notes-matrix - Apple Notes exporter", shell_output("#{bin}/notes-matrix help")
  end
end
EOF

echo
echo "Release artifact: ${ASSET_PATH}"
echo "SHA256 file:      ${SHA_PATH}"
echo "Formula template: ${FORMULA_PATH}"
echo
echo "Next steps:"
echo "1) Upload ${ASSET_PATH} to GitHub release ${VERSION}"
echo "2) Put ${FORMULA_PATH} into your tap repo Formula/notes-matrix.rb"
echo "3) Replace <your-username> in formula before commit"
echo
echo "Version (no v): ${VERSION_NO_V}"
echo "SHA256: ${SHA256}"

