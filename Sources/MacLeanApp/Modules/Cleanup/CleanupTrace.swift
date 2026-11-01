import AppKit
import Foundation
import MacLeanCore
import SwiftUI

// MARK: - Event buffer (engine thread → main actor)

/// Collects engine scan events from the background scan and hands them to the
/// main actor in batches. Closures are built here, outside any actor, so the
/// engine can call them from its own thread.
final class ScanEventBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [ScanEvent] = []
    private var cancelled = false

    var observer: @Sendable (ScanEvent) -> Void {
        { [self] event in
            lock.lock()
            events.append(event)
            lock.unlock()
        }
    }

    var cancelCheck: @Sendable () -> Bool {
        { [self] in isCancelled }
    }

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }

    func drain() -> [ScanEvent] {
        lock.lock(); defer { lock.unlock() }
        let out = events
        events.removeAll(keepingCapacity: true)
        return out
    }
}

// MARK: - Log lines

enum ScanVerbosity: Int, CaseIterable, Identifiable {
    case summary = 0
    case detailed = 1
    case trace = 2

    var id: Int { rawValue }
    var title: String {
        switch self {
        case .summary: return "Summary"
        case .detailed: return "Detailed"
        case .trace: return "Trace"
        }
    }
    var blurb: String {
        switch self {
        case .summary: return "Rules started and finished, and every item found."
        case .detailed: return "Also folders entered, missing folders and skipped entries with the reason."
        case .trace: return "Also every path as it is measured. Produces a very long log."
        }
    }
}

enum ScanLineLevel: String, CaseIterable, Identifiable {
    case info = "Info"
    case rule = "Rule"
    case found = "Found"
    case folder = "Folder"
    case skip = "Skipped"
    case missing = "Missing"
    case measure = "Measure"
    case warn = "Warning"

    var id: String { rawValue }
    var tag: String {
        switch self {
        case .info: return "INFO"
        case .rule: return "RULE"
        case .found: return "FOUND"
        case .folder: return "DIR"
        case .skip: return "SKIP"
        case .missing: return "MISS"
        case .measure: return "SIZE"
        case .warn: return "WARN"
        }
    }
    var tint: Color {
        switch self {
        case .info: return Theme.muted
        case .rule: return Theme.info
        case .found: return Theme.success
        case .folder: return Theme.ink
        case .skip: return Theme.faint
        case .missing: return Theme.faint
        case .measure: return Theme.faint
        case .warn: return Theme.warning
        }
    }
}

struct ScanLine: Identifiable, Sendable {
    let id: Int
    let time: Double
    let level: ScanLineLevel
    let text: String
    var path: String? = nil
    var ruleID: String? = nil
    var bytes: Int64? = nil

    var plain: String {
        var line = String(format: "%8.2fs  %-5@  ", time, level.tag as NSString) + text
        if let path { line += "  " + path }
        if let bytes { line += "  (" + Format.bytes(bytes) + ")" }
        return line
    }
}

struct RuleScanStat: Identifiable, Sendable {
    let ruleID: String
    var title: String
    var category: JunkCategory?
    var roots = 0
    var rootsMissing = 0
    var examined = 0
    var skipped = 0
    var items = 0
    var files = 0
    var bytes: Int64 = 0
    var seconds: Double = 0
    var status: Status = .running
    var skipReason: String?

    enum Status: String, Sendable { case running = "Running", done = "Done", skipped = "Skipped", cancelled = "Stopped" }
    var id: String { ruleID }
}

// MARK: - Trace model

/// Verbose, live view of what the scanner is doing.
@MainActor
final class ScanTrace: ObservableObject {
    static let shared = ScanTrace()
    static let maxLines = 6_000
    private static let verbosityKey = "cleanup.verbosity.v1"

    @Published var verbosity: ScanVerbosity {
        didSet { UserDefaults.standard.set(verbosity.rawValue, forKey: Self.verbosityKey) }
    }

