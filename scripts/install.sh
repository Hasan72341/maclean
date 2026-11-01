#!/usr/bin/env bash
# MacLean installer.
#
#   curl -fsSL https://raw.githubusercontent.com/hasan72341/maclean/main/scripts/install.sh | bash
#
# Options (after `bash -s --`):
#   --from-source   build on this Mac instead of downloading the app (needs Xcode
#                   or the Command Line Tools; takes a couple of minutes)
#   --uninstall     remove MacLean, its menu bar item and its background agent
#   --purge         with --uninstall, also delete settings, saved maps and logs
#
# No Apple Developer ID is involved: the app is signed on this Mac with a local
# (ad-hoc) signature, so macOS runs it without a Gatekeeper prompt.
set -euo pipefail

REPO="${MACLEAN_REPO:-hasan72341/maclean}"
# latest.txt of the newest GitHub release; it names the files and their checksums.
BASE="${MACLEAN_BASE_URL:-https://github.com/$REPO/releases/latest/download}"
INSTALLER_URL="https://raw.githubusercontent.com/$REPO/main/scripts/install.sh"
AGENT_LABEL="xyz.nyora.maclean.monitor"
AGENT_PLIST="$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"
MODE="binary"
PURGE=0
for arg in "$@"; do
  case "$arg" in
    --from-source) MODE="source" ;;
    --uninstall) MODE="uninstall" ;;
    --purge) PURGE=1 ;;
    -h|--help) sed -n '2,14p' "$0" 2>/dev/null || true; exit 0 ;;
  esac
done

bold=$'\033[1m'; dim=$'\033[2m'; accent=$'\033[38;5;173m'; red=$'\033[31m'; reset=$'\033[0m'
[[ -t 1 ]] || { bold=""; dim=""; accent=""; red=""; reset=""; }
step() { printf "%s›%s %s\n" "$accent" "$reset" "$*"; }
fail() { printf "%s✗ %s%s\n" "$red" "$*" "$reset" >&2; exit 1; }
started=$(date +%s)

[[ "$(uname -s)" == "Darwin" ]] || fail "MacLean runs on macOS only."
major="$(sw_vers -productVersion | cut -d. -f1)"
(( major >= 13 )) || fail "MacLean needs macOS 13 Ventura or newer (this Mac has $(sw_vers -productVersion))."

quit_running() {
  # A signal, not an Apple Event: Apple Events would trigger an Automation
  # permission prompt and block the install until it times out.
  pgrep -x MacLeanApp >/dev/null || return 0
  pkill -TERM -x MacLeanApp >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x MacLeanApp >/dev/null || return 0; sleep 0.1; done
  pkill -KILL -x MacLeanApp >/dev/null 2>&1 || true
}

existing_app() {
  for candidate in "/Applications/MacLean.app" "$HOME/Applications/MacLean.app"; do
    [[ -d "$candidate" ]] && { echo "$candidate"; return; }
  done
}

if [[ "$MODE" == "uninstall" ]]; then
  printf "%sUninstalling MacLean%s\n" "$bold" "$reset"
  quit_running
  launchctl bootout "gui/$(id -u)/$AGENT_LABEL" >/dev/null 2>&1 || true
  rm -f "$AGENT_PLIST"
  app="$(existing_app || true)"
  [[ -n "$app" ]] && rm -rf "$app" && step "Removed $app"
  rm -f /usr/local/bin/maclean 2>/dev/null || true
  rm -rf "$HOME/Library/Caches/MacLean" "$HOME/Library/Caches/maclean"
  if (( PURGE )); then
    rm -rf "$HOME/Library/Application Support/MacLean" "$HOME/Library/Logs/MacLeanMonitor."*
    defaults delete xyz.nyora.maclean >/dev/null 2>&1 || true
    step "Removed settings, alerts and logs"
  fi
  printf "%sDone.%s\n" "$bold" "$reset"
  exit 0
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/maclean-install.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

printf "%sInstalling MacLean%s %s(%s)%s\n" "$bold" "$reset" "$dim" "$( [[ $MODE == source ]] && echo "build from source" || echo "prebuilt, $(uname -m)")" "$reset"

