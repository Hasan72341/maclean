#!/usr/bin/env bash
# MacLean installer.
#
#   curl -fsSL https://raw.githubusercontent.com/hasan72341/maclean/main/scripts/install.sh | bash
#
# Options (after `bash -s --`):
#   --from-source   build on this Mac instead of downloading the app (needs Xcode
#                   or the Command Line Tools; takes a couple of minutes)
#   --uninstall     remove MacLean and everything it left on this Mac: the app,
#                   menu bar item, background agent, caches, saved maps,
#                   settings, alerts, logs and window state
#   --keep-data     with --uninstall, keep settings, alerts and history
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
KEEP_DATA=0
for arg in "$@"; do
  case "$arg" in
    --from-source) MODE="source" ;;
    --uninstall) MODE="uninstall" ;;
    --keep-data) KEEP_DATA=1 ;;
    --purge) ;; # older flag; removing everything is now the default
    -h|--help) sed -n '2,14p' "$0" 2>/dev/null || true; exit 0 ;;
  esac
done

bold=$'\033[1m'; dim=$'\033[2m'; accent=$'\033[38;5;173m'; red=$'\033[31m'; reset=$'\033[0m'
[[ -t 1 ]] || { bold=""; dim=""; accent=""; red=""; reset=""; }
step() { printf "%s›%s %s\n" "$accent" "$reset" "$*"; }
fail() { printf "%s✗ %s%s\n" "$red" "$*" "$reset" >&2; exit 1; }
started=$(date +%s)

human() { awk -v b="$1" 'BEGIN { if (b >= 1048576) printf "%.1f MB", b/1048576; else printf "%d KB", b/1024 }'; }

# download URL FILE [EXPECTED_BYTES]
# Shows a live bar: percent, bytes done of total, speed and time left.
download() {
  local url="$1" out="$2" total="${3:-}"
  if [[ -z "$total" || "$total" == 0 ]]; then
    total="$(curl -fsIL --retry 2 --connect-timeout 10 "$url" | awk 'tolower($1) == "content-length:" { n = $2 } END { gsub(/\r/, "", n); print n + 0 }')"
  fi
  rm -f "$out"
  # Up to 5 attempts; each one resumes where the last stopped (-C -), so a
  # dropped connection costs seconds, not the whole download.
  (
    for attempt in 1 2 3 4 5; do
      curl -fsSL --retry 3 --retry-delay 1 --connect-timeout 15 --speed-limit 1024 --speed-time 20 -C - "$url" -o "$out" && exit 0
      sleep $(( attempt * 2 ))
    done
    exit 1
  ) &
  local pid=$! have=0 pct rate left width=28 filled bar line last_pct=-1
  local tick=0 first=-1 hist=() rate_from secs
  while kill -0 "$pid" 2>/dev/null; do
    have=$(stat -f%z "$out" 2>/dev/null || echo 0)
    tick=$(( tick + 1 ))
    # Speed over the last ~3 s (12 samples of 0.25 s), counted from the first byte.
    (( have > 0 && first < 0 )) && first=$tick
    hist+=("$have")
    rate=0
    if (( first >= 0 )); then
      rate_from=$(( ${#hist[@]} > 12 ? ${#hist[@]} - 13 : first - 1 ))
      (( rate_from < 0 )) && rate_from=0
      secs=$(( ${#hist[@]} - 1 - rate_from ))
      (( secs > 0 )) && rate=$(( (have - ${hist[$rate_from]}) * 4 / secs ))
    fi
    if (( total > 0 )); then
      pct=$(( have * 100 / total )); (( pct > 100 )) && pct=100
      filled=$(( pct * width / 100 ))
      bar="$(printf '%*s' "$filled" '' | tr ' ' '#')$(printf '%*s' $(( width - filled )) '' | tr ' ' '-')"
      if (( have == 0 )); then left="connecting…"
      elif (( rate > 0 )); then left="$(( (total - have + rate - 1) / rate ))s left"
      else left="…"; fi
      line="$(printf "  [%s] %3d%%  %s / %s  %s/s  %s" "$bar" "$pct" "$(human "$have")" "$(human "$total")" "$(human "$rate")" "$left")"
    else
      pct=0; line="$(printf "  %s downloaded  %s/s" "$(human "$have")" "$(human "$rate")")"
    fi
    if [[ -t 1 ]]; then
      printf "\r\033[K%s" "$line"
    elif (( pct / 25 != last_pct / 25 )); then
      echo "$line"; last_pct=$pct
    fi
    sleep 0.25
  done
  if ! wait "$pid"; then [[ -t 1 ]] && printf "\r\033[K"; return 1; fi
  have=$(stat -f%z "$out" 2>/dev/null || echo 0)
  line="$(printf "  [%s] 100%%  %s in %ss" "$(printf '%*s' $width '' | tr ' ' '#')" "$(human "$have")" "$(( (tick + 3) / 4 ))")"
  if [[ -t 1 ]]; then printf "\r\033[K%s\n" "$line"; else echo "$line"; fi
}

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
  # The CLI link, only if it points at MacLean.
  if [[ -L /usr/local/bin/maclean && "$(readlink /usr/local/bin/maclean)" == *MacLean.app* ]]; then
    rm -f /usr/local/bin/maclean 2>/dev/null || step "Remove /usr/local/bin/maclean with sudo to finish"
  fi
  L="$HOME/Library"
  rm -rf "$L/Caches/MacLean" "$L/Caches/maclean" "$L/Caches/xyz.nyora.maclean" \
         "$L/HTTPStorages/xyz.nyora.maclean" "$L/HTTPStorages/xyz.nyora.maclean.binarycookies" \
         "$L/WebKit/xyz.nyora.maclean" "$L/Saved Application State/xyz.nyora.maclean.savedState" \
         "$L/Logs/MacLeanMonitor.out" "$L/Logs/MacLeanMonitor.err"
  step "Removed caches, saved maps, logs and window state"
  if (( KEEP_DATA )); then
    step "Kept settings and history in $L/Application Support/MacLean"
  else
    defaults delete xyz.nyora.maclean >/dev/null 2>&1 || true
    rm -rf "$L/Application Support/MacLean" "$L/Preferences/xyz.nyora.maclean.plist" \
           "$L/Preferences/ByHost/xyz.nyora.maclean."*.plist
    step "Removed settings, alerts and history"
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
  download "$FILES/$(field source)" "$WORK/src.tar.gz" || fail "Download failed; check your connection and try again."
  [[ "$(shasum -a 256 "$WORK/src.tar.gz" | cut -d' ' -f1)" == "$(field source_sha256)" ]] || fail "Source checksum mismatch."
  mkdir -p "$WORK/src" && tar -xzf "$WORK/src.tar.gz" -C "$WORK/src"
  step "Building (this takes a minute or two the first time)…"
  ( cd "$WORK/src" && scripts/package-app.sh ) | tail -1
  NEW_APP="$WORK/src/dist/MacLean.app"
else
  current="$(defaults read "$(existing_app 2>/dev/null || echo /nonexistent)/Contents/Info" CFBundleShortVersionString 2>/dev/null || true)"
  if [[ -n "$current" && "$current" != "$version" ]]; then step "Updating MacLean $current → $version"
  elif [[ -n "$current" ]]; then step "Reinstalling MacLean $version"; else step "Downloading MacLean $version"; fi
  download "$FILES/$(field app)" "$WORK/MacLean.tar.xz" "$(field app_size)" || fail "Download failed; check your connection and try again."
  step "Verifying checksum and unpacking"
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