    @Published private(set) var lines: [ScanLine] = []
    @Published private(set) var droppedLines = 0
    @Published private(set) var started: Date?
    @Published private(set) var finished: Date?
    @Published private(set) var currentRule: String?
    @Published private(set) var currentPath: String?
    @Published private(set) var rulesTotal = 0
    @Published private(set) var rulesDone = 0
    @Published private(set) var rulesSkipped = 0
    @Published private(set) var rootsVisited = 0
    @Published private(set) var rootsMissing = 0
    @Published private(set) var examined = 0
    @Published private(set) var measured = 0
    @Published private(set) var found = 0
    @Published private(set) var foundBytes: Int64 = 0
    @Published private(set) var skipCounts: [String: Int] = [:]
    @Published private(set) var ruleStats: [String: RuleScanStat] = [:]
    @Published private(set) var rateHistory: [Double] = []
    @Published private(set) var logURL: URL?

    private var nextID = 0
    private var lastExamined = 0
    private var lastTick: Date?

    init() {
        verbosity = ScanVerbosity(rawValue: UserDefaults.standard.integer(forKey: Self.verbosityKey)) ?? .detailed
        if UserDefaults.standard.object(forKey: Self.verbosityKey) == nil { verbosity = .detailed }
    }

    var elapsed: Double {
        guard let started else { return 0 }
        return (finished ?? Date()).timeIntervalSince(started)
    }

    var skippedTotal: Int { skipCounts.values.reduce(0, +) }

    var rulesFraction: Double {
        rulesTotal == 0 ? 0 : Double(rulesDone + rulesSkipped) / Double(rulesTotal)
    }

    var sortedStats: [RuleScanStat] { ruleStats.values.sorted { $0.seconds > $1.seconds } }

    // MARK: Lifecycle

    func begin(rulesTotal: Int, categories: [JunkCategory], minBytes: Int64, threshold: Int64) {
        lines = []
        droppedLines = 0
        nextID = 0
        started = Date()
        finished = nil
        currentRule = nil
        currentPath = nil
        self.rulesTotal = rulesTotal
        rulesDone = 0
        rulesSkipped = 0
        rootsVisited = 0
        rootsMissing = 0
        examined = 0
        measured = 0
        found = 0
        foundBytes = 0
        skipCounts = [:]
        ruleStats = [:]
        rateHistory = []
        lastExamined = 0
        lastTick = Date()
        let ruleBook = RuleBook.shared.snapshot
        note("Smart Scan started · \(rulesTotal) active rules in \(categories.count) categories")
        note("Categories: " + categories.map(\.title).joined(separator: ", "))
        note("Minimum item size \(minBytes == 0 ? "none" : Format.bytes(minBytes)) · large file threshold \(Format.bytes(threshold))")
        note("Rule book: \(ruleBook.custom.count) custom rules, \(ruleBook.overrides.count) edited bundled rules · \(RuleBook.shared.url.path)")
        note("Running as \(NSUserName()) (uid \(getuid())) · \(geteuid() == 0 ? "administrator" : "standard user, administrator rules are skipped")")
        note("Verbosity: \(verbosity.title)")
    }

    func note(_ text: String, level: ScanLineLevel = .info, path: String? = nil) {
        append(level, text, path: path)
    }

    func finish(cancelled: Bool, items: Int, bytes: Int64, recommended: Int64) {
        finished = Date()
        currentRule = nil
        currentPath = nil
        for key in ruleStats.keys where ruleStats[key]?.status == .running {
            ruleStats[key]?.status = .cancelled
        }
        note(cancelled ? "Scan stopped by user" : "Scan finished", level: cancelled ? .warn : .info)
        note("\(Format.count(rulesDone)) rules ran, \(Format.count(rulesSkipped)) skipped · \(Format.count(rootsVisited)) folders read, \(Format.count(rootsMissing)) missing")
        note("\(Format.count(examined)) entries examined, \(Format.count(measured)) measured, \(Format.count(skippedTotal)) skipped")
        for (reason, count) in skipCounts.sorted(by: { $0.value > $1.value }) {
            note("  skipped \(Format.count(count)) · \(reason)")
        }
        note("Found \(Format.count(items)) items · \(Format.bytes(bytes)) · \(Format.bytes(recommended)) recommended")
        note(String(format: "Total time %.2fs", elapsed))
        let slowest = sortedStats.prefix(5)
        if !slowest.isEmpty {
            note("Slowest rules: " + slowest.map { String(format: "%@ %.2fs", $0.title, $0.seconds) }.joined(separator: " · "))
        }
        writeLog()
    }

