# maclean

A safe, open-source macOS cleaner written in Swift. It scans local junk, privacy
artifacts, startup items, duplicates, disk images, mail attachments, cloud-folder
usage and AI-model caches, shows what it found, and only removes things when you
explicitly ask.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/hasan72341/maclean/main/scripts/install.sh | bash
```

This needs macOS 13 or newer, on Apple silicon or Intel. The installer:

1. downloads a 10 MB universal build from the latest
   [GitHub release](https://github.com/hasan72341/maclean/releases);
2. verifies its SHA-256;
3. signs it locally with an ad-hoc signature, so no Apple Developer ID or notarization
   is needed and no Gatekeeper prompt appears;
4. installs it to `/Applications` (or `~/Applications`);
5. repoints the realtime agent at the new copy;
6. opens the app.

Everything except the download takes under 2 seconds. Running the same command again
updates MacLean.

- Build on your own Mac instead: `curl -fsSL https://raw.githubusercontent.com/hasan72341/maclean/main/scripts/install.sh | bash -s -- --from-source`, or
  `git clone https://github.com/hasan72341/maclean && cd maclean && scripts/package-app.sh`
  (needs Xcode or the Command Line Tools; takes about 2 minutes).
- Uninstall: `curl -fsSL https://raw.githubusercontent.com/hasan72341/maclean/main/scripts/install.sh | bash -s -- --uninstall` removes MacLean and all its files (add `--keep-data` to keep settings and history).

Because the signature is made locally, macOS treats each install as a new app, so
Full Disk Access has to be granted again after an update.

### When something can't be deleted

If a removal leaves items behind (root-owned leftovers, locked files), MacLean lists
them with the exact path and the reason. For each one you can:

1. **Try as Administrator.** macOS asks for your password. The items move to your
   Trash and are owned by you again, so the Trash can be emptied. Launch items are
   unloaded first.
2. **Remove it yourself.** If something still remains, use **Copy path**,
   **Show in Finder**, or the ready-made `sudo rm` commands.

MacLean never offers the administrator retry or the commands for paths it refuses
on purpose: macOS system files, protected folders such as `~/Documents`,
keychains, and symbolic links.

## Screen sizes and interface size

The window fits any screen, down to 760×520. The sidebar collapses to icons when
the window is narrow (⌃⌘S toggles it). To make everything larger or smaller, use
Settings › General › Interface size (85–130%) or ⌘+ / ⌘− / ⌘0.

## Full Disk Access

MacLean isn't in the Full Disk Access list until you add it, because macOS doesn't
let apps add themselves. Settings › Full Disk Access has a MacLean tile you can drag
into the list. It then re-checks by itself until access works.

## Updates

MacLean checks GitHub releases at launch and every 6 hours. You can turn this off
in Settings › About & Updates.

When a newer release is out, every running copy shows:

- an update popup in the window;
- a macOS notification with an **Update** button;
- an update row in the menu bar panel.

**Update** downloads the release with a progress bar and checks its SHA-256. It then
replaces the app, signs it locally and reopens it. Settings and history are kept.

To ship an update, bump `VERSION`, commit, and run `scripts/release.sh --publish`.
The text in `RELEASE_NOTES` (or `dist/NOTES.md`) shows in the popup.

## Building and releasing

| Command | What it does |
|---|---|
| `scripts/package-app.sh` | `dist/MacLean.app` for this Mac's architecture: ~1 s with no changes, ~6 s after an edit |
| `UNIVERSAL=1 scripts/package-app.sh` | arm64 + x86_64 build |
| `scripts/release.sh [--publish]` | universal build, `.tar.xz` package, source tarball, `latest.txt` with checksums; `--publish` pushes and creates the GitHub release `v<VERSION>` (needs `gh`) |
| `swift scripts/make-icon.swift <dir>.iconset` | redraws the app icon (`packaging/AppIcon.icns`) |

The version comes from `VERSION`.

## Build

Requires macOS 13+ and Swift 6.

```sh
cd maclean
swift build -c release
.build/release/maclean help
```

Or run from source with `swift run maclean scan`.

## SwiftUI app

