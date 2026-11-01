import AppKit
import Foundation
import MacLeanCore
import SwiftUI

// MARK: - Models

enum PerformanceStartupFilter: String, Hashable, CaseIterable, Sendable {
    case all
    case userAgents
    case globalAgents
    case daemons
    case broken
    case running

    var title: String {
        switch self {
        case .all: return "Startup Items"
        case .userAgents: return "User Launch Agents"
        case .globalAgents: return "Global Launch Agents"
        case .daemons: return "Launch Daemons"
        case .broken: return "Broken Startup Items"
        case .running: return "Running Startup Items"
        }
    }

    var icon: String {
        switch self {
        case .all: return "power"
        case .userAgents: return "person.crop.circle"
        case .globalAgents: return "person.2"
        case .daemons: return "gearshape.2"
        case .broken: return "exclamationmark.triangle"
        case .running: return "play.circle"
        }
    }

    var subtitle: String {
        switch self {
        case .all: return "Every launchd job that starts with your Mac"
        case .userAgents: return "~/Library/LaunchAgents — run when you log in"
        case .globalAgents: return "/Library/LaunchAgents — run for every user"
        case .daemons: return "LaunchDaemons — run as root at boot"
        case .broken: return "Jobs whose program no longer exists"
        case .running: return "Jobs currently loaded with a live process"
        }
    }
}

struct PerformanceLaunchStatus: Sendable, Hashable {
    var pid: Int?
    var lastExit: Int?
}

struct PerformancePlistInfo: Sendable {
    var label: String = ""
    var program: String = ""
    var arguments: [String] = []
    var runAtLoad: Bool?
    var keepAlive: String = "—"
    var startInterval: Int?
    var calendarInterval: String?
    var watchPaths: [String] = []
    var stdoutPath: String?
    var stderrPath: String?
    var disabled: Bool?
    var bundleID: String?
    var otherKeys: [(String, String)] = []
    var fileSize: Int64 = 0
    var modified: Date?
    var raw: String = ""
}

struct PerformanceLoginItem: Sendable, Hashable, Identifiable {
    var name: String
    var path: String
    var hidden: Bool
    var bytes: Int64 = 0
    var exists: Bool = false
    var id: String { name + "|" + path }
}

struct PerformanceSnapshot: Sendable, Hashable, Identifiable {
    var name: String
    var dateToken: String
    var date: Date?
    var id: String { name }
}

struct PerformancePurgeResult: Sendable {
    var before: UInt64
    var after: UInt64
    var status: Int32
    var output: String
    var date: Date
    var delta: Int64 { Int64(clamping: after) - Int64(clamping: before) }
}

struct PerformanceRunRecord: Codable, Sendable, Hashable, Identifiable {
    var id = UUID()
    var task: String
    var date: Date
    var duration: Double
    var status: Int32
    var outputTail: String
}

enum PerformanceTaskKind: Sendable {
    case flushDNS
    case process(String, [String])
    case admin(String)
}

enum PerformanceTask: String, CaseIterable, Hashable, Sendable, Identifiable {
    case flushDNS
    case reindexLaunchServices
    case rebuildSpotlight
    case clearFontCaches
    case runPeriodicScripts
    case verifyDisk
    case repairHomePermissions
    case thinSnapshots
    case freeRAM

    var id: String { rawValue }

    static let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

    var title: String {
        switch self {
        case .flushDNS: return "Flush DNS Cache"
        case .reindexLaunchServices: return "Rebuild Launch Services"
        case .rebuildSpotlight: return "Reindex Spotlight"
        case .clearFontCaches: return "Clear Font Caches"
        case .runPeriodicScripts: return "Run Maintenance Scripts"
        case .verifyDisk: return "Verify Startup Disk"
        case .repairHomePermissions: return "Repair Home Permissions"
        case .thinSnapshots: return "Thin Local Snapshots"
        case .freeRAM: return "Free Up RAM"
        }
    }

    var icon: String {
        switch self {
        case .flushDNS: return "network"
        case .reindexLaunchServices: return "arrow.triangle.2.circlepath"
        case .rebuildSpotlight: return "magnifyingglass"
        case .clearFontCaches: return "textformat"
        case .runPeriodicScripts: return "calendar.badge.clock"
        case .verifyDisk: return "internaldrive"
        case .repairHomePermissions: return "lock.shield"
        case .thinSnapshots: return "clock.arrow.circlepath"
        case .freeRAM: return "memorychip"
        }
    }