    /// Called on every sampler tick with events drained from the engine.
    func ingest(_ events: [ScanEvent]) {
        for event in events { handle(event) }
        let now = Date()
        if let lastTick {
            let dt = max(now.timeIntervalSince(lastTick), 0.05)
            rateHistory.append(Double(examined - lastExamined) / dt)
            if rateHistory.count > SystemMonitor.historyLength { rateHistory.removeFirst(rateHistory.count - SystemMonitor.historyLength) }
        }
        lastTick = now
        lastExamined = examined
    }

    private func handle(_ event: ScanEvent) {
        let level = verbosity
        switch event {
        case .ruleStarted(let id, let title, let category, let roots):
            currentRule = title
            ruleStats[id] = RuleScanStat(ruleID: id, title: title, category: category, roots: roots)
            append(.rule, "▶ \(title) [\(id)] · \(category.title) · \(roots) folder\(roots == 1 ? "" : "s") to check", ruleID: id)
        case .ruleSkipped(let id, let title, let reason):
            rulesSkipped += 1
            var stat = RuleScanStat(ruleID: id, title: title)
            stat.status = .skipped
            stat.skipReason = reason
            ruleStats[id] = stat
            append(.warn, "⏭ \(title) [\(id)] skipped: \(reason)", ruleID: id)
        case .rootMissing(let id, let path):
            rootsMissing += 1
            ruleStats[id]?.rootsMissing += 1
            // Rules that fan out over every app container would flood the log;
            // those are summarised at the end of the rule unless tracing.
            let fanOut = (ruleStats[id]?.roots ?? 0) > 5
            if level == .trace || (level == .detailed && !fanOut) {
                append(.missing, "folder does not exist", path: path, ruleID: id)
            }
        case .rootEntered(let id, let path, let entries):
            rootsVisited += 1
            currentPath = path
            if level.rawValue >= ScanVerbosity.detailed.rawValue {
                append(.folder, "reading \(Format.count(entries)) entr\(entries == 1 ? "y" : "ies")", path: path, ruleID: id)
            }
        case .measuring(let id, let path):
            measured += 1
            currentPath = path
            if level == .trace {
                append(.measure, "measuring", path: path, ruleID: id)
            }
        case .entrySkipped(let id, let path, let reason):
            examined += 1
            ruleStats[id]?.examined += 1
            ruleStats[id]?.skipped += 1
            skipCounts[reason.text, default: 0] += 1
            if level.rawValue >= ScanVerbosity.detailed.rawValue {
                var text = reason.text
                if case .belowMinimum(let bytes) = reason { text += " (\(Format.bytes(bytes)))" }
                append(.skip, text, path: path, ruleID: id)
            }
        case .itemFound(let item):
            examined += 1
            found += 1
            foundBytes += item.bytes
            ruleStats[item.ruleID]?.examined += 1
            append(.found, "\(item.risk == .caution ? "caution" : "safe") · \(Format.count(item.files)) file\(item.files == 1 ? "" : "s")", path: item.path, ruleID: item.ruleID, bytes: item.bytes)
        case .ruleFinished(let id, let title, let items, let files, let bytes, let examined, let seconds):
            rulesDone += 1
            ruleStats[id]?.items = items
            ruleStats[id]?.files = files
            ruleStats[id]?.bytes = bytes
            ruleStats[id]?.examined = examined
            ruleStats[id]?.seconds = seconds
            ruleStats[id]?.status = .done
            if let stat = ruleStats[id], stat.roots > 5, stat.rootsMissing > 0, level == .detailed {
                append(.missing, "\(Format.count(stat.rootsMissing)) of \(Format.count(stat.roots)) folders do not exist (switch to Trace to list them)", ruleID: id)
            }
            append(.rule, String(format: "■ %@ done in %.2fs · %@ items · %@ · %@ entries examined", title, seconds, Format.count(items), Format.bytes(bytes), Format.count(examined)), ruleID: id)
        case .cancelled:
            append(.warn, "cancel requested, stopping after the current entry")
        }
    }

    private func append(_ level: ScanLineLevel, _ text: String, path: String? = nil, ruleID: String? = nil, bytes: Int64? = nil) {
        let line = ScanLine(id: nextID, time: elapsed, level: level, text: text, path: path, ruleID: ruleID, bytes: bytes)
        nextID += 1
        lines.append(line)
        if lines.count > Self.maxLines {
            let drop = lines.count - Self.maxLines
            lines.removeFirst(drop)
            droppedLines += drop
        }
    }

    // MARK: Export