A native frontend lives in `Sources/MacLeanApp` with ~200 screens across eight
sections. Every section keeps its own back stack (Back button, breadcrumbs,
⌘[ / Esc), and every screen calls MacLeanCore directly:

- **Dashboard** — live CPU/per-core/memory/swap/disk I/O/network/battery graphs
  (1 s sampling), health score, processes with quit/force quit, volumes, system info
- **Cleanup** — Smart Scan with per-category progress and a live verbose scan
  console (every rule, folder, skipped entry and finding, with per-rule timings),
  category → rule → item drill-down, selective cleaning, Trash bins, editable rules,
  custom rules, scan options, history
- **Applications** — app detail, uninstall plans with leftovers, reset, unused/large/
  recent apps, vendors, orphaned leftovers, extensions, running apps, updates
- **Privacy** — browser data per browser, recent items, TCC permissions by service
  and app, saved state, quarantine events, shell history, clipboard, Wi-Fi networks
- **Performance** — startup items/agents/daemons/login items with disable/remove,
  snapshots, memory, heavy consumers, and maintenance tasks with live output
- **Space & Files** — Space Lens drill-down, large & old files, duplicates, similar
  images, disk images, downloads, file types, cloud, mail attachments, empty folders
- **Protection** — scan profiles, findings, quarantine vault, realtime monitor and
  alerts, YARA rules, corpus, and Deep Scan (Mail Trash, Photos duplicates, document
  versions, deleted users, system caches, universal binaries)
- **Settings** — appearance, monitoring, history, statistics, Full Disk Access,
  engine/CLI info, app data, diagnostics, licenses

Removals always ask for confirmation, go through the engine's validating cleaners
(Trash by default), and are recorded in `~/Library/Application Support/MacLean/activity.json`.

UI smoke test (renders every section and argument-free screen to PNGs, then quits;
add `--env MACLEAN_SMOKE_SCAN=1` to also capture a read-only Smart Scan in progress,
`--env MACLEAN_SMOKE_LEFTOVERS=1` to create files of a made-up removed app and remove
them end to end from the Leftovers screens):

```sh
open -n --env MACLEAN_SMOKE_DIR=/tmp/maclean-smoke dist/MacLean.app
```

### Menu bar

MacLean puts an "m." mark in the menu bar. It keeps running after the main window
closes; clicking the Dock icon brings the window back. The panel shows:

- the health score;
- real-time protection status, with Turn On or Review alerts;
- live CPU, memory, disk-free and network tiles with graphs (click a tile to open its screen);
- the battery;
- one-click **Scan → Clean** for safe junk, **Free** memory (asks for the administrator
  password) and **Empty Trash**;
- the three busiest apps.

**Settings › Menu Bar & Background** controls how MacLean runs:

- keep running when the window is closed (off: closing the window quits);
- show in the Dock (off: a menu-bar-only app);
- open the window at launch (off: start quietly in the menu bar);
- open at login;
- which panel sections appear;
- notifications for new threats from the realtime agent, which are posted even
  while the window is closed.

Hiding both the Dock icon and the menu bar item is not allowed, so the app always stays
reachable. The gear button sets what appears next to the icon (icon only, CPU %, memory % or free
space), Open at login, and whether the item is shown at all. The icon turns into a red
shield when there are threat alerts. Smoke: `--env MACLEAN_SMOKE_MENU=1` renders the
panel in light and dark mode.

### Space Lens

**Space & Files › Space Lens** maps a disk or folder by size.

- **Engine** (`LensTree.swift`): one parallel walk builds the whole tree. Drilling into
  any folder afterwards is instant, with no rescan. Sizes are allocated bytes and match `du`.
  - Hard links count once and symlinks are not followed.
  - A scan of `/` skips `/System/Volumes`, `/Volumes`, other mounts and the virtual
    `/.nofollow` and `/.resolve` trees, and enters each folder (by file ID) only once, so
    APFS firmlinks and path aliases are not double-counted.
  - Each folder keeps its large entries and folds the long tail of tiny ones into a
    "N smaller items" entry, so memory stays small on million-file trees.
  - Every folder carries per-type totals (apps, video, audio, images, documents,
    archives, developer, other). The scan records the largest files and lists
    unreadable folders.
  - Progress is live and the scan can be cancelled.
  - About 30 s for 1.68 M files / 349 GB on this Mac (`du -sk` takes 47 s for the total
    alone). A full `/` scan: 2.63 M files / 451 GB in about 95 s, peak memory ~0.5 GB
    for the home folder. Totals can exceed the disk's used space because APFS clones
    are counted per file, as `du` does.
- **Full-disk scans as administrator**: scanning `/` shows the macOS password prompt
  first, then the bundled CLI (`maclean lens / --archive F --progress-file P`) walks the
  disk as root and hands the map back. Live counters come from the progress file, and Cancel
  creates `P.cancel`, which stops the root scan. If the prompt is dismissed, the scan runs
  without elevation and says so. `MACLEAN_LENS_NO_ADMIN=1` disables this;
  `MACLEAN_LENS_ADMIN_DRYRUN=1` runs the same pipeline unelevated (tests).
- **Saved maps** (`LensArchive.swift`): every finished scan is saved to
  `~/Library/Caches/MacLean/Lens` (compact binary, ~55 MB for the home folder, newest 8
  kept) and saved again after removals. Opening a scanned place after relaunch loads the
  map in under half a second, with a "Saved map from … · Rescan now" banner; the start
  screen lists saved maps and shows their sizes on the place tiles.
- **UI**:
  - A start screen with disk usage and common places (plus external volumes and
    "Choose Folder…").
  - A live scan view showing files/s, size found, folders and the current path, with Cancel.
  - The explorer offers three interactive charts:
    - **Sunburst**: four rings deep; click the centre to go up.
    - **Bubbles**: packed circles with their children nested inside.
    - **Treemap**: squarified, two levels.
  - Hover shows details. The explorer also has a breadcrumb trail, a "what's inside"
    breakdown by type, and a selectable list with the selection dock.
  - Sub-screens: **Largest files here**, **File types here** and **Smaller Items**, which
    lists and measures every entry folded into "N smaller items" so they can be
    selected and moved to the Trash; the map's totals update in place.
  - Removals use the validating Trash path, and the open tree is updated in place.
- CLI: `maclean lens <path> [--depth N] [--top N] [--verbose]` uses the same engine.
- Smoke: `--env MACLEAN_SMOKE_LENS=1` builds a test folder, scans it and checks totals,
  aggregation, kinds and the largest-files list. It captures all three charts, drills
  in, removes a folder, removes five grouped small files, then reloads the map from disk.
  `--env MACLEAN_SMOKE_LENS_DISK=1` scans `/` in the app and compares the total with the
  disk's allocated space.

### App leftovers

Leftover detection lives in the engine (`Leftovers.swift`) and is shared by the
uninstaller, the app's **Applications › Leftovers** screens and `maclean leftovers`.

- **Identity**: an app is described by its main bundle ID, the IDs of embedded login
  items, XPC services, extensions and helpers, its names/executable and its signing team.
- **Locations**: 23 places in `~/Library`: Application Support, Caches, Preferences and
  ByHost preferences, saved state, sandbox and group containers, application scripts,
  HTTP storage, WebKit, cookies, logs, crash/hang reports, the recent-documents list,
  Internet plug-ins, preference panes, Quick Look, Spotlight, services, screen savers,
  autosave, Sparkle update caches. For removed apps the search also covers
  `/Library/Application Support`, `Caches`, `Preferences`, `Logs`, launch agents and
  daemons (user and system) and `/Library/PrivilegedHelperTools`.
- **Matching** uses no list of known apps or suffixes. An entry belongs to the app when
  it is named after one of its IDs, or a longer ID (`<id>.ShipIt`, `<id>.<host-uuid>`)
  that the system does not have registered as a separate app. Launch Services is
  asked, so a sibling product (`com.vendor.app.lite`) installed anywhere is never touched.
  Name-only matches and group containers are listed but not pre-selected. A developer
  team's shared containers are never attributed to a single app. Launch items match on
  their label or a program path inside the app bundle.
- **Removed apps**: IDs that no installed app owns are grouped per app (helper IDs fold
  into the parent). "Installed" is decided by the Mac itself, so it works on any system:
  Launch Services registrations (any volume or folder), loaded launchd jobs and launch
  agents whose program still exists, an Applications walk (including subfolders and
  `/Volumes/*/Applications`), Spotlight's app list when indexing is on, iOS app wrappers,
  and macOS system apps. Code-host and framework namespaces (`com.github`, `com.electron`…)
  are never treated as one vendor. Each group gets a
  confidence level from where its files are, how long they have been idle, whether the
  app is sitting in the Trash, and whether another app from the same vendor is installed.
- **System-wide leftovers**: a launch agent/daemon counts only when the program it runs
  no longer exists, and a privileged helper only when no launch daemon references it.
  Services that ship with macOS (namespaces read from `/System/Library/Launch*`) and
  rotated log files are never reported. Items in `/Library` are flagged "needs
  administrator"; if the normal Trash move is refused, the result card offers the
  administrator prompt (or the exact Terminal commands) to finish the job.
- **Removal** goes through `ArtifactCleaner` (root-scoped, identity-checked, Trash by default).
  Groups can be ignored, and the result card links to the Trash and cleanup history.

### System Settings links

Screens that correspond to a System Settings pane show a link in their header (Battery,
Network, Storage, Login Items, Extensions, Software Update, Spotlight, Time Machine, each
Privacy & Security permission…). App detail lists the app's privacy grants with a button
to the exact pane, plus Notifications, Login Items, Extensions, Full Disk Access and App
Management. Pane IDs are not hard-coded per macOS version: at launch MacLean reads
the Settings extensions shipped with the running macOS, uses a pane ID only if that
version declares it (falling back to the classic preference-pane ID, then to System
Settings itself), and appends a Privacy anchor only if the Privacy & Security
extension knows it. ⌘, opens MacLean's own settings; the **Go** menu jumps to sections and panes.

### Editable rules

Cleanup → Rules lets you switch any rule off, and edit a built-in rule's name, risk,
auto-select and excluded names (and the age limit of large-file rules). Locations of
built-in rules are fixed. **New Rule** adds a custom rule for a folder inside your
home folder, in one of three modes: each entry inside the folder, the folder as a
whole, or large files (report only). Every rule has a read-only **Test** that lists
what it would find right now, and drafts can be tested before saving.

Edits live in `~/Library/Application Support/MacLean/rules.json` (override with
`MACLEAN_RULES_FILE`) and are used by both the app and the CLI. They can be exported
and imported. Custom rules are validated by the engine: they must stay inside the
home folder, cannot target top-level folders such as Documents or Downloads, and can
never touch Keychains, Mail, Messages, Photos, iCloud Drive, cookies, SSH/GPG/AWS keys
or MacLean's own data. Custom rules never run as root.

Scan logs are written to `~/Library/Application Support/MacLean/scan-logs` (the 20
most recent are kept). The log detail is Summary, Detailed (default) or Trace.

```sh
swift run MacLeanApp
# or
scripts/package-app.sh   # dist/MacLean.app
```

The GUI drives the bundled CLI (`Contents/MacOS/maclean`) and decodes its JSON;
it does not duplicate scanner logic. The app must ship the CLI next to the GUI
executable and the resource bundle/YARA binaries in `Contents/Resources`.

### Realtime XPC monitor

`maclean-monitor` is a per-user LaunchAgent that watches `~/Downloads`,
`~/Desktop`, `~/Documents`, `~/Library/Application Support`,
`~/Library/LaunchAgents`, `/Library/LaunchAgents`, `/Library/LaunchDaemons`, and
`/Applications`. On FSEvents changes it debounces the paths, scans the changed
files with the loaded corpus (including YARA), and persists findings to
`~/Library/Application Support/MacLean/alerts.json`.

The GUI installs the agent with `launchctl bootstrap gui/$UID`; it exposes a Mach
XPC service named `xyz.nyora.maclean.monitor` with start/stop/status/alerts/scan/
quarantine methods. There is **no privileged helper** and no root escalation.
The monitor defaults to `https://corpus.nyora.xyz/panther_corpus.sqlite`; the CLI
still requires an explicit `--corpus` so builds without that corpus remain
usable. Quarantine moves a file into
`~/Library/Application Support/MacLean/Quarantine/<uuid>/` with a JSON record.

You can run the monitor in the foreground for debugging:

```sh
swift run maclean-monitor --foreground --watch ~/Downloads \
  --corpus ~/corp/panther_corpus_plaintext.sqlite --state-dir /tmp/maclean-monitor
```

The XPC service is only registered when launchd starts the agent. The GUI's
Realtime screen writes the LaunchAgent plist and starts it after confirmation.

### Deep scan and protected stores

The **Deep Scan** screen and `maclean deep` combine the modules that macOS
protects:

- **TCC permissions** — reads `~/Library/Application Support/com.apple.TCC/TCC.db`
  (falling back to `/Library/Application Support/com.apple.TCC/TCC.db`) and lists
  service/client/auth state. `permissions --reset <service> --bundle <bundle>
  --apply --yes` uses Apple's `tccutil`; maclean never edits `TCC.db`.
- **Mail Trash** — finds `Deleted Messages`/`Trash` `.mbox` mailboxes and counts
  `.emlx` messages and bytes. `mail --trash --apply --yes` moves those messages to
  the macOS Trash; Mail may rebuild its index.
- **Photos duplicates** — hashes `.photoslibrary/originals` and reports exact
  duplicates plus optional dHash similar images. `photos --apply --yes` keeps the
  first file in each exact group and moves the rest to the macOS Trash; back up the
  library first and let Photos repair it.
- **Deleted users** — `.dmg` installers left in `/Users/DeletedUsers` (matching the
  original task, which does not scan whole deleted home directories).
- **Document versions** — `documentversions` and Deep Scan use the disassembly-confirmed
  Sketch and Apple iWork content types, `NSFileVersion`, and the original
  4-hour sibling-version selection window. Removal is per version through
  `NSFileVersion`, not container deletion.
- **System caches and logs** — sizes `/Library/Caches`, `/Library/Logs`,
  `/private/var/log`, `/private/var/db/diagnostics`, and `/private/var/db/uuidtext`.
- **Universal binaries** — enumerates app and nested Mach-O binaries, reads architectures via `lipo -archs`, and estimates thin savings. `system --thin <arch> --apply --yes` backs up each binary, thins it, and re-signs the app ad-hoc; it restores the backup if either step fails.

Root-only cleanup is explicit: `sudo maclean system --apply --yes --permanent
--include deleted-user --include system-cache`. Document versions are cleaned
with `maclean documentversions --apply --yes` or
`--include document-version`. Universal thinning can still break vendor
signatures, hardened-runtime entitlements, or app updates, even with a backup;
test the app afterward.

## Commands

| Command | What it does |
|---|---|
| `scan` | Read-only scan of all junk categories, or one with `--category` |
| `clean` | Remove scanned junk; dry run unless `--apply --yes` |
| `uninstall <app>` | Plan/remove an app bundle and its leftovers |
| `leftovers` | Read-only list of leftovers of removed apps, grouped with confidence |
| `privacy` | Browser history, cookies, autofill, sessions, recent items |
| `performance` | Startup items, local snapshots, memory; `--remove`, `--flush-dns` |
| `duplicates` | Exact duplicates by SHA-256, or `--similar-images` via dHash |
| `lens [path]` | Disk-usage tree from a full parallel scan (`--depth`, `--top`, `--verbose`) |
| `mail` | Mail attachments and Mail Downloads; `--trash` reports or moves Deleted Messages to Trash |
| `permissions` | TCC permission grants; `--reset <service> --bundle <bundle> --apply --yes` |
| `photos` | Exact/similar duplicate originals; `--apply --yes` moves exact extras to Trash |
| `system` | Deleted users, document versions, system caches/logs, universal binaries; root cleanup and `--thin` |
| `documentversions` | Document versions via Spotlight discovery + NSFileVersion |
| `deep` | All protected-store modules in one report |
| `diskimages` | Old, large `.dmg`/`.iso`/`.sparseimage` files |
| `cloud` | Local Dropbox/OneDrive/Google Drive/iCloud usage and large files |
| `updates` | Pending macOS updates (`softwareupdate -l`) |
| `protection` | Security audit using the six `PANScanConfiguration`-equivalent profiles |
| `apps` | Installed applications and sizes; `--unused-days <n>` filters by last use |
| `quarantine <path>` | Move a file into the MacLean quarantine with a metadata record |
| `rules` | Every rule with its state (`[off]`, `[edited]`, `[custom]`) |

Categories for `scan`/`clean`: `system`, `dev`, `browser`, `ai`, `updates`,
`trash`, `large`. `scan` and `clean` accept `--verbose` (rules, folders, skipped
entries, findings, timings on stderr) or `--trace` (also every measured path).

### Examples

```sh
maclean scan
maclean scan --category dev --min-size 50
maclean scan --json | jq '.items[0]'

maclean clean                          # dry run
maclean clean --apply --yes            # move auto-selected items to Trash
maclean clean --category system --apply --yes --permanent

maclean uninstall "Binary Ninja"       # dry run
maclean uninstall "Binary Ninja" --apply --yes
maclean uninstall "Binary Ninja" --apply --yes --force  # if it is still running

maclean privacy                        # list, changes nothing
maclean privacy --include-caution --apply --yes  # refuses if a browser is running
maclean privacy --include-caution --apply --yes --force

maclean performance
maclean performance --flush-dns --yes
maclean performance --remove ~/Library/LaunchAgents/com.example.plist --yes

maclean duplicates --path ~/Downloads --min-size 10
maclean duplicates --path ~/Pictures --similar-images

maclean lens ~/Library --depth 2 --top 10
maclean mail --include-caution --apply --yes
maclean diskimages --older-than 60 --min-size 200
maclean cloud --min-size 500
maclean updates
maclean protection --profile protected
maclean protection --profile protected --clamav
maclean protection --profile protected --corpus ~/corp/panther_corpus_plaintext.sqlite
maclean protection --profile protected --no-bundled-rules
maclean protection --profile protected --yara-rules ~/yara-rules
maclean protection --profile protected \
  --corpus https://corpus.nyora.xyz/panther_corpus.sqlite --no-corpus-yara
maclean protection --profile protected-dirs --path ~/Downloads \
  --corpus ~/corp/panther_corpus_plaintext.sqlite
maclean protection --profile paranoid --path ~/Downloads \
  --yara-rules ~/.local/share/maclean/corpus/signature-base/yara

maclean apps --unused-days 180
maclean quarantine ~/Downloads/suspicious.bin --reason "realtime alert" --json

maclean permissions
maclean permissions --reset kTCCServiceCamera --bundle com.example.app --apply --yes
maclean photos --similar
maclean mail --trash
maclean system
maclean deep --json
maclean mail --trash --apply --yes
maclean photos --apply --yes
maclean documentversions --apply --yes
sudo maclean system --apply --yes --permanent --include system-cache
maclean system --thin arm64 --apply --yes
```

Exit codes: `0` success, `1` partial failure, `2` usage or safety refusal.

## Using a Panther corpus database

`--corpus <sqlite|url>` loads a **user-supplied** Panther-format rule database at
runtime, either from a local path or an HTTPS URL. The database is never bundled,
copied into the repository, or shipped; `.sqlite` files are gitignored. Use it
only if you are entitled to possess it.

Remote corpora are downloaded to `~/Library/Caches/maclean/corpus`, validated for
the SQLite header and a 64 MiB size cap, written atomically with `0600`
permissions, and cached for 24 hours. Use `--corpus-refresh` to bypass the cache
and re-download.

Schema `5.6.1` (2026-10-29) is supported:

- `MalwareRuleHash` / `_Extended` — size + SHA-256 matches (8,061 rules)
- `MalwareRulePath` / `_Extended` — exact path, or parent path + anchored name
  regex (3,708 rules; no globs in this corpus)
- `MalwareRuleLaunchAgent` / `_Extended` — anchored plist basename without
  `.plist`, plus optional contents regex (897 rules)
- `MalwareRuleTeamID` / `_Extended` — Mach-O code-signing Team ID, parsed from
  the embedded CodeDirectory (3,530 rules)
- `MalwareRuleSectionHash` + `MalwareRuleSectionHashData` / `_Extended` —
  SHA-256 of Mach-O sections (82 rules; `__TEXT,__text` and friends)
- `MalwareRuleYara` / `_Extended` — 2,691 YARA rules evaluated by the bundled
  engine, including per-file `file_path`, `file_name` and `file_extension`
  externals
- `MalwareRuleSafariExtension`, `MalwareRuleChromeExtension`,
  `MalwareRuleHomepage`, `MalwareRuleProfile` — browser/profile checks
- `ScanTargetPath` / `ScanExclusionPath` — 40 targets with risk scores, per-target
  depth limits, root requirements and exclusions
- `Metadata` — version and update date

Matching mirrors the decompiled providers: name regexes are anchored as
`^(pattern)$` and case-sensitive; launch-agent names are the plist basename with
`.plist` removed; contents regexes run with dot-matches-line-separators; a path
rule with no name regex matches the path exactly, while one with a name regex
requires the parent path to equal the rule path and the last component to match.
Team IDs are read from the CodeDirectory TeamIdentifier; section hashes are
computed over the exact section bytes. Extended tables are loaded only for
Paranoid (`extendedRulesUsageEnabled`).

### Bundled YARA engine

Release builds carry **YARA 4.5.4** in
`Sources/MacLeanCore/Resources/bin/` as universal arm64+x86_64 binaries linked
only against `libSystem`:

- `yara` — the regular CLI, used for `--yara-rules`
- `yarac` — compiles multi-file/rule-directory inputs once before scanning
- `maclean-yara` — scans a file list in one process and sets
  `file_path`/`file_name`/`file_extension` per file, so path-based corpus rules
  work correctly
- `YARA-COPYING` — BSD-3-Clause attribution
- `OPENSSL-COPYING` — Apache-2.0 attribution for static OpenSSL
- `rules/signature-base-macos/` — 20 macOS-relevant signature-base rules under DRL 1.1, with `LICENSE` and `ATTRIBUTION.md`

No Homebrew, `yarac`, or system YARA is required at runtime. The engine is built
with the `macho` module, static OpenSSL 3.0.16, and a loop-nesting limit of 32 to
accommodate the corpus rules. Rebuild it with `scripts/vendor-yara.sh`.

Bundled open-source rules:

- The app ships 20 macOS-relevant **Neo23x0/signature-base** rule files in
  `Contents/Resources/maclean_MacLeanCore.bundle/Resources/rules/signature-base-macos`.
- Source commit: `36ab70428fc5b52701b7ee6107c853ff019ed759`; license: Detection
  Rule License 1.1 (`LICENSE` in that directory, attribution in `ATTRIBUTION.md`).
- `maclean protection` uses them by default; `--no-bundled-rules` disables them,
  and an explicit `--yara-rules <file|dir>` overrides the bundled set.
- The GUI Protection screen has a **Bundled rules** toggle.

Corpus YARA behavior:

- `protected` / `paranoid` and `protected-dirs` / `paranoid-dirs`: enabled by
  default (content scanning adds ~2.5 minutes over ~106k files on this machine).
- `fast` / `default` / `smart`: disabled; force with `--corpus-yara`.
- `--no-corpus-yara` disables it.
- The scanner skips the corpus database itself (and any SQLite file containing
  Panther's `MalwareRule` schema) so signatures cannot match their own source.

## Safety model

- **Read-only scanning.** `scan`, `privacy`, `performance`, `duplicates`,
  `lens`, `mail`, `diskimages`, `cloud`, `updates` and `apps` do not modify
  anything without an explicit apply flag.
- **Apply needs confirmation.** Destructive actions require both `--apply` and
  `--yes` (or `--yes` alone for one-shot actions such as `--flush-dns`).
- **Trash by default.** Removed items go to the macOS Trash, so they are
  recoverable. `--permanent` deletes immediately. Items already in a Trash are
  always deleted permanently.
- **Root-scoped deletion.** Every scan rule and artifact carries an allowed
  root. A path must be strictly inside that root (or be the root itself for
  whole-directory rules), after `realpath(3)` canonicalization. Symlinks are
  refused.
- **Protected paths.** `/`, `/System`, `/Library`, `/Applications`, `/Users`,
  `/usr`, `/bin`, `/sbin`, `/etc`, `/private`, `/var`, `/opt`, `/Volumes`,
  `/cores`, `/dev` and the home directory itself are always refused.
- **Caution opt-in.** Privacy data, saved passwords, mail attachments, disk
  images, system-level leftovers, local models and similar images are marked
  `review` and require `--include-caution`.
- **No privilege escalation.** Root-only rules are skipped unless the process
  already runs as root. `maclean` never invokes `sudo`. The realtime monitor is a
  user LaunchAgent, not a privileged helper.
- **Quarantine is explicit.** The CLI and the GUI's alert action move the file
  into MacLean's quarantine (never silent deletion), write a metadata record, and
  refuse symbolic links and paths outside the home directory and `/Applications`.
- **Protected-store cleanup is explicit.** Mail Trash and Photos cleanup require
  `--apply --yes`; root stores require `sudo`, `--apply --yes --permanent`; universal
  thinning requires `--apply --yes`, keeps a backup, and restores it if re-signing
  fails.

## What is implemented

| Scanner | maclean implementation |
|---|---|
| `SystemJunkScanning` | user caches/logs, saved state, crash reports, Mail downloads, iOS backups, sandbox container caches/autosave, system caches/logs (root), Xcode DerivedData/Archives/DeviceSupport/previews/simulator caches/runtimes, Homebrew/npm/Gradle/Cargo/SwiftPM |
| `TrashJunkScanning` | `~/.Trash`, mounted-volume `.Trashes/<uid>` |
| `PrivacyScanning` | Chrome/Edge/Brave/Chromium/Arc history, cookies, autofill, saved passwords, sessions; Firefox history/cookies/autofill/passwords/sessions/downloads; Safari history/cookies/downloads/tabs/website data; macOS recent items |
| `UninstallerScanning` | app bundle + Application Support, caches, preferences, saved state, containers, app scripts, HTTP storage, WebKit, cookies, logs, group containers, launch agents/daemons, privileged helpers, package receipts |
| `SpaceLensScanning` | `maclean lens` sized tree |
| `OrganizeScanning` | exact duplicates (SHA-256), similar images (dHash), large-file scan |
| `PerformanceScanning` | login items, launch agents/daemons, broken-program detection, local snapshots, memory stats, DNS flush, startup-item removal |
| `MailJunkScanning` | MailData attachments and Mail Downloads |
| `CloudStorageScanning` | local Dropbox/OneDrive/Google Drive/iCloud usage and large files |
| `UpdaterScanning` | pending macOS updates + Software Update/Sparkle/system update leftovers |
| `UnusedDiskImagesScanning` | old large disk images |
| `LocalModelScanning` | Ollama, Hugging Face, PyTorch, Whisper, LM Studio model caches |
| `AIToolScanning` | Cursor, Claude and ChatGPT caches; AI model inventory |
| `CleanMyDriveScanner` | volume Trash bins (no deep external-volume scan) |
| `PANScanConfiguration` / `ProtectionModule` | `protection`: six reference profiles (Fast, Default, Smart, Protected, Protected+Dirs, Paranoid), the 13-bit option set, enumeration limits, persistence/cron/profile/extension/process checks, security posture, mail attachments, external drives, bundled YARA engine, optional ClamAV scanning, and optional runtime-loading of a user-supplied Panther corpus (hash/path/launch-agent/extension/homepage/profile/TeamID/section/YARA rules) |
| `ProtectionModule` realtime path | `maclean-monitor`: FSEvents watcher, user LaunchAgent, Mach XPC service, corpus/YARA scanning of changed files, persisted alerts, GUI install/start/stop/alerts, quarantine action |
| Quarantine | `maclean quarantine` + XPC quarantine action, metadata records, symlink/outside-home refusals |
| Uninstaller unused-apps view | `maclean apps --unused-days <n>` using Spotlight's `kMDItemLastUsedDate` |
| `CMDeletedUsersScanTask` | `system`: `.dmg` installers under `/Users/DeletedUsers`; root cleanup |
| `CMDocumentVersionsScanTask` | `documentversions`/`deep`: Spotlight-style candidate discovery, `NSFileVersion`, and the original 4-hour sibling selection window |
| `CMUniversalBinariesScanTask` | `system`: app and nested Mach-O binaries via `lipo -archs`; skips `/System` and `/Library/Apple` apps; estimated thin savings |
| Deep system caches | `system`: `/Library/Caches`, `/Library/Logs`, `/private/var/log`, `/private/var/db/diagnostics`, and `/private/var/db/uuidtext` |
| `MailJunkScanning` (Trash) | `mail --trash`: Deleted Messages/Trash `.mbox` counts and cleanup; extra module |
| Photos Organize scanning | `photos`/`deep`: exact SHA-256 and optional dHash duplicate originals in `.photoslibrary/originals` |
| Permissions kit | `permissions`: TCC `access` grants and `tccutil reset`; reads the user DB, then the system DB |

## What is out of scope

Literal full parity is not achievable or appropriate for this project:

- **Menu-bar app, onboarding, health monitor.** The SwiftUI app covers the main
  modules; these shell features are not implemented.
- **Licensing, MAS receipts, telemetry, analytics, update feeds.**
- **Privileged helper chain.** The realtime monitor is a user LaunchAgent with a
  Mach XPC service. maclean never installs a root helper or asks for `sudo`.
- **Bundled malware signatures (`PANEngine`, YARA rules, `PANMalwareDatabase`).** No
  corpus or signature data is bundled. `maclean protection` implements the
  engine's configuration model and local heuristic checks, ships the open-source
  YARA engine for user/corpus rules, can use ClamAV through `clamscan`, and can
  load a **user-supplied** Panther-format SQLite corpus at runtime. Copying a
  corpus into the repository is not legal unless you have the rights to do so.
- **Gmail / Google Drive / Dropbox / OneDrive APIs.** Cloud cleanup that acts on
  server-side data requires each provider's OAuth app and credentials. maclean
  inventories and cleans only local copies and caches.
- **Sparkle/MAS app-update checks.** maclean checks macOS updates only;
  app-specific feeds would require network access and vendor feed parsing.
- **Mail Trash and Photos library deletion.** Both are protected stores; maclean
  supports explicit `--apply --yes` cleanup that moves files to the macOS Trash,
  but raw deletion can corrupt Mail's index or the Photos library database. Back
  up the Photos library and expect Mail to rebuild its index.
- **Direct TCC database edits.** maclean lists TCC grants and resets them through
  Apple's `tccutil`; it never edits `TCC.db`.
- **Root/volume-only cleanup.** Deleted-user homes, document versions, and system
  caches/logs require `sudo` and `--apply --yes --permanent`. Universal thinning
  requires `--apply --yes`, keeps a backup, and re-signs ad-hoc; it can still break
  vendor signatures, entitlements, or app updates.

## Open-source detection corpora

`maclean` ships the bundled signature-base macOS subset described above. The
`protection` command can also use these open-source corpora, installed and
updated by you:

| Corpus | License | Coverage | How to use |
|---|---|---|---|
| **ClamAV** + official CVDs | Engine GPL-2.0; database distributed free by Cisco Talos (update with `freshclam`) | General malware incl. macOS families | `brew install clamav && freshclam`; `maclean protection --clamav --path ~/Downloads` |
| **YARA Forge Core** | Tooling GPL-3.0; each rule keeps its source license | Curated weekly package from 45+ repos, high accuracy/low FP | Download a release package, unzip, pass the rules directory/file to `--yara-rules` |
| **Neo23x0/signature-base** | Detection Rule License 1.1 (attribution) | ~15 macOS-specific rules plus broad cross-platform coverage | `git clone https://github.com/Neo23x0/signature-base`; pass `signature-base/yara` as `--yara-rules` |
| **Yara-Rules/rules** | GPL-2.0 | Older, small macOS set; general malware | Pass the directory/file at runtime; GPL applies to the rules |
| **bartblaze/Yara-rules** | TLP:CLEAR, retain metadata | Broad general rules, almost no macOS-specific entries | Pass the directory at runtime |
| **Elastic protections-artifacts** | Elastic License 2.0 — source-available, **not OSI/OSS** | Strong cross-platform and macOS YARA rules | Only if you comply with the Elastic license; do not redistribute as OSS |
| **Loki-RS** | GPL-3.0 | Scanner, not a corpus; uses YARA Forge | Alternative engine if you want TUI/JSONL reports |

Rules are compiled by the bundled YARA engine. Findings carry the rule
identifier; corpus findings also map back to the malware family and rule ID.
The CLI never downloads or bundles a corpus implicitly. The GUI Protection screen
and the realtime monitor default to the Nyora Panther corpus URL above; no corpus
is committed to the repository. Check each corpus's license before redistributing
results or rules.

Open-source rule compatibility:

- Rules using `filename`, `filepath`, `filetype`, `extension`, and `owner`
  externals are supported alongside `file_path`, `file_name`, and
  `file_extension`; the bundled helper applies them per file.
- The vendored engine now statically links OpenSSL 3.0.16, so PE certificate
  fields such as `pe.number_of_signatures` and `pe.signatures` compile.
- Signature-base (748 files, 5,942 rules) compiles and scans; about 17–20 files
  are macOS-oriented.
- YARA Forge Core (one package, 5,123 rules) compiles and scans, but is mostly
  PE/Windows and is not a substitute for macOS-specific coverage.

The YARA **engine** is bundled with the app; the corpora above are not. If you
package a `.app`, ship `maclean_MacLeanCore.bundle` (or at least
`Contents/Resources/bin`) alongside the executable.

## Packaging

```sh
scripts/package-app.sh   # SwiftUI app + CLI + YARA -> dist/MacLean.app
scripts/package-cli.sh   # CLI-only app -> dist/MacLeanCLI.app
```

`package-app.sh` builds the GUI, CLI, and monitor, places them next to each other
in `Contents/MacOS`, copies the bundled `yara`/`yarac`/`maclean-yara` engines and
the SwiftPM resource bundle into `Contents/Resources`, writes the Info.plist, and
ad-hoc signs the app. The GUI installs the monitor LaunchAgent when you confirm
it in the Realtime screen. It is not notarized; distribute it as an unsigned/
ad-hoc build or sign it with your Developer ID.

Do not distribute a bare `maclean` binary without the resource bundle, or YARA
support will fall back to a system installation.

## Architecture

```
Sources/MacLeanCore
  Models.swift        Categories, risk, JunkItem, ScanReport
  Rules.swift         Declarative rule table and root resolution
  Scanner.swift       Rule-driven scan, dedupe, symlink skipping
  FileSizer.swift     Allocated-size and file-count measurement
  Safety.swift        realpath-based deletion boundary checks
  Cleaner.swift       Rule selection and Trash/permanent removal
  Artifact.swift      Specialized scan results + root-scoped cleaner
  Uninstaller.swift   App bundle + uninstall plan
  Leftovers.swift     App identity, leftover matching, removed-app groups
  Privacy.swift       Browser and recent-item artifacts
  Performance.swift   Launch items, snapshots, memory, DNS
  Duplicates.swift    SHA-256 duplicate groups + dHash similar images
  Lens.swift          Sized directory tree
  MailScanner.swift   Mail attachments
  DiskImages.swift    Old disk images
  Cloud.swift         Local cloud-folder inventory
  Updates.swift       softwareupdate wrapper
  ProtectionConfig.swift  PANScanConfiguration-equivalent profiles and options
  ProtectionScanner.swift Heuristic persistence/security audit
  Yara.swift          User-supplied YARA rules (uses bundled engine)
  YaraEngine.swift    Resolves bundled yara / maclean-yara before PATH
  CorpusYara.swift    Exports and runs the corpus's 2,691 YARA rules
  ClamAV.swift        Optional ClamAV engine + CVD database via `clamscan`
  PantherCorpus.swift Runtime loader for a user-supplied Panther SQLite corpus
  CorpusScanner.swift Indexed corpus matching (hash/path/launch/extensions/team/sections/YARA)
  MachOAnalyzer.swift Mach-O section hashing and code-signing Team ID parsing
  Resources/bin/      Bundled universal `yara`, `yarac`, and `maclean-yara` binaries
  AppCatalog.swift    Installed application inventory and unused-app lookup
  BundledRules.swift  Resolves the bundled signature-base macOS rule set
  MonitorProtocol.swift  XPC protocol, alert/status models, monitor defaults
  Quarantine.swift    Quarantine records and safe file moves
  Permissions.swift   TCC access listing and tccutil reset
  MailTrash.swift     Deleted Messages / Trash mailbox report
  Photos.swift        Photos originals duplicate report
  DocumentVersions.swift Spotlight-style versions, 4-hour selection, NSFileVersion cleanup
  ProtectedStores.swift Deleted users, document versions, system caches, universal binaries
  DeepScan.swift      Aggregated deep report
  DeepCleaner.swift   Mail Trash, Photos duplicate, and root-store cleanup
  UniversalThinner.swift  Backup, lipo -thin, and ad-hoc re-sign
Sources/maclean
  main.swift          Argument parsing, scan/clean/apps/rules/quarantine
  AdvancedCommands.swift  Specialized commands and JSON output
Sources/maclean-monitor
  main.swift          XPC listener/service and foreground mode
  MonitorEngine.swift FSEvents watcher, debounce, corpus scan, alerts, quarantine
Sources/MacLeanApp
  MacLeanApp.swift    SwiftUI entry point, CLI runner, JSON models
  AppModel.swift      UI state and command orchestration
  ContentView.swift   Sidebar, cards, rows, status bar
  SmartScanView.swift Smart Scan and Junk screens
  UninstallerView.swift
  FeatureViews.swift  Privacy, Performance, Protection, Settings
  RealtimeView.swift  Monitor status, alerts, install/start/stop, quarantine
  DeepView.swift      Permissions, Photos, Mail Trash, protected stores
  MonitorClient.swift NSXPCConnection client and LaunchAgent installer
```

## Development

```sh
swift test
swift build -c release
```

Tests use temporary home directories (created, then canonicalized with
`realpath`) and never touch your real caches, Trash, launch agents, or privacy
data. They cover rule scanning, size measurement, symlink handling, selection
policy, safety refusals, whole-root deletion, uninstaller leftovers, privacy
discovery, startup-item parsing, duplicates, lens sizing, disk images, mail
attachments, cloud inventory, app metadata, canonical path handling, the six
protection profiles, option-bit layout, protection detectors, corpus loading,
corpus hash/path/launch-agent/extension/TeamID/section/YARA matching, explicit
single-file corpus targets, quarantine moves and refusals, TCC parsing, Mail
Trash discovery and cleanup, Photos duplicate detection and cleanup,
document-version discovery/selection/cleanup, protected-store sizing and cleanup,
universal binary detection and thinning, and the bundled YARA helper.

## License

MIT. See `LICENSE`.