    var summary: String {
        switch self {
        case .flushDNS: return "Clears cached DNS lookups and restarts mDNSResponder."
        case .reindexLaunchServices: return "Fixes duplicate “Open With” entries and wrong default apps."
        case .rebuildSpotlight: return "Erases and rebuilds the Spotlight index of the startup disk."
        case .clearFontCaches: return "Removes per-user font caches to fix garbled or missing fonts."
        case .runPeriodicScripts: return "Runs the daily, weekly and monthly system maintenance scripts."
        case .verifyDisk: return "Checks the startup volume's file system for errors (read-only)."
        case .repairHomePermissions: return "Resets ownership and permissions of files in your home folder."
        case .thinSnapshots: return "Asks Time Machine to purge up to 10 GB of local snapshots."
        case .freeRAM: return "Flushes inactive disk cache pages so free memory goes up."
        }
    }

    var details: String {
        switch self {
        case .flushDNS:
            return "Runs the engine's DNS flush: dscacheutil -flushcache, then sends SIGHUP to mDNSResponder. Use it when websites resolve to old addresses after a DNS change or VPN switch. Restarting mDNSResponder normally requires administrator rights; if it is refused, retry as administrator."
        case .reindexLaunchServices:
            return "Kills and rebuilds the Launch Services database from the local, system and user domains. This repairs duplicate entries in Open With menus, wrong document icons and broken default-app associations. Default-app choices you set manually are kept."
        case .rebuildSpotlight:
            return "Runs mdutil -E / which erases the Spotlight store and starts a full reindex. Search results will be incomplete and mds/mdworker CPU use will be high until reindexing finishes (often 30 minutes to a few hours)."
        case .clearFontCaches:
            return "Runs atsutil databases -removeUser which deletes the current user's font registration caches. Restart apps (or log out) afterwards so fonts are re-registered."
        case .runPeriodicScripts:
            return "Runs periodic daily weekly monthly as root. These rotate system logs, clean temporary files and rebuild small databases. macOS normally runs them on schedule; running them manually helps on Macs that are often asleep."
        case .verifyDisk:
            return "Runs diskutil verifyVolume / which checks the APFS container of the startup disk. On a live system it may briefly freeze the UI while it takes a snapshot. It never modifies data."
        case .repairHomePermissions:
            return "Runs diskutil resetUserPermissions / <your uid> which resets ACLs and ownership of items in your home folder. Use it when Finder repeatedly asks for passwords or files are unexpectedly locked."
        case .thinSnapshots:
            return "Runs tmutil thinlocalsnapshots / 10000000000 4 to reclaim up to 10 GB of purgeable space held by local Time Machine snapshots, with the highest urgency. Your Time Machine backups on external disks are not affected."
        case .freeRAM:
            return "Runs purge as root. It forces disk caches to be flushed, which raises free memory immediately. macOS refills caches as needed, so the effect is temporary; use it before launching a memory-hungry app."
        }
    }

    var risk: String {
        switch self {
        case .flushDNS, .clearFontCaches, .verifyDisk, .freeRAM: return "Low"
        case .reindexLaunchServices, .runPeriodicScripts, .thinSnapshots: return "Low"
        case .rebuildSpotlight, .repairHomePermissions: return "Moderate"
        }
    }

    var needsAdmin: Bool {
        switch self {
        case .rebuildSpotlight, .runPeriodicScripts, .freeRAM, .repairHomePermissions: return true
        default: return false
        }
    }

    var kind: PerformanceTaskKind {
        switch self {
        case .flushDNS:
            return .flushDNS
        case .reindexLaunchServices:
            return .process(Self.lsregister, ["-kill", "-r", "-domain", "local", "-domain", "system", "-domain", "user"])
        case .rebuildSpotlight:
            return .admin("/usr/bin/mdutil -E /")
        case .clearFontCaches:
            return .process("/usr/bin/atsutil", ["databases", "-removeUser"])
        case .runPeriodicScripts:
            return .admin("/usr/sbin/periodic daily weekly monthly")
        case .verifyDisk:
            return .process("/usr/sbin/diskutil", ["verifyVolume", "/"])
        case .repairHomePermissions:
            return .admin("/usr/sbin/diskutil resetUserPermissions / \(getuid())")
        case .thinSnapshots:
            return .process("/usr/bin/tmutil", ["thinlocalsnapshots", "/", "10000000000", "4"])
        case .freeRAM:
            return .admin("/usr/sbin/purge")
        }
    }

