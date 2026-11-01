import AppKit
import Foundation
import MacLeanCore

/// Blocking, read-mostly probes. Everything here runs off the main actor via `engine {}`.
enum PrivacyProbe {
    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    // MARK: Saved application state

    static func savedStates() -> [PrivacySavedState] {
        let root = home.appendingPathComponent("Library/Saved Application State")
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: []) else { return [] }
        var states: [PrivacySavedState] = []
        for entry in entries where entry.pathExtension == "savedState" {
            let size = FileSizer.measure(entry)
            if size.isSymbolicLink { continue }
            let bundle = entry.deletingPathExtension().lastPathComponent
            let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)?.deletingPathExtension().lastPathComponent
            states.append(PrivacySavedState(path: entry.path, bundleID: bundle, appName: app, bytes: size.bytes, files: size.files, modified: size.modified))
        }
        return states.sorted { $0.bytes > $1.bytes }
    }

    static func directoryListing(_ path: String) -> [(name: String, bytes: Int64, modified: Date?)] {
        let url = URL(fileURLWithPath: path)
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: []) else { return [] }
        return entries.map { entry in
            let size = FileSizer.measure(entry)
            return (entry.lastPathComponent, size.bytes, size.modified)
        }
        .sorted { $0.bytes > $1.bytes }
    }

    // MARK: Quarantine events

    static var quarantineDB: String {
        home.appendingPathComponent("Library/Preferences/com.apple.LaunchServices.QuarantineEventsV2").path
    }

    private static let sep = "\u{1F}"

    private static func sqlite(_ db: String, _ sql: String, readonly: Bool = true) -> ProcessResult {
        var args = ["-separator", sep]
        if readonly { args.append("-readonly") }
        args += [db, sql]
        return ProcessRunner.run("/usr/bin/sqlite3", args, timeout: 30)
    }

    static func quarantine() -> PrivacyQuarantineReport {
        let db = quarantineDB
        let fm = FileManager.default
        var report = PrivacyQuarantineReport(database: db, exists: fm.fileExists(atPath: db), bytes: 0, count: 0, agents: [], hosts: [], events: [], error: nil)
        guard report.exists else { return report }
        report.bytes = ((try? fm.attributesOfItem(atPath: db)[.size]) as? NSNumber)?.int64Value ?? 0
        for suffix in ["-wal", "-shm"] {
            report.bytes += ((try? fm.attributesOfItem(atPath: db + suffix)[.size]) as? NSNumber)?.int64Value ?? 0
        }

        let count = sqlite(db, "SELECT COUNT(*) FROM LSQuarantineEvent;")
        guard count.status == 0 else {
            report.error = count.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "sqlite3 exited with status \(count.status)" : count.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return report
        }
        report.count = Int(count.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0

        let agents = sqlite(db, "SELECT COALESCE(NULLIF(LSQuarantineAgentName,''),'Unknown'), COUNT(*) FROM LSQuarantineEvent GROUP BY 1 ORDER BY 2 DESC LIMIT 25;")
        report.agents = agents.stdout.split(separator: "\n").compactMap { line in
            let parts = line.components(separatedBy: sep)
            guard parts.count == 2, let n = Int(parts[1]) else { return nil }
            return (parts[0], n)
        }

        let urls = sqlite(db, "SELECT COALESCE(NULLIF(LSQuarantineOriginURLString,''), LSQuarantineDataURLString, '') FROM LSQuarantineEvent;")
        var hostCounts: [String: Int] = [:]
        for line in urls.stdout.split(separator: "\n") {
            let host = URL(string: String(line))?.host ?? "(no origin)"
            hostCounts[host, default: 0] += 1
        }
        report.hosts = hostCounts.sorted { $0.value > $1.value }.prefix(25).map { ($0.key, $0.value) }

        let events = sqlite(db, "SELECT LSQuarantineEventIdentifier, COALESCE(LSQuarantineTimeStamp,0), COALESCE(LSQuarantineAgentName,''), COALESCE(LSQuarantineOriginURLString,''), COALESCE(LSQuarantineDataURLString,'') FROM LSQuarantineEvent ORDER BY LSQuarantineTimeStamp DESC LIMIT 300;")
        report.events = events.stdout.split(separator: "\n").compactMap { line in
            let parts = line.components(separatedBy: sep)
            guard parts.count >= 5 else { return nil }
            let stamp = Double(parts[1]) ?? 0
            return PrivacyQuarantineEvent(
                id: parts[0],
                date: stamp > 0 ? Date(timeIntervalSinceReferenceDate: stamp) : nil,
                agent: parts[2].isEmpty ? "Unknown" : parts[2],
                origin: parts[3],
                dataURL: parts[4]
            )
        }
        return report
    }

    static func clearQuarantine() -> PrivacyCommandOutput {
        let db = quarantineDB
        let result = sqlite(db, "DELETE FROM LSQuarantineEvent; VACUUM;", readonly: false)
        return PrivacyCommandOutput(
            title: "Clear download history",
            command: "/usr/bin/sqlite3 \(Format.abbreviated(db)) 'DELETE FROM LSQuarantineEvent; VACUUM;'",
            status: result.status,
            output: (result.stdout + result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    // MARK: Shell history

    static let shellCandidates: [(String, String)] = [
        (".zsh_history", "zsh"),
        (".bash_history", "bash"),
        (".python_history", "Python REPL"),
        (".node_repl_history", "Node REPL"),
        (".lesshst", "less"),
        (".sqlite_history", "SQLite shell"),
        (".mysql_history", "MySQL shell"),
        (".psql_history", "PostgreSQL shell"),
        (".irb_history", "Ruby IRB"),
        (".rediscli_history", "Redis CLI"),
    ]

    static func shellFiles() -> [PrivacyShellFile] {
        let fm = FileManager.default
        return shellCandidates.map { name, shell in
            let path = home.appendingPathComponent(name).path
            var isDir: ObjCBool = false
            let exists = fm.fileExists(atPath: path, isDirectory: &isDir) && !isDir.boolValue
            guard exists, let attrs = try? fm.attributesOfItem(atPath: path) else {
                return PrivacyShellFile(name: name, path: path, shell: shell, exists: false, bytes: 0, lines: 0, modified: nil)
            }
            let bytes = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            let data = (try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)) ?? Data()
            let lines = data.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
            return PrivacyShellFile(name: name, path: path, shell: shell, exists: true, bytes: bytes, lines: lines, modified: attrs[.modificationDate] as? Date)
        }
    }

    static func shellInsight(_ path: String) -> PrivacyShellInsight {
        let data = (try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)) ?? Data()
        let text = String(decoding: data, as: UTF8.self)
        var counts: [String: Int] = [:]
        var first: Date?
        var last: Date?
        var stamped = 0
        var unique = Set<String>()
        for raw in text.split(separator: "\n") {
            var line = Substring(raw)
            if line.hasPrefix(": "), let semi = line.firstIndex(of: ";") {
                let meta = line[line.index(line.startIndex, offsetBy: 2)..<semi]
                if let stampText = meta.split(separator: ":").first, let stamp = Double(stampText) {
                    let date = Date(timeIntervalSince1970: stamp)
                    stamped += 1
                    if first == nil || date < first! { first = date }
                    if last == nil || date > last! { last = date }
                }
                line = line[line.index(after: semi)...]
            } else if line.hasPrefix("#"), let stamp = Double(line.dropFirst()) {
                let date = Date(timeIntervalSince1970: stamp)
                stamped += 1
                if first == nil || date < first! { first = date }
                if last == nil || date > last! { last = date }
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            unique.insert(trimmed)
            let word = trimmed.split(separator: " ").first.map(String.init) ?? trimmed
            counts[String(word.prefix(40)), default: 0] += 1
        }
        let top = counts.sorted { $0.value > $1.value }.prefix(20).map { ($0.key, $0.value) }
        return PrivacyShellInsight(topCommands: top, first: first, last: last, timestamped: stamped, uniqueCommands: unique.count)
    }

    /// Truncates the listed history files to zero bytes. Only the fixed
    /// candidate names directly inside the home folder are accepted.
    static func truncateHistory(_ paths: [String]) -> RemovalSummary {
        let allowed = Set(shellCandidates.map { home.appendingPathComponent($0.0).path })
        var summary = RemovalSummary()
        let fm = FileManager.default
        for path in paths {
            guard allowed.contains(path) else {
                summary.failures.append((path, "not a known history file"))
                continue
            }
            let resolved = PathCanon.resolve(path)
            guard resolved == path else {
                summary.failures.append((path, "is a symbolic link; refusing"))
                continue
            }
            let size = ((try? fm.attributesOfItem(atPath: path)[.size]) as? NSNumber)?.int64Value ?? 0
            do {
                let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
                try handle.truncate(atOffset: 0)
                try handle.close()
                summary.removed += 1
                summary.bytes += size
            } catch {
                summary.failures.append((path, error.localizedDescription))
            }
        }
        return summary
    }

    // MARK: Wi-Fi

    static func wifiDevice() -> String? {
        let result = ProcessRunner.run("/usr/sbin/networksetup", ["-listallhardwareports"], timeout: 15)
        var port: String?
        for line in result.stdout.split(separator: "\n") {
            if line.hasPrefix("Hardware Port:") {
                port = line.replacingOccurrences(of: "Hardware Port:", with: "").trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("Device:"), let current = port, current == "Wi-Fi" || current == "AirPort" {
                return line.replacingOccurrences(of: "Device:", with: "").trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    static func wifi() -> PrivacyWifiReport {
        guard let device = wifiDevice() else {
            return PrivacyWifiReport(device: nil, current: nil, networks: [], raw: "", error: "No Wi-Fi hardware port was found by networksetup -listallhardwareports.")
        }
        let list = ProcessRunner.run("/usr/sbin/networksetup", ["-listpreferredwirelessnetworks", device], timeout: 20)
        let lines = list.stdout.split(separator: "\n").map(String.init)
        let networks = lines.dropFirst().map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let current = ProcessRunner.run("/usr/sbin/networksetup", ["-getairportnetwork", device], timeout: 10)
        var currentName: String?
        if let range = current.stdout.range(of: "Current Wi-Fi Network: ") {
            currentName = current.stdout[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let error = list.status == 0 ? nil : (list.stderr + list.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
        return PrivacyWifiReport(device: device, current: currentName, networks: networks, raw: list.stdout, error: error)
    }

    static func removeWifiCommand(device: String, names: [String]) -> String {
        names.map { "sudo /usr/sbin/networksetup -removepreferredwirelessnetwork \(device) '\($0.replacingOccurrences(of: "'", with: "'\\''"))'" }
            .joined(separator: "\n")
    }

    /// Removes networks through one administrator prompt. Names are passed as
    /// argv, never interpolated into the script source.
    static func removeWifi(device: String, names: [String]) -> PrivacyCommandOutput {
        let script = [
            "on run argv",
            "set dev to item 1 of argv",
            "set cmd to \"\"",
            "repeat with i from 2 to count of argv",
            "set cmd to cmd & \"/usr/sbin/networksetup -removepreferredwirelessnetwork \" & quoted form of dev & \" \" & quoted form of (item i of argv) & \"; \"",
            "end repeat",
            "do shell script cmd with administrator privileges",
            "end run",
        ]
        var args: [String] = []
        for line in script { args += ["-e", line] }
        args.append(device)
        args += names
        let result = ProcessRunner.run("/usr/bin/osascript", args, timeout: 180)
        return PrivacyCommandOutput(
            title: "Remove \(names.count) Wi-Fi network\(names.count == 1 ? "" : "s")",
            command: removeWifiCommand(device: device, names: names),
            status: result.status,
            output: (result.stdout + result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    // MARK: Quick Look

    static func quickLook() -> PrivacyQuickLookReport {
        let conf = ProcessRunner.run("/usr/bin/getconf", ["DARWIN_USER_CACHE_DIR"], timeout: 5)
        let base = conf.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        var report = PrivacyQuickLookReport(path: nil, bytes: 0, files: 0, modified: nil, generators: 0)
        if !base.isEmpty {
            let path = URL(fileURLWithPath: base).appendingPathComponent("com.apple.QuickLook.thumbnailcache").path
            if FileManager.default.fileExists(atPath: path) {
                let size = FileSizer.measure(URL(fileURLWithPath: path))
                report.path = path
                report.bytes = size.bytes
                report.files = size.files
                report.modified = size.modified
            }
        }
        let plugins = ProcessRunner.run("/usr/bin/qlmanage", ["-m", "plugins"], timeout: 20)
        report.generators = plugins.stdout.split(separator: "\n").filter { $0.contains("->") }.count
        return report
    }

    static func resetQuickLook() -> PrivacyCommandOutput {
        let result = ProcessRunner.run("/usr/bin/qlmanage", ["-r", "cache"], timeout: 60)
        return PrivacyCommandOutput(
            title: "Reset Quick Look cache",
            command: "qlmanage -r cache",
            status: result.status,
            output: (result.stdout + result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    // MARK: Live footprint

    /// Fast stat-only total of the listed files (directories are skipped).
    static func footprint(_ paths: [String]) -> Int64 {
        var total: Int64 = 0
        var info = stat()
        for path in paths where lstat(path, &info) == 0 {
            if (info.st_mode & S_IFMT) == S_IFREG { total += Int64(info.st_size) }
        }
        return total
    }
}
