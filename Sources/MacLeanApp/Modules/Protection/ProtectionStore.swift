import AppKit
import Foundation
import MacLeanCore
import SwiftUI

// MARK: - Models

struct ProtectionProfile: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let icon: String
    let summary: String
    let detail: String
    let needsPaths: Bool

    func configuration(paths: [String]) -> ScanConfiguration {
        let urls = paths.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        switch id {
        case "fast": return .fast()
        case "default": return .standard()
        case "smart": return .smart()
        case "protected-dirs": return .protectedWithDirectories(urls)
        case "paranoid": return .paranoid()
        default: return .protectedScan()
        }
    }

    static let all: [ProtectionProfile] = [
        ProtectionProfile(
            id: "fast", title: "Fast", icon: "hare",
            summary: "Launch items, known malware locations and quick disk checks.",
            detail: "Checks persistence (LaunchAgents/Daemons, login items), the predefined malware paths and shallow disk locations. Depth 2, DMG inspection on, no archives or packages. Takes seconds.",
            needsPaths: false
        ),
        ProtectionProfile(
            id: "default", title: "Default", icon: "shield",
            summary: "Adds browser extensions, cron jobs, profiles and running processes.",
            detail: "Everything in Fast plus Safari extensions and homepage, cron jobs, configuration profiles and running processes. DMG and PKG inspection on, depth 3.",
            needsPaths: false
        ),
        ProtectionProfile(
            id: "smart", title: "Smart", icon: "wand.and.stars",
            summary: "Default detectors tuned for routine checks.",
            detail: "Same detector set as Default, reported under the Smart mode. Recommended for regular scheduled checks.",
            needsPaths: false
        ),
        ProtectionProfile(
            id: "protected", title: "Protected", icon: "shield.lefthalf.filled",
            summary: "All detectors, archives, external drives and mail attachments.",
            detail: "Enables every detector: security issues, privileged URLs, external drives, mail attachments and Chrome extensions. Archives, DMG and PKG files are inspected up to depth 5.",
            needsPaths: false
        ),
        ProtectionProfile(
            id: "protected-dirs", title: "Protected · Folders", icon: "folder.badge.gearshape",
            summary: "Deep inspection of folders you choose.",
            detail: "Runs only the disk detector on the folders you add, with archive, DMG and PKG inspection, depth 5, and raised archive limits (ratio 1000, 30,000 files).",
            needsPaths: true
        ),
        ProtectionProfile(
            id: "paranoid", title: "Paranoid", icon: "exclamationmark.shield",
            summary: "Unlimited depth, nested archives and extended rules.",
            detail: "Protected plus unlimited enumeration depth, archive nesting up to 20, 512 MB archive limit and extended corpus rules. Slowest and most thorough.",
            needsPaths: false
        ),
    ]

    static func find(_ id: String) -> ProtectionProfile? { all.first { $0.id == id } }
}

struct ProtectionHistoryEntry: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var date: Date
    var profile: String
    var duration: TimeInterval
    var scannedFiles: Int
    var high: Int
    var medium: Int
    var low: Int
    var info: Int
    var corpusVersion: String?
    var total: Int { high + medium + low + info }
}

struct ProtectionQuarantineEntry: Identifiable, Sendable {
    let record: QuarantineRecord
    let bytes: Int64
    let present: Bool
    let originalOccupied: Bool
    var id: String { record.id.uuidString }
}

struct ProtectionRuleFile: Identifiable, Sendable, Hashable {
    let name: String
    let path: String
    let bytes: Int64
    let modified: Date?
    let rules: [String]
    var id: String { name }
}

struct ProtectionCorpusMeta: Codable, Sendable {
    let url: String
    let etag: String?
    let lastModified: String?
    let downloadedAt: Date
    let size: Int
    let sha256: String
}

struct ProtectionCorpusStatus: Sendable {
    let source: String
    let remote: Bool
    let cachePath: String?
    let cached: Bool
    let cacheBytes: Int64
    let meta: ProtectionCorpusMeta?
    let info: CorpusInfo?
    let infoError: String?

