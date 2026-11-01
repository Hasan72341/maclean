import AppKit
import Foundation
import MacLeanCore
import SwiftUI

enum SettingsAppearance: String, CaseIterable, Hashable, Sendable {
    case system
    case light
    case dark

    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var icon: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }
}

struct SettingsAccessProbe: Sendable, Identifiable, Hashable {
    var id: String { path }
    let label: String
    let path: String
    let exists: Bool
    let readable: Bool
    let detail: String
}

struct SettingsEngineInfo: Sendable {
    var cliPath: String?
    var cliVersion: String = ""
    var cliStatus: Int32?
    var cliStderr: String = ""
    var rulesCount: Int = 0
    var safeRules: Int = 0
    var cautionRules: Int = 0
    var rootRules: Int = 0
    var scanOnlyRules: Int = 0
    var rulesByCategory: [(String, Int)] = []
    var yaraDirectory: String?
    var yaraRuleFiles: [String] = []
    var yaraRuleBytes: Int64 = 0
    var corpusURL: String = MonitorDefaults.corpusURL
    var resourcesDirectory: String?
    var bundledBinaries: [(String, Int64)] = []
}

struct SettingsFileEntry: Sendable, Identifiable, Hashable {
    var id: String { path }
    let name: String
    let path: String
    let bytes: Int64
    let files: Int
    let isDirectory: Bool
    let modified: Date?
}

struct SettingsLicenseFile: Sendable, Identifiable, Hashable {
    var id: String { name }
    let name: String
    let path: String
    let bytes: Int64
    let text: String
    let summary: String
}

struct SettingsCLILink: Sendable {
    var exists: Bool = false
    var isSymlink: Bool = false
    var destination: String?
    var pointsToBundled: Bool = false
}

