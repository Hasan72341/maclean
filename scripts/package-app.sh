#!/usr/bin/env bash
set -euo pipefail

# Packages MacLean.app: the SwiftUI app, the CLI it drives, the realtime agent,
# the YARA engine and the app icon.
#
#   scripts/package-app.sh              native arch, incremental (fast for development)
#   UNIVERSAL=1 scripts/package-app.sh  arm64 + x86_64 (what releases ship)

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
VERSION="$(cat "$ROOT/VERSION" 2>/dev/null || echo 0.0.0)"
start=$(date +%s)

# Keep the CLI's version in step with VERSION (only touch the file when it differs,
# so incremental builds stay incremental).
if ! grep -q "^let version = \"$VERSION\"" Sources/maclean/main.swift; then
  sed -i '' "s/^let version = \".*\"/let version = \"$VERSION\"/" Sources/maclean/main.swift
fi

# One build invocation for all three products (shares one module graph).
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  ARCH_FLAGS=(--arch arm64 --arch x86_64)
else
  ARCH_FLAGS=()
fi
swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} 2>&1 | grep -E "error|warning: |Compiling|Build complete" | grep -v "^\[" | tail -3 || true
BIN_DIR="$(swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"
for product in MacLeanApp maclean maclean-monitor; do
  [[ -x "$BIN_DIR/$product" ]] || { echo "missing build product: $product" >&2; exit 1; }
done

APP="$ROOT/dist/MacLean.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_DIR/MacLeanApp" "$BIN_DIR/maclean" "$BIN_DIR/maclean-monitor" "$APP/Contents/MacOS/"
# Debug symbols are not needed at runtime (keeps the download small).
strip -x "$APP/Contents/MacOS/"* 2>/dev/null || true

if [[ -d "$BIN_DIR/maclean_MacLeanCore.bundle" ]]; then
  cp -R "$BIN_DIR/maclean_MacLeanCore.bundle" "$APP/Contents/Resources/"
fi
# The YARA engine lives once, in Resources/bin (the engine looks there first).
# (SwiftPM bundles are flat for native builds and Contents/Resources for universal ones.)
BUNDLE_BIN="$(find "$APP/Contents/Resources/maclean_MacLeanCore.bundle" -maxdepth 5 -type d -name bin | head -1)"
if [[ -n "$BUNDLE_BIN" && -d "$BUNDLE_BIN" ]]; then
  mv "$BUNDLE_BIN" "$APP/Contents/Resources/bin"
elif [[ -d "$ROOT/Sources/MacLeanCore/Resources/bin" ]]; then
  cp -R "$ROOT/Sources/MacLeanCore/Resources/bin" "$APP/Contents/Resources/bin"
fi

[[ -f "$ROOT/packaging/AppIcon.icns" ]] && cp "$ROOT/packaging/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>xyz.nyora.maclean</string>
  <key>CFBundleName</key><string>MacLean</string>
  <key>CFBundleDisplayName</key><string>MacLean</string>
  <key>CFBundleExecutable</key><string>MacLeanApp</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc signature (no Apple Developer ID needed). Inner binaries first.
find "$APP/Contents/Resources/bin" "$APP/Contents/MacOS" -type f -perm +111 -exec codesign --force --sign - {} \; 2>/dev/null || true
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "Packaged $APP  (v$VERSION, $(du -sh "$APP" | cut -f1), $(lipo -archs "$APP/Contents/MacOS/MacLeanApp"), $(( $(date +%s) - start ))s)"