    var age: TimeInterval? { meta.map { Date().timeIntervalSince($0.downloadedAt) } }
    var isFresh: Bool { (age ?? .infinity) < CorpusFetcher.cacheLifetime }
}

struct ProtectionAdminResult: Sendable {
    let command: String
    let status: Int32
    let stdout: String
    let stderr: String
}

extension ProtectionFinding {
    var protectionID: String { "\(severity.rawValue)|\(kind)|\(path)|\(title)" }
}

enum ProtectionUI {
    static func tint(_ severity: Severity) -> Color {
        switch severity {
        case .high: return Theme.danger
        case .medium: return Theme.warning
        case .low: return Theme.info
        case .info: return Theme.muted
        }
    }

    static let severities: [Severity] = [.high, .medium, .low, .info]

    static var nativeArch: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }

    static func isRunning(_ bundleID: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleID }
    }

    @MainActor static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        ToastCenter.shared.show("Copied to clipboard")
    }

    static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static var cliPath: String { CLI.locate()?.path ?? "maclean" }

    static func summary(_ result: DeepCleanResult, bytes: Int64) -> RemovalSummary {
        var summary = RemovalSummary()
        summary.removed = result.removedCount
        summary.bytes = bytes
        summary.failures = result.failed.map { ($0.path, $0.reason) }
        return summary
    }

    /// Runs a shell command with the macOS administrator password prompt.
    static func runAdmin(_ command: String) async -> ProtectionAdminResult {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"
        let result = await engine { ProcessRunner.run("/usr/bin/osascript", ["-e", script], timeout: 1800) }
        return ProtectionAdminResult(command: command, status: result.status, stdout: result.stdout, stderr: result.stderr)
    }
}

// MARK: - Store

@MainActor
final class ProtectionStore: ObservableObject {
    static let shared = ProtectionStore()

    // Scan options
    @Published var selectedProfile = "smart"
    @Published var useCorpus = true
    @Published var corpusSource = MonitorDefaults.corpusURL
    @Published var corpusYara = true
    @Published var bundledRules = true
    @Published var folderPaths: [String] = []

    // Scan results
    @Published private(set) var report: ProtectionReport?
    @Published private(set) var reportDate: Date?
    @Published private(set) var reportProfile: String?
    @Published private(set) var scanState: LoadState = .idle
    @Published private(set) var scanStarted: Date?
    @Published private(set) var scanProfile: String?
    @Published private(set) var lastDuration: TimeInterval?
    @Published private(set) var history: [ProtectionHistoryEntry] = []
    @Published private(set) var handledFindings: Set<String> = []

    // Quarantine
    @Published private(set) var quarantine: [ProtectionQuarantineEntry] = []
    @Published private(set) var quarantineState: LoadState = .idle

    // Rules + corpus
    @Published private(set) var ruleFiles: [ProtectionRuleFile] = []
    @Published private(set) var rulesDirectory: String?
    @Published private(set) var rulesState: LoadState = .idle
    @Published private(set) var corpus: ProtectionCorpusStatus?
    @Published private(set) var corpusState: LoadState = .idle

    // Realtime
    let monitor = MonitorClient()
    @Published private(set) var fileAlerts: [MonitorAlert] = []

    // Deep scan stores
    @Published private(set) var deepState: LoadState = .idle
    @Published private(set) var deepDuration: TimeInterval?
    @Published private(set) var mail: MailTrashReport?
    @Published private(set) var mailState: LoadState = .idle
    @Published private(set) var photos: PhotosDuplicateReport?
    @Published private(set) var photosState: LoadState = .idle
    @Published var photosSimilar = false
    @Published private(set) var documents: DocumentVersionsReport?
    @Published private(set) var documentsState: LoadState = .idle
    @Published private(set) var stores: ProtectedStoreReport?
    @Published private(set) var storesState: LoadState = .idle
    @Published var busy = false

    private var supportDir: URL { MonitorDefaults.supportDirectory }
    private var historyURL: URL { supportDir.appendingPathComponent("protection-history.json") }
    private var reportURL: URL { supportDir.appendingPathComponent("protection-last-report.json") }