    var plainText: String {
        var header = "MacLean Smart Scan log\n"
        if let started { header += "Started \(Format.date(started))\n" }
        if droppedLines > 0 { header += "(\(droppedLines) earlier lines dropped from memory)\n" }
        return header + lines.map(\.plain).joined(separator: "\n") + "\n"
    }

    static var logDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MacLean/scan-logs")
    }

    private func writeLog() {
        let dir = Self.logDirectory
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let url = dir.appendingPathComponent("scan-\(formatter.string(from: started ?? Date())).log")
        let text = plainText
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
            logURL = url
            // Keep the 20 most recent logs.
            let logs = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "log" }
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
            for old in logs.dropFirst(20) { try? FileManager.default.removeItem(at: old) }
        } catch {
            append(.warn, "could not write log file: \(error.localizedDescription)")
        }
    }

    func copyToPasteboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(plainText, forType: .string)
        ToastCenter.shared.show("Copied \(Format.count(lines.count)) log lines")
    }

    /// Formats events from a one-off rule test at full detail.
    static func testLines(_ events: [ScanEvent]) -> [ScanLine] {
        var out: [ScanLine] = []
        func add(_ level: ScanLineLevel, _ text: String, _ path: String? = nil, _ bytes: Int64? = nil) {
            out.append(ScanLine(id: out.count, time: 0, level: level, text: text, path: path, bytes: bytes))
        }
        for event in events {
            switch event {
            case .ruleStarted(_, let title, _, let roots): add(.rule, "▶ \(title) · \(roots) folder\(roots == 1 ? "" : "s")")
            case .ruleSkipped(_, _, let reason): add(.warn, "skipped: \(reason)")
            case .rootMissing(_, let path): add(.missing, "folder does not exist", path)
            case .rootEntered(_, let path, let entries): add(.folder, "reading \(Format.count(entries)) entries", path)
            case .measuring: break
            case .entrySkipped(_, let path, let reason): add(.skip, reason.text, path)
            case .itemFound(let item): add(.found, "\(Format.count(item.files)) files", item.path, item.bytes)
            case .ruleFinished(_, _, let items, _, let bytes, let examined, let seconds):
                add(.rule, String(format: "■ done in %.2fs · %@ items · %@ · %@ examined", seconds, Format.count(items), Format.bytes(bytes), Format.count(examined)))
            case .cancelled: add(.warn, "cancelled")
            }
        }
        return out
    }
}

// MARK: - Rule editing

struct RuleTestResult: Sendable {
    let date: Date
    let seconds: Double
    let items: [JunkItem]
    let lines: [ScanLine]
    var bytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
}

/// App-side front for the engine `RuleBook`: edits, custom rules, tests.
@MainActor
final class RuleLab: ObservableObject {
    static let shared = RuleLab()

    @Published private(set) var revision = 0
    @Published private(set) var tests: [String: RuleTestResult] = [:]
    @Published private(set) var testing: Set<String> = []

    var book: RuleBook { RuleBook.shared }
    var rules: [JunkRule] { Rules.resolved }
    var customCount: Int { book.snapshot.custom.count }
    var editedCount: Int { book.snapshot.overrides.values.filter { o in o.title != nil || o.risk != nil || o.autoselect != nil || o.excludes != nil || o.olderThanDays != nil }.count }
    var disabledCount: Int { rules.filter { !book.isEnabled($0.id) }.count }

    func rule(_ id: String) -> JunkRule? { Rules.rule(id: id) }
    func isEnabled(_ id: String) -> Bool { book.isEnabled(id) }
    func isCustom(_ id: String) -> Bool { book.isCustom(id) }
    func custom(_ id: String) -> CustomRule? { book.customRules.first { $0.id == id } }

    private func changed(_ message: String) {
        revision += 1
        objectWillChange.send()
        CleanupStore.shared.objectWillChange.send()
        ToastCenter.shared.show(message)
    }

    private func failed(_ error: Error) {
        ToastCenter.shared.show(error.localizedDescription, error: true)
    }