    var executable: String {
        switch kind {
        case .flushDNS: return "/usr/bin/dscacheutil"
        case .process(let exe, _): return exe
        case .admin(let command): return String(command.split(separator: " ").first ?? "")
        }
    }

    var isAvailable: Bool { FileManager.default.isExecutableFile(atPath: executable) }

    var commandLine: String {
        switch kind {
        case .flushDNS: return "dscacheutil -flushcache; killall -HUP mDNSResponder"
        case .process(let exe, let args): return ([exe] + args).joined(separator: " ")
        case .admin(let command): return "sudo " + command
        }
    }

    var route: PerformanceRoute {
        switch self {
        case .flushDNS: return .flushDNS
        case .reindexLaunchServices: return .reindexLaunchServices
        case .rebuildSpotlight: return .rebuildSpotlight
        case .clearFontCaches: return .clearFontCaches
        case .runPeriodicScripts: return .runPeriodicScripts
        case .verifyDisk: return .verifyDisk
        case .repairHomePermissions: return .repairHomePermissions
        case .thinSnapshots: return .thinSnapshots
        case .freeRAM: return .freeRAM
        }
    }
}

struct PerformanceTaskRun {
    var startedAt: Date
    var finishedAt: Date?
    var output: String = ""
    var status: Int32?
    var admin: Bool
    var running: Bool { finishedAt == nil }
    var elapsed: TimeInterval { (finishedAt ?? Date()).timeIntervalSince(startedAt) }
}

// MARK: - Shell helpers (nonisolated, run inside engine{})