    init() {
        loadPersisted()
    }

    // MARK: Derived

    var findings: [ProtectionFinding] {
        (report?.findings ?? []).sorted {
            if $0.severity != $1.severity { return $0.severity > $1.severity }
            return $0.path < $1.path
        }
    }

    var openFindings: [ProtectionFinding] { findings.filter { !handledFindings.contains($0.protectionID) } }

    func finding(_ id: String) -> ProtectionFinding? { report?.findings.first { $0.protectionID == id } }

    func count(_ severity: Severity) -> Int { openFindings.filter { $0.severity == severity }.count }

    var threatCount: Int { openFindings.filter { $0.severity >= .medium }.count }

    var alerts: [MonitorAlert] {
        let live = monitor.alerts
        return (live.isEmpty ? fileAlerts : live).sorted { $0.date > $1.date }
    }

    var quarantineBytes: Int64 { quarantine.reduce(0) { $0 + $1.bytes } }

    var totalRuleCount: Int { ruleFiles.reduce(0) { $0 + $1.rules.count } }

    // MARK: Persistence

    private func loadPersisted() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: historyURL),
           let decoded = try? decoder.decode([ProtectionHistoryEntry].self, from: data) {
            history = decoded
        }
        if let data = try? Data(contentsOf: reportURL),
           let decoded = try? decoder.decode(ProtectionPersistedReport.self, from: data) {
            report = decoded.report
            reportDate = decoded.date
            reportProfile = decoded.profile
            handledFindings = Set(decoded.handled)
            scanState = .loaded(decoded.date)
        }
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        if let data = try? encoder.encode(history) { try? data.write(to: historyURL, options: .atomic) }
        if let report, let date = reportDate {
            let payload = ProtectionPersistedReport(date: date, profile: reportProfile ?? "", report: report, handled: Array(handledFindings))
            if let data = try? encoder.encode(payload) { try? data.write(to: reportURL, options: .atomic) }
        }
    }

    func clearHistory() {
        history = []
        persist()
    }

    // MARK: Protection scan

    func runScan(profileID: String) {
        guard !scanState.isLoading, let profile = ProtectionProfile.find(profileID) else { return }
        if profile.needsPaths && folderPaths.isEmpty {
            scanState = .failed("Add at least one folder for the \(profile.title) profile.")
            return
        }
        let paths = folderPaths
        var configuration = profile.configuration(paths: paths)
        let extra = paths.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        if !extra.isEmpty {
            configuration.scanOption.insert(.diskURLs)
            configuration.diskScanURLs = extra.map(\.path)
        }
        let config = configuration
        let source: String? = useCorpus && !corpusSource.trimmingCharacters(in: .whitespaces).isEmpty
            ? corpusSource.trimmingCharacters(in: .whitespaces) : nil
        let yara: Bool? = source == nil ? nil : corpusYara
        let bundled = bundledRules
        let started = Date()
        scanStarted = started
        scanProfile = profile.id
        scanState = .loading("Running \(profile.title) scan…")

        Task {
            do {
                let result = try await engine(priority: .userInitiated) { () throws -> ProtectionReport in
                    var corpus: PantherCorpus?
                    if let source {
                        let resolved = try CorpusFetcher.resolve(source)
                        corpus = try PantherCorpus(path: resolved.path, includeExtended: config.extendedRulesUsageEnabled)
                    }
                    let rules = bundled ? BundledRules.directory() : nil
                    return ProtectionScanner(configuration: config).scan(
                        extraPaths: extra,
                        yaraRules: rules,
                        corpus: corpus,
                        corpusYara: yara
                    )
                }
                let finished = Date()
                report = result
                reportDate = finished
                reportProfile = profile.id
                handledFindings = []
                lastDuration = finished.timeIntervalSince(started)
                let grouped = Dictionary(grouping: result.findings, by: \.severity)
                history.insert(ProtectionHistoryEntry(
                    date: finished,
                    profile: profile.id,
                    duration: finished.timeIntervalSince(started),
                    scannedFiles: result.scannedFiles,
                    high: grouped[.high]?.count ?? 0,
                    medium: grouped[.medium]?.count ?? 0,
                    low: grouped[.low]?.count ?? 0,
                    info: grouped[.info]?.count ?? 0,
                    corpusVersion: result.corpus?.version
                ), at: 0)
                if history.count > 200 { history.removeLast(history.count - 200) }
                scanState = .loaded(finished)
                persist()
                ToastCenter.shared.show("\(profile.title) scan: \(result.findings.count) findings in \(Format.count(result.scannedFiles)) files")
            } catch {
                scanState = .failed(error.localizedDescription)
            }
            scanStarted = nil
        }
    }

    func markHandled(_ id: String) {
        handledFindings.insert(id)
        persist()
    }

    // MARK: Quarantine

    func loadQuarantine() async {
        quarantineState = .loading("Reading quarantine…")
        let entries = await engine { () -> [ProtectionQuarantineEntry] in
            let fm = FileManager.default
            return QuarantineManager.records().map { record in
                let present = fm.fileExists(atPath: record.quarantinedPath)
                let bytes = present ? FileSizer.measure(URL(fileURLWithPath: record.quarantinedPath)).bytes : 0
                return ProtectionQuarantineEntry(
                    record: record,
                    bytes: bytes,
                    present: present,
                    originalOccupied: fm.fileExists(atPath: record.originalPath)
                )
            }
        }
        quarantine = entries
        quarantineState = .loaded(Date())
    }

    func quarantineEntry(_ id: String) -> ProtectionQuarantineEntry? { quarantine.first { $0.id == id } }

    /// Quarantines a path through QuarantineManager (validated against home and /Applications).
    func quarantinePath(_ path: String, reason: String, findingID: String? = nil) async -> String? {
        do {
            let record = try await engine { try QuarantineManager.quarantine(path: path, reason: reason) }
            var summary = RemovalSummary()
            summary.removed = 1
            ActivityLog.shared.record("Protection", "Quarantined \(URL(fileURLWithPath: path).lastPathComponent)", summary, detail: record.quarantinedPath)
            if let findingID { markHandled(findingID) }
            await loadQuarantine()
            return nil
        } catch {
            ToastCenter.shared.show("Quarantine failed: \(error.localizedDescription)", error: true)
            return error.localizedDescription
        }
    }

    func restore(_ entry: ProtectionQuarantineEntry) async -> String? {
        let record = entry.record
        let root = QuarantineManager.root.standardizedFileURL.path
        let result = await engine { () -> String? in
            let fm = FileManager.default
            let quarantined = URL(fileURLWithPath: record.quarantinedPath).standardizedFileURL
            let container = quarantined.deletingLastPathComponent()
            guard container.deletingLastPathComponent().path == root else { return "record is outside the quarantine folder" }
            guard fm.fileExists(atPath: quarantined.path) else { return "quarantined file is missing" }
            guard !fm.fileExists(atPath: record.originalPath) else { return "a file already exists at the original location" }
            let home = fm.homeDirectoryForCurrentUser.path
            guard record.originalPath.hasPrefix(home + "/") || record.originalPath.hasPrefix("/Applications/") else {
                return "original location is outside home and /Applications"
            }
            do {
                try fm.createDirectory(at: URL(fileURLWithPath: record.originalPath).deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(atPath: quarantined.path, toPath: record.originalPath)
                try? fm.removeItem(at: container)
                return nil
            } catch {
                return error.localizedDescription
            }
        }
        var summary = RemovalSummary()
        if let result {
            summary.failures = [(record.originalPath, result)]
        } else {
            summary.removed = 1
        }
        ActivityLog.shared.record("Protection", "Restored from quarantine", summary, detail: record.originalPath)
        await loadQuarantine()
        return result
    }

    func deleteQuarantined(_ entries: [ProtectionQuarantineEntry]) async -> RemovalSummary {
        let records = entries.map { ($0.record, $0.bytes) }
        let root = QuarantineManager.root.standardizedFileURL.path
        let summary = await engine { () -> RemovalSummary in
            var summary = RemovalSummary()
            let fm = FileManager.default
            for (record, bytes) in records {
                let container = URL(fileURLWithPath: record.quarantinedPath).standardizedFileURL.deletingLastPathComponent()
                guard container.deletingLastPathComponent().path == root,
                      container.lastPathComponent == record.id.uuidString else {
                    summary.failures.append((record.quarantinedPath, "outside the quarantine folder"))
                    continue
                }
                do {
                    try fm.removeItem(at: container)
                    summary.removed += 1
                    summary.bytes += bytes
                } catch {
                    summary.failures.append((record.quarantinedPath, error.localizedDescription))
                }
            }
            return summary
        }
        ActivityLog.shared.record("Protection", "Deleted quarantined items", summary)
        await loadQuarantine()
        return summary
    }

    // MARK: Rules

    func loadRules() async {
        rulesState = .loading("Reading bundled YARA rules…")
        let (dir, files) = await engine { () -> (String?, [ProtectionRuleFile]) in
            guard let directory = BundledRules.directory() else { return (nil, []) }
            let regex = try? NSRegularExpression(pattern: #"(?m)^\s*(?:(?:private|global)\s+)*rule\s+([A-Za-z0-9_]+)"#)
            let files = YaraScanner.ruleFiles(at: directory).map { url -> ProtectionRuleFile in
                let text = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .isoLatin1)) ?? ""
                let range = NSRange(text.startIndex..., in: text)
                let names = regex?.matches(in: text, range: range).compactMap { match -> String? in
                    guard let r = Range(match.range(at: 1), in: text) else { return nil }
                    return String(text[r])
                } ?? []
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                return ProtectionRuleFile(
                    name: url.lastPathComponent,
                    path: url.path,
                    bytes: Int64(values?.fileSize ?? 0),
                    modified: values?.contentModificationDate,
                    rules: names
                )
            }
            return (directory.path, files)
        }
        rulesDirectory = dir
        ruleFiles = files
        rulesState = dir == nil ? .failed("Bundled rules were not found in the app bundle.") : .loaded(Date())
    }

    // MARK: Corpus

    func loadCorpus(refresh: Bool = false) async {
        let source = corpusSource.trimmingCharacters(in: .whitespaces)
        corpusState = .loading(refresh ? "Downloading corpus…" : "Reading corpus cache…")
        let status = await engine { () -> (ProtectionCorpusStatus, String?) in
            let fm = FileManager.default
            let remote = CorpusFetcher.isRemote(source)
            var fetchError: String?
            if refresh {
                do { _ = try CorpusFetcher.resolve(source, refresh: true) } catch { fetchError = error.localizedDescription }
            }
            let cacheURL = remote ? CorpusFetcher.cacheLocation(for: source) : URL(fileURLWithPath: (source as NSString).expandingTildeInPath)
            var meta: ProtectionCorpusMeta?
            if remote, let cacheURL {
                let metaURL = cacheURL.deletingPathExtension().appendingPathExtension("json")
                if let data = try? Data(contentsOf: metaURL) {
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    meta = try? decoder.decode(ProtectionCorpusMeta.self, from: data)
                }
            }
            let cached = cacheURL.map { fm.fileExists(atPath: $0.path) } ?? false
            var bytes: Int64 = 0
            var info: CorpusInfo?
            var infoError: String?
            if let cacheURL, cached {
                bytes = (try? fm.attributesOfItem(atPath: cacheURL.path)[.size] as? NSNumber)?.int64Value ?? 0
                do { info = try PantherCorpus(path: cacheURL.path).info } catch { infoError = error.localizedDescription }
            }
            return (ProtectionCorpusStatus(
                source: source, remote: remote, cachePath: cacheURL?.path, cached: cached,
                cacheBytes: bytes, meta: meta, info: info, infoError: infoError
            ), fetchError)
        }
        corpus = status.0
        if let error = status.1 {
            corpusState = .failed(error)
        } else {
            corpusState = .loaded(Date())
            if refresh { ToastCenter.shared.show("Corpus refreshed") }
        }
    }

    // MARK: Realtime

    func refreshRealtime() async {
        monitor.refresh()
        let url = MonitorDefaults.alertsURL
        fileAlerts = await engine { () -> [MonitorAlert] in
            guard let data = try? Data(contentsOf: url) else { return [] }
            return (try? JSONDecoder().decode([MonitorAlert].self, from: data)) ?? []
        }
    }

    func alert(_ id: String) -> MonitorAlert? { alerts.first { $0.id.uuidString == id } }

    // MARK: Deep scan

    func runDeepScan() async {
        guard !deepState.isLoading else { return }
        let started = Date()
        deepState = .loading("Scanning Mail, Photos, document versions and protected stores…")
        mailState = .loading("Scanning…"); photosState = .loading("Scanning…")
        documentsState = .loading("Scanning…"); storesState = .loading("Scanning…")
        let similar = photosSimilar
        let report = await engine(priority: .userInitiated) {
            DeepScanner.scan(includePermissions: false, includeSimilarPhotos: similar)
        }
        let now = Date()
        mail = report.mailTrash; mailState = .loaded(now)
        photos = report.photos; photosState = .loaded(now)
        documents = report.documentVersions; documentsState = .loaded(now)
        stores = report.protectedStores; storesState = .loaded(now)
        deepDuration = now.timeIntervalSince(started)
        deepState = .loaded(now)
    }

    func scanMail() async {
        mailState = .loading("Scanning Mail trash…")
        mail = await engine { MailTrashScanner.scan() }
        mailState = .loaded(Date())
    }

    func scanPhotos() async {
        photosState = .loading("Hashing Photos originals…")
        let similar = photosSimilar
        photos = await engine { PhotosDuplicateScanner.scan(includeSimilar: similar) }
        photosState = .loaded(Date())
    }

    func scanDocuments() async {
        documentsState = .loading("Reading document versions…")
        documents = await engine { DocumentVersionsScanner.scan() }
        documentsState = .loaded(Date())
    }

    func scanStores() async {
        storesState = .loading("Measuring protected stores and universal binaries…")
        stores = await engine { ProtectedStoreScanner.scan() }
        storesState = .loaded(Date())
    }

    // MARK: Deep cleaning

    func cleanMail(_ selected: [MailTrashMailbox]) async -> RemovalSummary {
        if ProtectionUI.isRunning("com.apple.mail") {
            var summary = RemovalSummary()
            summary.failures = [("Mail", "Quit Mail before cleaning Mail Trash.")]
            ToastCenter.shared.show("Quit Mail before cleaning Mail Trash", error: true)
            return summary
        }
        busy = true
        defer { busy = false }
        let before = selected.reduce(Int64(0)) { $0 + $1.bytes }
        let report = MailTrashReport(mailboxes: selected, totalBytes: before, error: nil)
        let result = await engine { DeepCleaner.cleanMailTrash(report: report, apply: true, permanent: false) }
        await scanMail()
        let paths = Set(selected.map(\.path))
        let after = (mail?.mailboxes ?? []).filter { paths.contains($0.path) }.reduce(Int64(0)) { $0 + $1.bytes }
        let summary = ProtectionUI.summary(result, bytes: max(0, before - after))
        ActivityLog.shared.record("Protection", "Mail Trash", summary, detail: "\(selected.count) mailboxes")
        return summary
    }

    func cleanPhotos(_ groups: [DuplicateGroup]) async -> RemovalSummary {
        if ProtectionUI.isRunning("com.apple.Photos") {
            var summary = RemovalSummary()
            summary.failures = [("Photos", "Quit Photos before removing duplicate originals.")]
            ToastCenter.shared.show("Quit Photos before removing duplicates", error: true)
            return summary
        }
        busy = true
        defer { busy = false }
        let report = PhotosDuplicateReport(
            libraries: photos?.libraries ?? [],
            exactGroups: groups,
            similarGroups: [],
            wastedBytes: 0,
            similarBytes: 0,
            error: nil
        )
        let sizes = Dictionary(groups.flatMap { g in g.paths.map { (PathCanon.resolve($0), g.size) } }, uniquingKeysWith: { a, _ in a })
        let result = await engine { DeepCleaner.cleanPhotosDuplicates(report: report, apply: true, permanent: false) }
        let bytes = (result.movedToTrash + result.deleted).reduce(Int64(0)) { $0 + (sizes[$1] ?? 0) }
        let summary = ProtectionUI.summary(result, bytes: bytes)
        ActivityLog.shared.record("Protection", "Photos duplicates", summary, detail: "\(groups.count) groups")
        await scanPhotos()
        return summary
    }

    func cleanDocuments(_ files: [DocumentVersionFile]) async -> RemovalSummary {
        busy = true
        defer { busy = false }
        let report = DocumentVersionsReport(
            files: files,
            totalBytes: files.reduce(0) { $0 + $1.bytes },
            selectedBytes: 0,
            error: nil
        )
        let sizes = Dictionary(files.flatMap { $0.versions.map { ($0.versionPath, $0.bytes) } }, uniquingKeysWith: { a, _ in a })
        let result = await engine { DocumentVersionCleaner.clean(report: report, apply: true) }
        let bytes = result.deleted.reduce(Int64(0)) { $0 + (sizes[$1] ?? 0) }
        let summary = ProtectionUI.summary(result, bytes: bytes)
        ActivityLog.shared.record("Protection", "Document versions", summary, detail: "\(files.count) documents")
        await scanDocuments()
        return summary
    }

    func adminCommand(kind: String) -> String {
        "\(ProtectionUI.shellQuote(ProtectionUI.cliPath)) system --apply --yes --permanent --include \(kind) --json"
    }

    /// Runs the CLI as root through the administrator prompt.
    func cleanProtectedStore(kind: String, items: [ProtectedStoreItem]) async -> (RemovalSummary, ProtectionAdminResult) {
        busy = true
        defer { busy = false }
        let before = items.reduce(Int64(0)) { $0 + $1.bytes }
        let output = await ProtectionUI.runAdmin(adminCommand(kind: kind))
        var summary = RemovalSummary()
        if output.status == 0 || !output.stdout.isEmpty,
           let data = output.stdout.data(using: .utf8),
           let result = try? JSONDecoder().decode(DeepCleanResult.self, from: data) {
            await scanStores()
            let remaining = Set((kind == "deleted-user" ? stores?.deletedUsers : stores?.systemCaches)?.map(\.path) ?? [])
            let after = items.filter { remaining.contains($0.path) }.reduce(Int64(0)) { $0 + $1.bytes }
            summary = ProtectionUI.summary(result, bytes: max(0, before - after))
        } else {
            let reason = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            summary.failures = [("system", reason.isEmpty ? "exit status \(output.status)" : reason)]
        }
        ActivityLog.shared.record("Protection", kind == "deleted-user" ? "Deleted user installers" : "System caches & logs", summary)
        return (summary, output)
    }

    func thin(_ items: [UniversalBinaryItem]) async -> (RemovalSummary, UniversalThinResult) {
        busy = true
        defer { busy = false }
        let arch = ProtectionUI.nativeArch
        let report = ProtectedStoreReport(
            isRoot: false, deletedUsers: [], documentVersions: [], systemCaches: [],
            universalBinaries: items, errors: []
        )
        let result = await engine { UniversalThinner.thin(report: report, architecture: arch, apply: true, resign: true) }
        let thinned = Set(result.thinned)
        let bytes = items.filter { thinned.contains(PathCanon.resolve($0.path)) }.reduce(Int64(0)) { $0 + $1.estimatedSavings }
        var summary = RemovalSummary()
        summary.removed = result.thinned.count
        summary.bytes = bytes
        summary.failures = result.failed.map { ($0.path, $0.reason) }
        ActivityLog.shared.record("Protection", "Universal binaries thinned to \(arch)", summary, detail: result.backups.joined(separator: "\n"))
        await scanStores()
        return (summary, result)
    }
}

private struct ProtectionPersistedReport: Codable {
    let date: Date
    let profile: String
    let report: ProtectionReport
    let handled: [String]
}