    func enabledBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { RuleBook.shared.isEnabled(id) },
            set: { RuleLab.shared.setEnabled(id, $0) }
        )
    }

    func setEnabled(_ id: String, _ on: Bool) {
        do {
            try book.setEnabled(on, for: id)
            ActivityLog.shared.add(ActivityEntry(module: "Rules", title: "\(on ? "Enabled" : "Disabled") rule \(id)", items: 0, bytes: 0, failures: 0, detail: ""))
            changed("\(rule(id)?.title ?? id) \(on ? "enabled" : "disabled")")
        } catch { failed(error) }
    }

    func saveOverride(_ id: String, _ override: RuleOverride) {
        do {
            try book.setOverride(override, for: id)
            ActivityLog.shared.add(ActivityEntry(module: "Rules", title: "Edited rule \(id)", items: 0, bytes: 0, failures: 0, detail: ""))
            changed("Saved changes to \(rule(id)?.title ?? id)")
        } catch { failed(error) }
    }

    func resetRule(_ id: String) {
        do {
            try book.setOverride(nil, for: id)
            changed("\(rule(id)?.title ?? id) reset to the built-in definition")
        } catch { failed(error) }
    }

    @discardableResult
    func saveCustom(_ rule: CustomRule) -> Bool {
        do {
            let isNew = !book.isCustom(rule.id)
            try book.upsert(rule)
            ActivityLog.shared.add(ActivityEntry(module: "Rules", title: "\(isNew ? "Created" : "Edited") custom rule \(rule.title)", items: 0, bytes: 0, failures: 0, detail: "~/" + rule.relativePath))
            changed(isNew ? "Created rule \(rule.title)" : "Saved \(rule.title)")
            return true
        } catch {
            failed(error)
            return false
        }
    }

    func deleteCustom(_ id: String) {
        let title = rule(id)?.title ?? id
        do {
            try book.deleteCustom(id: id)
            tests[id] = nil
            ActivityLog.shared.add(ActivityEntry(module: "Rules", title: "Deleted custom rule \(title)", items: 0, bytes: 0, failures: 0, detail: ""))
            changed("Deleted \(title)")
        } catch { failed(error) }
    }

    func resetEdits() {
        do { try book.resetOverrides(); changed("All built-in rules reset to defaults") } catch { failed(error) }
    }

    func resetEverything() {
        do { try book.resetAll(); tests = [:]; changed("Rule book cleared: built-in rules restored, custom rules removed") } catch { failed(error) }
    }

    func reload() {
        book.reload()
        changed("Reloaded \(book.url.lastPathComponent) from disk")
    }

    func exportRules() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "maclean-rules.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try book.exportData().write(to: url, options: .atomic)
            ToastCenter.shared.show("Exported rules to \(url.lastPathComponent)")
        } catch { failed(error) }
    }

    func importRules() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try book.importData(Data(contentsOf: url))
            changed("Imported rules from \(url.lastPathComponent)")
        } catch { failed(error) }
    }

    /// Read-only dry run of one rule (never removes anything).
    func test(_ rule: JunkRule) async {
        guard !testing.contains(rule.id) else { return }
        testing.insert(rule.id)
        let buffer = ScanEventBuffer()
        let observer = buffer.observer
        let threshold = Int64(max(1, CleanupStore.shared.settings.largeThresholdMB)) * 1_048_576
        let minBytes = Int64(max(0, CleanupStore.shared.settings.minSizeMB)) * 1_048_576
        let started = Date()
        let report = await engine {
            JunkScanner(largeFileThreshold: threshold).scan(minBytes: minBytes, rules: [rule], observer: observer)
        }
        tests[rule.id] = RuleTestResult(
            date: Date(),
            seconds: Date().timeIntervalSince(started),
            items: report.items,
            lines: ScanTrace.testLines(buffer.drain())
        )
        testing.remove(rule.id)
    }

    /// Builds the would-be rule for a custom draft so it can be tested before saving.
    func draftRule(_ draft: CustomRule) throws -> JunkRule {
        var rule = draft
        rule.relativePath = try RuleBook.validate(draft)
        if rule.title.isEmpty { rule.title = "Draft rule" }
        return JunkRule(
            id: rule.id,
            title: rule.title,
            category: rule.category,
            location: .home(rule.relativePath),
            mode: {
                switch rule.mode {
                case .contents: return .contents
                case .whole: return .whole
                case .largeFiles: return .largeFiles(olderThanDays: rule.olderThanDays)
                }
            }(),
            excludes: rule.excludes,
            risk: rule.risk,
            autoselect: rule.mode == .largeFiles ? false : rule.autoselect,
            scanOnly: rule.mode == .largeFiles,
            origin: .custom
        )
    }
}