enum PerformanceShell {
    static func appleScriptQuote(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Runs a shell command as root through the standard macOS password prompt.
    static func runAdmin(_ command: String, timeout: TimeInterval = 3_600) -> ProcessResult {
        let script = "do shell script \(appleScriptQuote(command + " 2>&1")) with administrator privileges"
        return ProcessRunner.run("/usr/bin/osascript", ["-e", script], timeout: timeout)
    }

    static func runAppleScript(_ script: String, timeout: TimeInterval = 30) -> ProcessResult {
        ProcessRunner.run("/usr/bin/osascript", ["-e", script], timeout: timeout)
    }

    static func launchctlList() -> [String: PerformanceLaunchStatus] {
        let result = ProcessRunner.run("/bin/launchctl", ["list"], timeout: 10)
        var map: [String: PerformanceLaunchStatus] = [:]
        for line in result.stdout.split(separator: "\n").dropFirst() {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count >= 3 else { continue }
            map[String(parts[2])] = PerformanceLaunchStatus(pid: Int(parts[0]), lastExit: Int(parts[1]))
        }
        return map
    }

    static func plistInfo(path: String) -> PerformancePlistInfo {
        var info = PerformancePlistInfo()
        let url = URL(fileURLWithPath: path)
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path) {
            info.fileSize = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            info.modified = attrs[.modificationDate] as? Date
        }
        guard let dict = PlistReader.dictionary(at: url) else { return info }
        info.label = PlistReader.string("Label", in: dict) ?? url.deletingPathExtension().lastPathComponent
        info.arguments = PlistReader.strings("ProgramArguments", in: dict)
        info.program = PlistReader.string("Program", in: dict) ?? info.arguments.first ?? ""
        info.runAtLoad = dict["RunAtLoad"] as? Bool
        info.disabled = dict["Disabled"] as? Bool
        if let keep = dict["KeepAlive"] {
            if let flag = keep as? Bool { info.keepAlive = flag ? "Always" : "No" }
            else if let sub = keep as? [String: Any] { info.keepAlive = "Conditional (" + sub.keys.sorted().joined(separator: ", ") + ")" }
            else { info.keepAlive = String(describing: keep) }
        }
        info.startInterval = dict["StartInterval"] as? Int
        if let cal = dict["StartCalendarInterval"] { info.calendarInterval = describe(cal) }
        info.watchPaths = PlistReader.strings("WatchPaths", in: dict)
        info.stdoutPath = dict["StandardOutPath"] as? String
        info.stderrPath = dict["StandardErrorPath"] as? String
        info.bundleID = dict["AssociatedBundleIdentifiers"].map(describe)
        let known: Set<String> = ["Label", "Program", "ProgramArguments", "RunAtLoad", "KeepAlive", "StartInterval",
                                  "StartCalendarInterval", "WatchPaths", "StandardOutPath", "StandardErrorPath",
                                  "Disabled", "AssociatedBundleIdentifiers"]
        info.otherKeys = dict.keys.filter { !known.contains($0) }.sorted().map { ($0, describe(dict[$0] as Any)) }
        if let data = try? PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0) {
            info.raw = String(data: data, encoding: .utf8) ?? ""
        }
        return info
    }

    static func describe(_ value: Any) -> String {
        switch value {
        case let s as String: return s
        case let b as Bool: return b ? "true" : "false"
        case let n as NSNumber: return n.stringValue
        case let a as [Any]: return "[" + a.map(describe).joined(separator: ", ") + "]"
        case let d as [String: Any]: return "{" + d.keys.sorted().map { "\($0): \(describe(d[$0] as Any))" }.joined(separator: ", ") + "}"
        default: return String(describing: value)
        }
    }

    static func snapshot(from name: String) -> PerformanceSnapshot {
        var token = name
        if let range = name.range(of: "com.apple.TimeMachine.") { token = String(name[range.upperBound...]) }
        if token.hasSuffix(".local") { token = String(token.dropLast(6)) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return PerformanceSnapshot(name: name, dateToken: token, date: formatter.date(from: token))
    }

    static func isSafeToken(_ text: String) -> Bool {
        !text.isEmpty && text.allSatisfy { $0.isNumber || $0 == "-" }
    }

    static func loginItems() -> (items: [PerformanceLoginItem], error: String?) {
        let script = """
        set out to ""
        tell application "System Events"
            repeat with li in login items
                set out to out & (name of li) & tab & (path of li) & tab & (hidden of li as text) & linefeed
            end repeat
        end tell
        return out
        """
        let result = runAppleScript(script)
        guard result.status == 0 else {
            return ([], result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let items = result.stdout.split(separator: "\n").compactMap { line -> PerformanceLoginItem? in
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard let name = parts.first, !name.isEmpty else { return nil }
            var path = parts.count > 1 ? parts[1] : ""
            if path.hasSuffix("/"), path.count > 1 { path.removeLast() }
            let exists = !path.isEmpty && FileManager.default.fileExists(atPath: path)
            let bytes = exists ? FileSizer.measure(URL(fileURLWithPath: path)).bytes : 0
            return PerformanceLoginItem(name: name, path: path, hidden: parts.count > 2 && parts[2] == "true", bytes: bytes, exists: exists)
        }
        return (items, nil)
    }

    static func processInfo(pid: Int32) -> (path: String, started: String, threads: String, ppid: String, state: String) {
        let path = ProcessRunner.run("/bin/ps", ["-o", "comm=", "-p", "\(pid)"], timeout: 5).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let started = ProcessRunner.run("/bin/ps", ["-o", "lstart=", "-p", "\(pid)"], timeout: 5).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let ppid = ProcessRunner.run("/bin/ps", ["-o", "ppid=", "-p", "\(pid)"], timeout: 5).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let state = ProcessRunner.run("/bin/ps", ["-o", "state=", "-p", "\(pid)"], timeout: 5).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let threads = ProcessRunner.run("/bin/ps", ["-M", "-p", "\(pid)"], timeout: 5).stdout
            .split(separator: "\n").count
        return (path, started, threads > 1 ? "\(threads - 1)" : "—", ppid, state)
    }
}

// MARK: - Store

@MainActor
final class PerformanceStore: ObservableObject {
    static let shared = PerformanceStore()

    @Published private(set) var startupItems: [StartupItem] = []
    @Published private(set) var launchStatus: [String: PerformanceLaunchStatus] = [:]
    @Published private(set) var startupState: LoadState = .idle

    @Published private(set) var snapshots: [PerformanceSnapshot] = []
    @Published private(set) var snapshotState: LoadState = .idle

    @Published private(set) var memoryStats: MemoryStats?
    @Published private(set) var memoryState: LoadState = .idle

    @Published private(set) var loginItems: [PerformanceLoginItem] = []
    @Published private(set) var loginState: LoadState = .idle

    @Published private(set) var assertions: [String] = []
    @Published private(set) var assertionState: LoadState = .idle

    @Published private(set) var plistInfo: [String: PerformancePlistInfo] = [:]
    @Published private(set) var serviceDump: [String: String] = [:]

    @Published private(set) var runs: [PerformanceTask: PerformanceTaskRun] = [:]
    @Published private(set) var history: [PerformanceRunRecord] = []
    @Published private(set) var purgeResult: PerformancePurgeResult?
    @Published var lastFailures: [(path: String, reason: String)] = []
    @Published var busy = false

    private var processes: [PerformanceTask: Process] = [:]
    private let historyKey = "PerformanceMaintenanceHistory"

    init() {
        if let data = UserDefaults.standard.data(forKey: historyKey),
           let decoded = try? JSONDecoder().decode([PerformanceRunRecord].self, from: data) {
            history = decoded
        }
    }

    var home: String { FileManager.default.homeDirectoryForCurrentUser.path }
    var uid: uid_t { getuid() }

    // MARK: Startup items

    func loadStartupIfNeeded() {
        if startupState == .idle { Task { await loadStartup() } }
    }

    func loadStartup() async {
        startupState = .loading("Reading launchd property lists…")
        let result = await engine { () -> ([StartupItem], [String: PerformanceLaunchStatus]) in
            (PerformanceScanner.startupItems(), PerformanceShell.launchctlList())
        }
        startupItems = result.0
        launchStatus = result.1
        startupState = .loaded(Date())
    }

    func items(_ filter: PerformanceStartupFilter) -> [StartupItem] {
        let userAgents = home + "/Library/LaunchAgents/"
        switch filter {
        case .all: return startupItems
        case .userAgents: return startupItems.filter { $0.path.hasPrefix(userAgents) }
        case .globalAgents: return startupItems.filter { $0.path.hasPrefix("/Library/LaunchAgents/") }
        case .daemons: return startupItems.filter { $0.kind == "Launch daemon" }
        case .broken: return startupItems.filter(\.broken)
        case .running: return startupItems.filter { (launchStatus[$0.label]?.pid ?? 0) > 0 }
        }
    }

    func item(path: String) -> StartupItem? { startupItems.first { $0.path == path } }

    func isUserDomain(_ item: StartupItem) -> Bool { item.path.hasPrefix(home + "/") }

    func domainTarget(_ item: StartupItem) -> String {
        if item.path.hasPrefix(home + "/Library/LaunchAgents/") || item.path.hasPrefix("/Library/LaunchAgents/") {
            return "gui/\(uid)"
        }
        return "system"
    }

    func loadPlist(path: String) async {
        let label = item(path: path)?.label ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let target = item(path: path).map(domainTarget) ?? "gui/\(uid)"
        let result = await engine { () -> (PerformancePlistInfo, String) in
            let info = PerformanceShell.plistInfo(path: path)
            let print = ProcessRunner.run("/bin/launchctl", ["print", "\(target)/\(info.label.isEmpty ? label : info.label)"], timeout: 10)
            let text = print.status == 0 ? print.stdout : ""
            return (info, text)
        }
        plistInfo[path] = result.0
        serviceDump[path] = result.1
        let statuses = await engine { PerformanceShell.launchctlList() }
        launchStatus = statuses
    }

    /// Unloads the job from launchd without deleting the plist.
    func disable(_ item: StartupItem) async -> ProcessResult {
        let target = domainTarget(item)
        let path = item.path
        let result: ProcessResult
        if target == "system" {
            result = await engine { PerformanceShell.runAdmin("/bin/launchctl bootout system \(PerformanceShell.shellQuote(path))", timeout: 120) }
        } else {
            result = await engine { ProcessRunner.run("/bin/launchctl", ["bootout", target, path], timeout: 30) }
        }
        record(item.label, action: "Disabled", result: result)
        await loadPlist(path: path)
        return result
    }

    func enable(_ item: StartupItem) async -> ProcessResult {
        let target = domainTarget(item)
        let path = item.path
        let result: ProcessResult
        if target == "system" {
            result = await engine { PerformanceShell.runAdmin("/bin/launchctl bootstrap system \(PerformanceShell.shellQuote(path))", timeout: 120) }
        } else {
            result = await engine { ProcessRunner.run("/bin/launchctl", ["bootstrap", target, path], timeout: 30) }
        }
        record(item.label, action: "Enabled", result: result)
        await loadPlist(path: path)
        return result
    }

    private func record(_ label: String, action: String, result: ProcessResult) {
        let ok = result.status == 0
        ActivityLog.shared.add(ActivityEntry(module: "Performance", title: "\(action) \(label)", items: ok ? 1 : 0, bytes: 0, failures: ok ? 0 : 1,
                                             detail: (result.stdout + result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)))
        ToastCenter.shared.show(ok ? "\(action) \(label)" : "\(action) failed: \((result.stderr + result.stdout).trimmingCharacters(in: .whitespacesAndNewlines))", error: !ok)
    }

    /// Mirrors `maclean performance --remove`: user-domain plists go through the
    /// engine's ArtifactCleaner (Trash); system ones are moved to the Trash as root.
    func remove(_ items: [StartupItem]) async -> RemovalSummary {
        busy = true
        defer { busy = false }
        let uidValue = uid
        let userItems = items.filter(isUserDomain)
        let systemItems = items.filter { !isUserDomain($0) }
        var summary = RemovalSummary()

        if !userItems.isEmpty {
            let paths = userItems.map(\.path)
            let gui = "gui/\(uidValue)"
            let artifacts = await engine { () -> [Artifact] in
                paths.compactMap { path in
                    _ = ProcessRunner.run("/bin/launchctl", ["bootout", gui, path], timeout: 15)
                    let url = URL(fileURLWithPath: path).standardizedFileURL
                    return ArtifactBuilder.make(path: url.path, allowedRoot: url.deletingLastPathComponent().path,
                                                group: "Startup item", detail: url.lastPathComponent, risk: .caution, autoselect: true)
                }
            }
            let missing = paths.filter { p in !artifacts.contains { $0.path == PathCanon.resolve(p) } }
            let partial = await EngineActions.cleanArtifacts(artifacts)
            summary.removed += partial.removed
            summary.bytes += partial.bytes
            summary.failures += partial.failures
            summary.failures += missing.map { ($0, "not found or not a regular file") }
        }

        if !systemItems.isEmpty {
            let trash = home + "/.Trash"
            let stamp = Int(Date().timeIntervalSince1970)
            let commands = systemItems.map { item -> String in
                let q = PerformanceShell.shellQuote(item.path)
                let dest = PerformanceShell.shellQuote("\(trash)/\(stamp)-\(URL(fileURLWithPath: item.path).lastPathComponent)")
                return "/bin/launchctl bootout system \(q) 2>/dev/null; /bin/mv -n \(q) \(dest)"
            }
            let sizes = systemItems.reduce(Int64(0)) { total, item in
                total + ((try? FileManager.default.attributesOfItem(atPath: item.path)[.size] as? NSNumber)?.int64Value ?? 0)
            }
            let script = commands.joined(separator: " && ")
            let result = await engine { PerformanceShell.runAdmin(script, timeout: 300) }
            let still = systemItems.filter { FileManager.default.fileExists(atPath: $0.path) }
            summary.removed += systemItems.count - still.count
            if still.isEmpty { summary.bytes += sizes }
            let reason = (result.stdout + result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            summary.failures += still.map { ($0.path, reason.isEmpty ? "administrator command failed (exit \(result.status))" : reason) }
        }

        lastFailures = summary.failures
        ActivityLog.shared.record("Performance", "Remove startup items", summary,
                                  detail: items.map(\.label).joined(separator: ", "))
        await loadStartup()
        return summary
    }

    // MARK: Login items

    func loadLoginIfNeeded() {
        if loginState == .idle { Task { await loadLoginItems() } }
    }

    func loadLoginItems() async {
        loginState = .loading("Asking System Events for login items…")
        let result = await engine { PerformanceShell.loginItems() }
        loginItems = result.items
        if let error = result.error, !error.isEmpty {
            loginState = .failed(error)
        } else {
            loginState = .loaded(Date())
        }
    }

    func removeLoginItems(_ items: [PerformanceLoginItem]) async {
        busy = true
        defer { busy = false }
        var summary = RemovalSummary()
        for item in items {
            let script = "tell application \"System Events\" to delete login item \(PerformanceShell.appleScriptQuote(item.name))"
            let result = await engine { PerformanceShell.runAppleScript(script) }
            if result.status == 0 {
                summary.removed += 1
            } else {
                summary.failures.append((item.name, result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }
        lastFailures = summary.failures
        ActivityLog.shared.record("Performance", "Remove login items", summary, detail: items.map(\.name).joined(separator: ", "))
        await loadLoginItems()
    }

    // MARK: Snapshots

    func loadSnapshotsIfNeeded() {
        if snapshotState == .idle { Task { await loadSnapshots() } }
    }

    func loadSnapshots() async {
        snapshotState = .loading("Listing local Time Machine snapshots…")
        let names = await engine { PerformanceScanner.localSnapshots() }
        snapshots = names.map(PerformanceShell.snapshot(from:)).sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        snapshotState = .loaded(Date())
    }

    func deleteSnapshots(_ list: [PerformanceSnapshot]) async -> ProcessResult? {
        let tokens = list.map(\.dateToken).filter(PerformanceShell.isSafeToken)
        guard !tokens.isEmpty else { return nil }
        busy = true
        defer { busy = false }
        let script = tokens.map { "/usr/bin/tmutil deletelocalsnapshots \($0)" }.joined(separator: "; ")
        let result = await engine { PerformanceShell.runAdmin(script, timeout: 900) }
        let before = Set(snapshots.map(\.dateToken))
        await loadSnapshots()
        let after = Set(snapshots.map(\.dateToken))
        var summary = RemovalSummary()
        summary.removed = tokens.filter { before.contains($0) && !after.contains($0) }.count
        let output = (result.stdout + result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        summary.failures = tokens.filter { after.contains($0) }.map { ("com.apple.TimeMachine.\($0).local", output.isEmpty ? "exit \(result.status)" : output) }
        lastFailures = summary.failures
        ActivityLog.shared.record("Performance", "Delete local snapshots", summary, detail: output)
        return result
    }

    // MARK: Memory

    func loadMemory() async {
        memoryState = .loading("Reading vm_stat…")
        let stats = await engine { PerformanceScanner.memory() }
        memoryStats = stats
        memoryState = stats == nil ? .failed("vm_stat failed") : .loaded(Date())
    }

    func freeRAM() async {
        let task = PerformanceTask.freeRAM
        guard runs[task]?.running != true else { return }
        let before = await engine { PerformanceScanner.memory()?.freeBytes ?? 0 }
        runs[task] = PerformanceTaskRun(startedAt: Date(), admin: true)
        let result = await engine { PerformanceShell.runAdmin("/usr/sbin/purge", timeout: 300) }
        try? await Task.sleep(nanoseconds: 600_000_000)
        let afterStats = await engine { PerformanceScanner.memory() }
        memoryStats = afterStats ?? memoryStats
        let after = afterStats?.freeBytes ?? 0
        let output = (result.stdout + result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        purgeResult = PerformancePurgeResult(before: before, after: after, status: result.status, output: output, date: Date())
        let summaryLine = "Free memory \(Format.bytes(before)) → \(Format.bytes(after))"
        finish(task, status: result.status, output: (output.isEmpty ? "" : output + "\n") + summaryLine)
    }

    // MARK: Energy assertions

    func loadAssertions() async {
        assertionState = .loading("Reading power assertions…")
        let result = await engine { ProcessRunner.run("/usr/bin/pmset", ["-g", "assertions"], timeout: 10) }
        assertions = result.stdout.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("pid ") }
        assertionState = result.status == 0 ? .loaded(Date()) : .failed(result.stderr)
    }

    // MARK: Processes

    func terminate(pid: Int32, name: String, force: Bool) {
        let result = kill(pid, force ? SIGKILL : SIGTERM)
        let ok = result == 0
        let reason = ok ? "" : String(cString: strerror(errno))
        ActivityLog.shared.add(ActivityEntry(module: "Performance", title: "\(force ? "Force quit" : "Quit") \(name)", items: ok ? 1 : 0, bytes: 0, failures: ok ? 0 : 1, detail: reason))
        ToastCenter.shared.show(ok ? "\(force ? "Force quit" : "Quit") \(name) (pid \(pid))" : "Could not quit \(name): \(reason)", error: !ok)
        Task { await SystemMonitor.shared.refreshProcesses() }
    }

    // MARK: Maintenance runner

    func lastRun(_ task: PerformanceTask) -> PerformanceRunRecord? {
        history.first { $0.task == task.rawValue }
    }

    func run(_ task: PerformanceTask, forceAdmin: Bool = false) {
        guard runs[task]?.running != true else { return }
        if task == .freeRAM {
            Task { await freeRAM() }
            return
        }
        var kind = task.kind
        if forceAdmin, task == .flushDNS {
            kind = .admin("/usr/bin/dscacheutil -flushcache; /usr/bin/killall -HUP mDNSResponder")
        }
        switch kind {
        case .flushDNS:
            runs[task] = PerformanceTaskRun(startedAt: Date(), admin: false)
            Task {
                let output = await engine { PerformanceScanner.flushDNS() }
                let failed = output.contains("restart exit") && !output.contains("restart exit 0")
                finish(task, status: failed ? 1 : 0, output: output)
            }
        case .admin(let command):
            runs[task] = PerformanceTaskRun(startedAt: Date(), output: "$ sudo \(command)\n", admin: true)
            Task {
                let result = await engine { PerformanceShell.runAdmin(command) }
                var text = result.stdout + result.stderr
                if result.timedOut { text += "\n(timed out)" }
                finish(task, status: result.status, output: text)
            }
        case .process(let exe, let args):
            startStreaming(task, exe: exe, args: args)
        }
    }

    func cancel(_ task: PerformanceTask) {
        processes[task]?.terminate()
    }

    func canCancel(_ task: PerformanceTask) -> Bool { processes[task] != nil }

    private func startStreaming(_ task: PerformanceTask, exe: String, args: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        runs[task] = PerformanceTaskRun(startedAt: Date(), output: "$ " + ([exe] + args).joined(separator: " ") + "\n", admin: false)
        Self.attachHandlers(process: process, pipe: pipe, task: task)
        do {
            try process.run()
            processes[task] = process
        } catch {
            finish(task, status: -1, output: error.localizedDescription)
        }
    }

    // Pipe and termination handlers run on background queues; build them
    // outside main-actor isolation so Swift 6 does not trap.
    nonisolated private static func attachHandlers(process: Process, pipe: Pipe, task: PerformanceTask) {
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor in PerformanceStore.shared.append(task, text) }
        }
        process.terminationHandler = { proc in
            let status = proc.terminationStatus
            pipe.fileHandleForReading.readabilityHandler = nil
            let rest = pipe.fileHandleForReading.readDataToEndOfFile()
            let text = String(decoding: rest, as: UTF8.self)
            Task { @MainActor in
                PerformanceStore.shared.append(task, text)
                PerformanceStore.shared.finish(task, status: status, output: nil)
            }
        }
    }

    fileprivate func append(_ task: PerformanceTask, _ text: String) {
        guard !text.isEmpty, var run = runs[task] else { return }
        run.output += text
        if run.output.count > 200_000 { run.output = String(run.output.suffix(150_000)) }
        runs[task] = run
    }

    fileprivate func finish(_ task: PerformanceTask, status: Int32, output: String?) {
        var run = runs[task] ?? PerformanceTaskRun(startedAt: Date(), admin: task.needsAdmin)
        if let output { run.output += output }
        run.finishedAt = Date()
        run.status = status
        runs[task] = run
        processes[task] = nil
        let record = PerformanceRunRecord(task: task.rawValue, date: run.startedAt, duration: run.elapsed, status: status,
                                          outputTail: String(run.output.suffix(2_000)))
        history.insert(record, at: 0)
        if history.count > 200 { history.removeLast(history.count - 200) }
        if let data = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(data, forKey: historyKey)
        }
        ActivityLog.shared.add(ActivityEntry(module: "Performance", title: task.title, items: status == 0 ? 1 : 0, bytes: 0,
                                             failures: status == 0 ? 0 : 1, detail: String(run.output.suffix(500))))
        ToastCenter.shared.show(status == 0 ? "\(task.title) finished" : "\(task.title) exited with status \(status)", error: status != 0)
        if task == .thinSnapshots { Task { await loadSnapshots() } }
    }

    func clearHistory() {
        history = []
        UserDefaults.standard.removeObject(forKey: historyKey)
    }
}