@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    static let appearanceKey = "maclean.appearance"
    static let permanentKey = "maclean.permanentDelete"
    static let intervalKey = "maclean.monitorInterval"
    static let linkPath = "/usr/local/bin/maclean"

    @Published var appearance: SettingsAppearance = .system
    @Published var permanentDelete: Bool = false
    @Published var monitorPaused = false
    @Published private(set) var trashBytes: Int64?

    @Published private(set) var engineInfo = SettingsEngineInfo()
    @Published private(set) var engineState: LoadState = .idle

    @Published private(set) var accessProbes: [SettingsAccessProbe] = []
    @Published private(set) var accessState: LoadState = .idle

    @Published private(set) var appDataEntries: [SettingsFileEntry] = []
    @Published private(set) var appDataState: LoadState = .idle

    @Published private(set) var licenses: [SettingsLicenseFile] = []
    @Published private(set) var licenseState: LoadState = .idle

    @Published private(set) var cliLink = SettingsCLILink()
    @Published var cliInstallOutput: String = ""
    @Published var cliInstallBusy = false

    @Published var lastFailures: [(path: String, reason: String)] = []
    @Published var removalBusy = false

    init() {
        let defaults = UserDefaults.standard
        appearance = SettingsAppearance(rawValue: defaults.string(forKey: Self.appearanceKey) ?? "") ?? .system
        permanentDelete = defaults.bool(forKey: Self.permanentKey)
        let interval = defaults.double(forKey: Self.intervalKey)
        if interval > 0 { SystemMonitor.shared.intervalSeconds = interval }
    }

    static var appSupport: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MacLean", isDirectory: true)
    }

    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String
        switch (short, build) {
        case let (s?, b?): return "\(s) (\(b))"
        case let (s?, nil): return s
        default: return "0.2.0 (development build)"
        }
    }

    // MARK: General

    func setAppearance(_ value: SettingsAppearance) {
        appearance = value
        UserDefaults.standard.set(value.rawValue, forKey: Self.appearanceKey)
        applyAppearance()
    }

    func applyAppearance() {
        switch appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    func setPermanentDelete(_ value: Bool) {
        permanentDelete = value
        UserDefaults.standard.set(value, forKey: Self.permanentKey)
    }

    func loadTrashSize() async {
        let trash = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
        trashBytes = await engine { FileSizer.measure(trash).bytes }
    }

    // MARK: Monitoring

    func setInterval(_ seconds: Double) {
        SystemMonitor.shared.intervalSeconds = seconds
        UserDefaults.standard.set(seconds, forKey: Self.intervalKey)
    }

    func toggleMonitor() {
        if monitorPaused {
            SystemMonitor.shared.start()
            monitorPaused = false
        } else {
            SystemMonitor.shared.stop()
            monitorPaused = true
        }
    }

    // MARK: Engine

    func loadEngineIfNeeded() {
        if engineState == .idle { Task { await loadEngine() } }
    }

    func loadEngine() async {
        engineState = .loading("Inspecting engine…")
        var info = await engine { () -> SettingsEngineInfo in
            var info = SettingsEngineInfo()
            info.cliPath = CLI.locate()?.path
            let rules = Rules.all
            info.rulesCount = rules.count
            info.safeRules = rules.filter { $0.risk == .safe }.count
            info.cautionRules = rules.filter { $0.risk == .caution }.count
            info.rootRules = rules.filter { $0.requiresRoot }.count
            info.scanOnlyRules = rules.filter { $0.scanOnly }.count
            var byCategory: [String: Int] = [:]
            for rule in rules { byCategory[rule.category.title, default: 0] += 1 }
            info.rulesByCategory = byCategory.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
            if let dir = BundledRules.directory() {
                info.yaraDirectory = dir.path
                let files = YaraScanner.ruleFiles(at: dir)
                info.yaraRuleFiles = files.map(\.path).sorted()
                info.yaraRuleBytes = files.reduce(Int64(0)) { $0 + FileSizer.measure($1).bytes }
                let resources = dir.deletingLastPathComponent().deletingLastPathComponent()
                info.resourcesDirectory = resources.path
                let bin = resources.appendingPathComponent("bin")
                let names = (try? FileManager.default.contentsOfDirectory(atPath: bin.path)) ?? []
                info.bundledBinaries = names.sorted().map { name in
                    (name, FileSizer.measure(bin.appendingPathComponent(name)).bytes)
                }
            }
            return info
        }
        do {
            let output = try await CLI.run(["version"], timeout: 15)
            info.cliVersion = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            info.cliStatus = output.status
            info.cliStderr = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            info.cliVersion = ""
            info.cliStderr = error.localizedDescription
        }
        engineInfo = info
        refreshCLILink()
        engineState = .loaded(Date())
    }

    // MARK: CLI install

    func refreshCLILink() {
        let fm = FileManager.default
        var link = SettingsCLILink()
        let path = Self.linkPath
        if let attrs = try? fm.attributesOfItem(atPath: path) {
            link.exists = true
            link.isSymlink = (attrs[.type] as? FileAttributeType) == .typeSymbolicLink
            if link.isSymlink {
                link.destination = try? fm.destinationOfSymbolicLink(atPath: path)
            }
        }
        if let dest = link.destination, let cli = engineInfo.cliPath {
            link.pointsToBundled = PathCanon.resolve(dest) == PathCanon.resolve(cli)
        }
        cliLink = link
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    func installCommand() -> String? {
        guard let cli = engineInfo.cliPath else { return nil }
        return "sudo mkdir -p /usr/local/bin && sudo ln -sf \(Self.shellQuote(cli)) \(Self.linkPath)"
    }

    func runPrivileged(_ shell: String, title: String) async {
        cliInstallBusy = true
        cliInstallOutput = "Waiting for administrator authorization…"
        let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"
        let result = await engine { ProcessRunner.run("/usr/bin/osascript", ["-e", script], timeout: 180) }
        var lines = ["$ \(shell)", "exit status \(result.status)\(result.timedOut ? " (timed out)" : "")"]
        if !result.stdout.isEmpty { lines.append(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) }
        if !result.stderr.isEmpty { lines.append(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }
        cliInstallOutput = lines.joined(separator: "\n")
        cliInstallBusy = false
        refreshCLILink()
        ToastCenter.shared.show(result.status == 0 ? "\(title) succeeded" : "\(title) failed (status \(result.status))", error: result.status != 0)
    }

    func installCLI() async {
        guard let cli = engineInfo.cliPath else { return }
        await runPrivileged("mkdir -p /usr/local/bin && ln -sf \(Self.shellQuote(cli)) \(Self.linkPath)", title: "Install CLI link")
    }

    func uninstallCLI() async {
        guard cliLink.isSymlink else { return }
        await runPrivileged("rm \(Self.linkPath)", title: "Remove CLI link")
    }

    // MARK: Full Disk Access

    func loadAccessIfNeeded() {
        if accessState == .idle { Task { await checkAccess() } }
    }

    func checkAccess() async {
        accessState = .loading("Probing protected locations…")
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        accessProbes = await engine { Self.probeAll(home: home) }
        accessState = .loaded(Date())
    }

    nonisolated static func probeAll(home: String) -> [SettingsAccessProbe] {
        let targets: [(String, String, Bool)] = [
            ("TCC database", home + "/Library/Application Support/com.apple.TCC/TCC.db", true),
            ("Mail", home + "/Library/Mail", false),
            ("Safari", home + "/Library/Safari", false),
            ("Messages", home + "/Library/Messages", false),
            ("Cookies", home + "/Library/Cookies", false),
            ("Home Library Containers", home + "/Library/Containers/com.apple.Safari", false),
        ]
        return targets.map { probe(label: $0.0, path: $0.1, isFile: $0.2) }
    }

    nonisolated static func probe(label: String, path: String, isFile: Bool) -> SettingsAccessProbe {
        let fm = FileManager.default
        let exists = fm.fileExists(atPath: path)
        guard exists else {
            return SettingsAccessProbe(label: label, path: path, exists: false, readable: false, detail: "Not present on this Mac")
        }
        if isFile {
            do {
                let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
                let data = try handle.read(upToCount: 16) ?? Data()
                try? handle.close()
                return SettingsAccessProbe(label: label, path: path, exists: true, readable: true, detail: "Read \(data.count) bytes")
            } catch {
                return SettingsAccessProbe(label: label, path: path, exists: true, readable: false, detail: error.localizedDescription)
            }
        }
        do {
            let items = try fm.contentsOfDirectory(atPath: path)
            return SettingsAccessProbe(label: label, path: path, exists: true, readable: true, detail: "\(items.count) entries listed")
        } catch {
            return SettingsAccessProbe(label: label, path: path, exists: true, readable: false, detail: error.localizedDescription)
        }
    }

    var fullDiskAccessGranted: Bool? {
        guard accessState.loadedAt != nil else { return nil }
        if let tcc = accessProbes.first(where: { $0.label == "TCC database" }), tcc.exists { return tcc.readable }
        let present = accessProbes.filter(\.exists)
        guard !present.isEmpty else { return nil }
        return present.allSatisfy(\.readable)
    }

    // MARK: App data

    func loadAppDataIfNeeded() {
        if appDataState == .idle { Task { await loadAppData() } }
    }

    func loadAppData() async {
        appDataState = .loading("Measuring app data…")
        let root = Self.appSupport
        appDataEntries = await engine { () -> [SettingsFileEntry] in
            let fm = FileManager.default
            let names = (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
            return names.map { name in
                let url = root.appendingPathComponent(name)
                let info = FileSizer.measure(url)
                return SettingsFileEntry(name: name, path: url.path, bytes: info.bytes, files: info.files, isDirectory: info.isDirectory, modified: info.modified)
            }.sorted { $0.bytes > $1.bytes }
        }
        appDataState = .loaded(Date())
    }

    func trashAppData(_ paths: [String]) async {
        removalBusy = true
        var sizes: [String: Int64] = [:]
        for entry in appDataEntries where paths.contains(entry.path) { sizes[entry.path] = entry.bytes }
        let summary = await EngineActions.trashFiles(paths, bytes: sizes)
        ActivityLog.shared.record("Settings", "Removed app data", summary, detail: paths.map(Format.abbreviated).joined(separator: "\n"))
        lastFailures = summary.failures
        removalBusy = false
        await loadAppData()
    }

    func clearHistory() {
        let count = ActivityLog.shared.entries.count
        ActivityLog.shared.clear()
        ToastCenter.shared.show("Cleared \(Format.count(count)) history entries")
        Task { await loadAppData() }
    }

    // MARK: Licenses

    func loadLicensesIfNeeded() {
        if licenseState == .idle { Task { await loadLicenses() } }
    }

    func loadLicenses() async {
        licenseState = .loading("Locating license files…")
        licenses = await engine { Self.findLicenses() }
        licenseState = .loaded(Date())
    }

    nonisolated static func findLicenses() -> [SettingsLicenseFile] {
        var candidates: [(String, URL)] = []
        if let dir = BundledRules.directory() {
            let resources = dir.deletingLastPathComponent().deletingLastPathComponent()
            candidates.append(("YARA-COPYING", resources.appendingPathComponent("YARA-COPYING")))
            candidates.append(("OPENSSL-COPYING", resources.appendingPathComponent("OPENSSL-COPYING")))
            candidates.append(("YARA-BUILD.txt", resources.appendingPathComponent("YARA-BUILD.txt")))
            candidates.append(("signature-base ATTRIBUTION.md", dir.appendingPathComponent("ATTRIBUTION.md")))
            candidates.append(("signature-base LICENSE", dir.appendingPathComponent("LICENSE")))
        }
        let fm = FileManager.default
        return candidates.compactMap { name, url in
            guard fm.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url) else { return nil }
            let text = String(decoding: data, as: UTF8.self)
            let summary = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty && !$0.allSatisfy { "#=-*".contains($0) } } ?? ""
            return SettingsLicenseFile(name: name, path: url.path, bytes: Int64(data.count), text: text, summary: String(summary.prefix(120)))
        }
    }

    // MARK: Diagnostics

    func diagnosticsText() -> String {
        let snapshot = SystemMonitor.shared.latest
        let process = ProcessInfo.processInfo
        let info = engineInfo
        let log = ActivityLog.shared
        var lines: [String] = []
        lines.append("MacLean diagnostics — \(Date().formatted(.iso8601))")
        lines.append("")
        lines.append("[App]")
        lines.append("Version: \(Self.appVersion)")
        lines.append("Bundle: \(Bundle.main.bundlePath)")
        lines.append("Executable: \(Bundle.main.executablePath ?? "—")")
        lines.append("PID: \(process.processIdentifier)")
        lines.append("Appearance: \(appearance.title)")
        lines.append("Removal mode: \(permanentDelete ? "Delete permanently" : "Move to Trash")")
        lines.append("Monitor interval: \(SystemMonitor.shared.intervalSeconds)s\(monitorPaused ? " (paused)" : "")")
        lines.append("")
        lines.append("[System]")
        lines.append("macOS: \(process.operatingSystemVersionString)")
        lines.append("Model: \(Self.sysctlString("hw.model") ?? "—")")
        lines.append("CPU: \(Self.sysctlString("machdep.cpu.brand_string") ?? "—")")
        lines.append("Cores: \(process.processorCount) (\(process.activeProcessorCount) active)")
        lines.append("Memory: \(Format.bytes(Int64(process.physicalMemory)))")
        lines.append("Uptime: \(Format.duration(process.systemUptime))")
        lines.append("Thermal: \(snapshot.thermalTitle)")
        lines.append("CPU load: \(Format.percent(snapshot.cpu.total, digits: 1))")
        lines.append("Memory used: \(Format.bytes(snapshot.memory.used)) of \(Format.bytes(snapshot.memory.total)) (\(snapshot.memory.pressureTitle))")
        lines.append("Swap: \(Format.bytes(snapshot.memory.swapUsed)) of \(Format.bytes(snapshot.memory.swapTotal))")
        lines.append("Disk: \(Format.bytes(snapshot.disk.used)) used, \(Format.bytes(snapshot.disk.available)) free of \(Format.bytes(snapshot.disk.total))")
        lines.append("Load average: \(snapshot.loadAverage.map { String(format: "%.2f", $0) }.joined(separator: " "))")
        lines.append("Processes: \(snapshot.processCount)")
        lines.append("Health score: \(snapshot.healthScore)")
        if let battery = snapshot.battery {
            lines.append("Battery: \(battery.percent)%\(battery.isCharging ? " charging" : "")\(battery.cycleCount.map { ", \($0) cycles" } ?? "")")
        }
        lines.append("")
        lines.append("[Engine]")
        lines.append("CLI: \(info.cliPath ?? "not found")")
        lines.append("CLI version: \(info.cliVersion.isEmpty ? "—" : info.cliVersion)")
        lines.append("CLI link: \(cliLink.exists ? (cliLink.destination ?? Self.linkPath) : "not installed")")
        lines.append("Cleanup rules: \(info.rulesCount) (\(info.safeRules) safe, \(info.cautionRules) caution, \(info.rootRules) need root)")
        lines.append("YARA rule files: \(info.yaraRuleFiles.count)")
        lines.append("YARA directory: \(info.yaraDirectory ?? "not found")")
        lines.append("Corpus URL: \(info.corpusURL)")
        lines.append("Full Disk Access: \(fullDiskAccessGranted.map { $0 ? "granted" : "not granted" } ?? "unknown")")
        lines.append("")
        lines.append("[Activity]")
        lines.append("History entries: \(log.entries.count)")
        lines.append("Total freed: \(Format.bytes(log.totalFreed))")
        lines.append("Items cleaned: \(log.entries.reduce(0) { $0 + $1.items })")
        lines.append("Failures: \(log.entries.reduce(0) { $0 + $1.failures })")
        return lines.joined(separator: "\n")
    }

    nonisolated static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    // MARK: Files

    static func save(text: String, suggestedName: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            ToastCenter.shared.show("Saved \(url.lastPathComponent)")
        } catch {
            ToastCenter.shared.show("Save failed: \(error.localizedDescription)", error: true)
        }
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        ToastCenter.shared.show("Copied to clipboard")
    }

    static func historyJSON(_ entries: [ActivityEntry]) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(entries) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Activity statistics helpers

struct SettingsModuleStat: Identifiable, Hashable {
    var id: String { module }
    let module: String
    var bytes: Int64 = 0
    var items: Int = 0
    var failures: Int = 0
    var runs: Int = 0
}

enum SettingsStats {
    static func byModule(_ entries: [ActivityEntry]) -> [SettingsModuleStat] {
        var map: [String: SettingsModuleStat] = [:]
        for entry in entries {
            var stat = map[entry.module] ?? SettingsModuleStat(module: entry.module)
            stat.bytes += entry.bytes
            stat.items += entry.items
            stat.failures += entry.failures
            stat.runs += 1
            map[entry.module] = stat
        }
        return map.values.sorted { $0.bytes == $1.bytes ? $0.module < $1.module : $0.bytes > $1.bytes }
    }

    static func byTitle(_ entries: [ActivityEntry]) -> [SettingsModuleStat] {
        byModule(entries.map { var e = $0; e.module = $0.title; return e })
    }

    /// Bytes freed per day for the last `days` days, oldest first.
    static func daily(_ entries: [ActivityEntry], days: Int = 30) -> [(Date, Int64, Int)] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        var buckets: [(Date, Int64, Int)] = (0..<days).reversed().compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: today).map { ($0, Int64(0), 0) }
        }
        for entry in entries {
            let day = calendar.startOfDay(for: entry.date)
            if let index = buckets.firstIndex(where: { $0.0 == day }) {
                buckets[index].1 += entry.bytes
                buckets[index].2 += 1
            }
        }
        return buckets
    }
}
