import Foundation

/// Second-chance removal with administrator rights for items a normal
/// (user-level) removal could not delete.
///
/// Only paths that are safe to hand to root qualify: they must exist, be
/// absolute, not be symbolic links, and sit outside the system and the
/// user's protected folders. Items go to the user's Trash (owned by the user
/// again so the Trash can be emptied), launch items are unloaded first, and
/// user-immutable flags are cleared. Every item reports its own result.
public enum AdminRemoval {
    public enum Verdict: Equatable, Sendable {
        /// A retry with administrator rights may succeed.
        case elevate
        /// MacLean refuses this path on purpose; the reason says why.
        case refused(String)
        /// Already gone (removed by something else).
        case gone
        /// Not a file path (a process, a service name…).
        case notAPath
    }

    public struct ItemResult: Equatable, Sendable {
        public let path: String
        public let ok: Bool
        public let message: String
    }

    public struct Outcome: Sendable {
        public var results: [ItemResult]
        public var cancelled: Bool
        public var error: String?
        public var removed: [String] { results.filter(\.ok).map(\.path) }
        public var failed: [ItemResult] { results.filter { !$0.ok } }
    }

    /// System locations root may never touch from MacLean (SIP-protected or vital).
    static let systemDenied = ["/System", "/bin", "/sbin", "/usr", "/private/var/db", "/private/etc", "/etc", "/dev", "/cores", "/Volumes", "/private/var/vm"]
    /// …except these subtrees.
    static let systemAllowed = ["/usr/local", "/private/var/db/receipts", "/private/var/folders"]
    /// Folders that must never be removed themselves (their contents may be).
    static let keepFolders: Set<String> = [
        "/", "/Applications", "/Library", "/Users", "/private", "/private/var", "/private/tmp", "/tmp", "/var",
        "/Library/Application Support", "/Library/Caches", "/Library/Preferences", "/Library/Logs",
        "/Library/LaunchAgents", "/Library/LaunchDaemons", "/Library/PrivilegedHelperTools", "/Library/Extensions",
        "/usr/local", "/usr/local/bin", "/usr/local/lib", "/private/var/folders",
    ]
    /// Reasons that mean MacLean's own safety rules refused the item.
    static let policyMarkers = ["refusing", "outside the locations", "not a known", "quit it first", "outside the quarantine", "is running"]

    public static func verdict(path: String, reason: String, home: String = NSHomeDirectory()) -> Verdict {
        guard path.hasPrefix("/") else { return .notAPath }
        let lowerReason = reason.lowercased()
        if let marker = policyMarkers.first(where: { lowerReason.contains($0) }) {
            return .refused(marker == "quit it first" || marker == "is running" ? "the app is running — quit it first" : "refused by MacLean's safety rules")
        }
        var info = stat()
        guard lstat(path, &info) == 0 else { return .gone }
        if (info.st_mode & S_IFMT) == S_IFLNK { return .refused("symbolic link") }
        let clean = URL(fileURLWithPath: path).standardizedFileURL.path
        if clean.contains("/../") { return .refused("unusual path") }
        let resolved = clean.hasPrefix("/var/") || clean.hasPrefix("/tmp/") ? "/private" + clean : clean
        if keepFolders.contains(resolved) { return .refused("a system folder") }
        if systemDenied.contains(where: { resolved == $0 || resolved.hasPrefix($0 + "/") }),
           !systemAllowed.contains(where: { resolved == $0 || resolved.hasPrefix($0 + "/") }) {
            return .refused("protected by macOS")
        }
        if resolved == "/Users" || (resolved.hasPrefix("/Users/") && resolved.split(separator: "/").count <= 2) {
            return .refused("a home folder")
        }
        if resolved.hasPrefix(home + "/") || resolved == home {
            let relative = resolved == home ? "" : String(resolved.dropFirst(home.count + 1))
            let lower = relative.lowercased()
            if RuleBook.protectedExact.contains(where: { $0.lowercased() == lower }) { return .refused("a protected folder in your home") }
            if RuleBook.protectedPrefixes.contains(where: { lower == $0.lowercased() || lower.hasPrefix($0.lowercased() + "/") })
                && !lower.hasPrefix("library/preferences/") {
                return .refused("protected personal data")
            }
        }
        return .elevate
    }