# Release manifest: version, sha256 and file names (cache-busted).
manifest="$(curl -fsSL --retry 3 "$BASE/latest.txt")" || fail "Could not reach $BASE"
field() { printf "%s\n" "$manifest" | awk -F= -v k="$1" '$1 == k { print $2 }'; }
version="$(field version)"
[[ -n "$version" ]] || fail "The release manifest is malformed."
# Files come from that exact release (not "latest"), so they always match the manifest.
FILES="$(field download_base)"; FILES="${FILES:-$BASE}"

if [[ "$MODE" == "source" ]]; then
  xcrun --find swift >/dev/null 2>&1 || fail "Building from source needs Xcode or the Command Line Tools (xcode-select --install)."
  step "Downloading source $version"
  curl -fsSL --retry 3 "$FILES/$(field source)" -o "$WORK/src.tar.gz"
  [[ "$(shasum -a 256 "$WORK/src.tar.gz" | cut -d' ' -f1)" == "$(field source_sha256)" ]] || fail "Source checksum mismatch."
  mkdir -p "$WORK/src" && tar -xzf "$WORK/src.tar.gz" -C "$WORK/src"
  step "Building (this takes a minute or two the first time)…"
  ( cd "$WORK/src" && scripts/package-app.sh ) | tail -1
  NEW_APP="$WORK/src/dist/MacLean.app"
else
  step "Downloading MacLean $version"
  curl -fL --progress-bar --retry 3 --retry-delay 1 --connect-timeout 15 "$FILES/$(field app)" -o "$WORK/MacLean.tar.xz"
  [[ "$(shasum -a 256 "$WORK/MacLean.tar.xz" | cut -d' ' -f1)" == "$(field app_sha256)" ]] || fail "Download checksum mismatch; try again."
  tar -xJf "$WORK/MacLean.tar.xz" -C "$WORK"
  NEW_APP="$WORK/MacLean.app"
fi
[[ -x "$NEW_APP/Contents/MacOS/MacLeanApp" ]] || fail "The package is incomplete."

# /Applications when this user may write there (admins can), otherwise ~/Applications.
if [[ -w /Applications ]]; then DEST_DIR="/Applications"; else DEST_DIR="$HOME/Applications"; mkdir -p "$DEST_DIR"; fi
DEST="$DEST_DIR/MacLean.app"

step "Installing to $DEST"
quit_running
old="$(existing_app || true)"
[[ -n "$old" && "$old" != "$DEST" ]] && rm -rf "$old"
rm -rf "$DEST"
ditto "$NEW_APP" "$DEST"

# Local signature: valid on this Mac, no Developer ID or notarization needed.
xattr -cr "$DEST" 2>/dev/null || true
find "$DEST/Contents/Resources/bin" "$DEST/Contents/MacOS" -type f -perm +111 -exec codesign --force --sign - {} \; 2>/dev/null || true
codesign --force --sign - "$DEST" >/dev/null 2>&1 || fail "Could not sign the app on this Mac."
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST" >/dev/null 2>&1 || true

# Point an existing realtime agent at the new copy and restart it.
if [[ -f "$AGENT_PLIST" ]]; then
  /usr/libexec/PlistBuddy -c "Set :ProgramArguments:0 $DEST/Contents/MacOS/maclean-monitor" "$AGENT_PLIST" >/dev/null 2>&1 || true
  launchctl bootout "gui/$(id -u)/$AGENT_LABEL" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$(id -u)" "$AGENT_PLIST" >/dev/null 2>&1 || true
  step "Restarted the realtime protection agent"
fi

open "$DEST"
printf "%s✓ MacLean %s is installed%s %s(%ss)%s\n" "$bold" "$version" "$reset" "$dim" "$(( $(date +%s) - started ))" "$reset"
printf "  %sLook for the m. icon in the menu bar. For full scans, allow Full Disk Access in\n  System Settings › Privacy & Security. Uninstall: curl -fsSL %s | bash -s -- --uninstall%s\n" "$dim" "$INSTALLER_URL" "$reset"
