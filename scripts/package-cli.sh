#!/usr/bin/env bash
set -euo pipefail

# Packages the CLI plus its bundled YARA engine as an ad-hoc signed .app.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

swift build -c release --product maclean
BIN_DIR="$(swift build -c release --show-bin-path)"

APP="$ROOT/dist/MacLeanCLI.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_DIR/maclean" "$APP/Contents/MacOS/maclean"
if [[ -d "$BIN_DIR/maclean_MacLeanCore.bundle" ]]; then
  cp -R "$BIN_DIR/maclean_MacLeanCore.bundle" "$APP/Contents/Resources/"
fi
if [[ -d "$ROOT/Sources/MacLeanCore/Resources/bin" ]]; then
  cp -R "$ROOT/Sources/MacLeanCore/Resources/bin" "$APP/Contents/Resources/bin"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>xyz.nyora.maclean.cli</string>
  <key>CFBundleName</key><string>MacLean CLI</string>
  <key>CFBundleDisplayName</key><string>MacLean CLI</string>
  <key>CFBundleExecutable</key><string>maclean</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.2.0</string>
  <key>CFBundleVersion</key><string>0.2.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo "Packaged $APP"
echo "CLI:  $APP/Contents/MacOS/maclean"
echo "YARA: $APP/Contents/Resources/bin/maclean-yara"