    /// The shell script root runs. Paths are read from a NUL-separated file, so
    /// no path is ever interpolated into shell code.
    static let script = #"""
    #!/bin/bash
    LIST="$1"; TRASH="$2"; OWNER="$3"; STAMP="$(date +%s)"
    while IFS= read -r -d '' p; do
      if [ ! -e "$p" ] && [ ! -L "$p" ]; then printf 'OK\t%s\talready gone\n' "$p"; continue; fi
      if [ -L "$p" ]; then printf 'FAIL\t%s\tsymbolic link\n' "$p"; continue; fi
      case "$p" in
        /Library/LaunchDaemons/*.plist) launchctl bootout system "$p" >/dev/null 2>&1 ;;
        /Library/LaunchAgents/*.plist) launchctl bootout "gui/${OWNER%%:*}" "$p" >/dev/null 2>&1 ;;
      esac
      chflags -R nouchg "$p" 2>/dev/null
      dest="$TRASH/$(basename "$p")"
      [ -e "$dest" ] && dest="$TRASH/$STAMP-$(basename "$p")"
      if err=$(mv "$p" "$dest" 2>&1); then
        chown -R "$OWNER" "$dest" 2>/dev/null
        printf 'OK\t%s\tmoved to Trash\n' "$p"
      elif err2=$(rm -rf "$p" 2>&1) && [ ! -e "$p" ]; then
        printf 'OK\t%s\tdeleted\n' "$p"
      else
        msg="${err2:-$err}"; msg="${msg##*: }"
        printf 'FAIL\t%s\t%s\n' "$p" "$(printf '%s' "$msg" | tr '\n\t' '  ')"
      fi
    done < "$LIST"
    """#

    /// Runs the removal behind the macOS administrator password prompt.
    /// `runner` is replaceable for tests (it receives the script path and arguments).
    public static func run(
        _ paths: [String],
        elevated: Bool = true,
        home: String = NSHomeDirectory()
    ) -> Outcome {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("maclean-admin-\(UUID().uuidString)")
        do {
            try fm.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            return Outcome(results: [], cancelled: false, error: error.localizedDescription)
        }
        defer { try? fm.removeItem(at: work) }
        let list = work.appendingPathComponent("paths")
        let scriptURL = work.appendingPathComponent("remove.sh")
        var data = Data()
        for path in paths { data.append(contentsOf: Array(path.utf8)); data.append(0) }
        do {
            try data.write(to: list)
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
        } catch {
            return Outcome(results: [], cancelled: false, error: error.localizedDescription)
        }
        let trash = home + "/.Trash"
        let owner = "\(getuid()):\(getgid())"
        let command = ["/bin/bash", scriptURL.path, list.path, trash, owner].map(quote).joined(separator: " ")
        let result: ProcessResult
        if elevated {
            let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            result = ProcessRunner.run("/usr/bin/osascript", ["-e", "do shell script \"\(escaped)\" with administrator privileges"], timeout: 600)
        } else {
            result = ProcessRunner.run("/bin/bash", ["-c", command], timeout: 600)
        }
        if result.status != 0 && result.stdout.isEmpty {
            let cancelled = result.stderr.contains("-128") || result.stderr.lowercased().contains("user canceled")
            return Outcome(results: [], cancelled: cancelled, error: cancelled ? nil : result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        // osascript returns the script's output with \r line endings.
        var results = parse(result.stdout)
        let reported = Set(results.map(\.path))
        for path in paths where !reported.contains(path) {
            results.append(ItemResult(path: path, ok: false, message: "no result reported"))
        }
        return Outcome(results: results, cancelled: false, error: nil)
    }

    static func parse(_ output: String) -> [ItemResult] {
        output.replacingOccurrences(of: "\r", with: "\n").split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 2, parts[0] == "OK" || parts[0] == "FAIL" else { return nil }
            return ItemResult(path: parts[1], ok: parts[0] == "OK", message: parts.count > 2 ? parts[2] : "")
        }
    }

    public static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Commands a person can paste into Terminal to remove the items themselves.
    public static func terminalCommands(for paths: [String]) -> String {
        paths.map { "sudo rm -rf \(quote($0))" }.joined(separator: "\n")
    }

    /// A plain-language hint for an error that even root could not overcome.
    public static func hint(for message: String, path: String) -> String? {
        let lower = message.lowercased()
        if lower.contains("operation not permitted") {
            if path.hasPrefix("/System") || path.hasPrefix("/usr/") || path.hasPrefix("/bin") || path.hasPrefix("/sbin") {
                return "Protected by System Integrity Protection; macOS does not allow removing it."
            }
            return "macOS privacy protection blocked it. Give MacLean Full Disk Access (System Settings › Privacy & Security), or quit the app that owns it, then try again."
        }
        if lower.contains("resource busy") || lower.contains("in use") { return "The file is in use. Quit the app using it and try again." }
        if lower.contains("read-only file system") { return "It is on a read-only volume (for example the sealed system volume or a disk image)." }
        return nil
    }
}
