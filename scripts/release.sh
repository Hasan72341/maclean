#!/usr/bin/env bash
set -euo pipefail

# Builds a universal release and the files the one-line installer reads:
#   dist/release/MacLean-<version>.tar.xz      the app (arm64 + x86_64)
#   dist/release/maclean-src-<version>.tar.gz  source, for --from-source
#   dist/release/latest.txt                    version, download location, checksums
#
#   scripts/release.sh             build only
#   scripts/release.sh --publish   tag v<version> and publish a GitHub release (gh CLI)

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
VERSION="$(cat VERSION)"
TAG="v$VERSION"
OUT="$ROOT/dist/release"
REPO="${MACLEAN_REPO:-hasan72341/maclean}"

UNIVERSAL=1 scripts/package-app.sh
rm -rf "$OUT" && mkdir -p "$OUT"

APP_PKG="MacLean-$VERSION.tar.xz"
SRC_TAR="maclean-src-$VERSION.tar.gz"
# xz: about a third of the size of a zip, and it unpacks in under a second.
COPYFILE_DISABLE=1 tar -C dist -cf - MacLean.app | xz -9e -T0 > "$OUT/$APP_PKG"
if git rev-parse --git-dir >/dev/null 2>&1; then
  git archive --format=tar.gz --prefix= -o "$OUT/$SRC_TAR" HEAD
else
  COPYFILE_DISABLE=1 tar --exclude ./.build --exclude ./dist --exclude ./.swiftpm --exclude ./.git \
    -czf "$OUT/$SRC_TAR" -C "$ROOT" .
fi

sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
cat > "$OUT/latest.txt" <<MANIFEST
version=$VERSION
download_base=https://github.com/$REPO/releases/download/$TAG
app=$APP_PKG
app_sha256=$(sha "$OUT/$APP_PKG")
source=$SRC_TAR
source_sha256=$(sha "$OUT/$SRC_TAR")
date=$(date -u +%Y-%m-%dT%H:%M:%SZ)
MANIFEST

echo "Release $VERSION:"
ls -lh "$OUT" | awk 'NR > 1 { print "  " $5 "\t" $9 }'

if [[ "${1:-}" == "--publish" ]]; then
  [[ -z "$(git status --porcelain)" ]] || { echo "Commit your changes before publishing." >&2; exit 1; }
  git push origin HEAD
  notes="Install or update:

\`\`\`sh
curl -fsSL https://raw.githubusercontent.com/$REPO/main/scripts/install.sh | bash
\`\`\`

Universal build (Apple silicon + Intel), macOS 13 or newer. The installer verifies the SHA-256 in \`latest.txt\` and signs the app locally (ad-hoc), so no Developer ID or Gatekeeper prompt is involved."
  if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    gh release upload "$TAG" "$OUT"/* --clobber --repo "$REPO"
  else
    gh release create "$TAG" "$OUT"/* --repo "$REPO" --target "$(git rev-parse HEAD)" --title "MacLean $VERSION" --notes "$notes"
  fi
  echo "Published $TAG. Install with:"
  echo "  curl -fsSL https://raw.githubusercontent.com/$REPO/main/scripts/install.sh | bash"
fi
