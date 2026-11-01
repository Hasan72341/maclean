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
  retry() { for i in 1 2 3 4 5; do "$@" && return 0; echo "  retry $i" >&2; sleep 8; done; return 1; }
  # Draft first, upload each file with retries, manifest last, then publish:
  # installers never see a release with missing files.
  if ! gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    retry gh release create "$TAG" --repo "$REPO" --draft --target "$(git rev-parse HEAD)" --title "MacLean $VERSION" --notes "$notes" >/dev/null
  fi
  for file in "$APP_PKG" "$SRC_TAR" latest.txt; do
    retry gh release upload "$TAG" "$OUT/$file" --clobber --repo "$REPO"
  done
  retry gh release edit "$TAG" --repo "$REPO" --draft=false --latest >/dev/null
  echo "Published $TAG. Install with:"
  echo "  curl -fsSL https://raw.githubusercontent.com/$REPO/main/scripts/install.sh | bash"
fi
