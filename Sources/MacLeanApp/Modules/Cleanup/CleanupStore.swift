import Darwin
import Foundation
import MacLeanCore
import SwiftUI

// MARK: - Settings

struct CleanupSettings: Codable, Equatable, Sendable {
    var minSizeMB: Int = 0
    var largeThresholdMB: Int = 500
    var enabled: [String] = JunkCategory.allCases.map(\.rawValue)
    var includeCaution: Bool = true
    var permanent: Bool = false

    static let key = "cleanup.settings.v1"

    static func load() -> CleanupSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let value = try? JSONDecoder().decode(CleanupSettings.self, from: data) else {
            return CleanupSettings()
        }
        return value
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: CleanupSettings.key)
        }
    }

    var enabledCategories: [JunkCategory] {
        JunkCategory.allCases.filter { enabled.contains($0.rawValue) }
    }
}

// MARK: - Models

enum CleanupPhase: Equatable, Sendable {
    case pending, scanning, done
}

struct CleanupCategoryProgress: Identifiable, Equatable, Sendable {
    let category: JunkCategory
    var phase: CleanupPhase = .pending
    var items = 0
    var files = 0
    var bytes: Int64 = 0
    var seconds: Double = 0
    var id: String { category.rawValue }
}

struct CleanupTally: Identifiable, Sendable {
    let category: JunkCategory
    var count: Int
    var bytes: Int64
    var id: String { category.rawValue }
}

struct CleanupRun: Sendable {
    let date: Date
    let title: String
    let permanent: Bool
    let requested: Int
    let removed: [JunkItem]
    let bytes: Int64
    let tallies: [CleanupTally]
    let failures: [(path: String, reason: String)]
}

struct CleanupScanRecord: Codable, Identifiable, Sendable {
    var id = UUID()
    var date: Date
    var duration: Double
    var items: Int
    var files: Int
    var bytes: Int64
    var recommendedBytes: Int64
}

struct CleanupChild: Identifiable, Sendable {
    let path: String
    let bytes: Int64
    let files: Int
    let isDirectory: Bool
    let modified: Date?
    let device: UInt64?
    let inode: UInt64?
    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
}

struct CleanupRootEstimate: Identifiable, Sendable {
    let ruleID: String
    let title: String
    let root: String
    let readable: Bool
    let entries: Int
    let files: Int
    let bytes: Int64
    var id: String { ruleID + root }
}

enum CleanupSort: String, CaseIterable, Identifiable {
    case size = "Size"
    case name = "Name"
    case date = "Date"
    var id: String { rawValue }

    func apply(_ items: [JunkItem]) -> [JunkItem] {
        switch self {
        case .size: return items.sorted { $0.bytes > $1.bytes }
        case .name: return items.sorted { CleanupText.name($0.path).localizedStandardCompare(CleanupText.name($1.path)) == .orderedAscending }
        case .date: return items.sorted { ($0.modified ?? .distantPast) < ($1.modified ?? .distantPast) }
        }
    }
}

// MARK: - Store

@MainActor
final class CleanupStore: ObservableObject {
    static let shared = CleanupStore()

    @Published var settings: CleanupSettings {
        didSet { settings.save() }
    }

    @Published private(set) var items: [JunkItem] = []
    @Published private(set) var scanState: LoadState = .idle
    @Published private(set) var progress: [CleanupCategoryProgress] = []
    @Published private(set) var currentCategory: JunkCategory?
    @Published private(set) var scanStarted: Date?
    @Published private(set) var scanFinished: Date?
    @Published private(set) var foundHistory: [Double] = []
    @Published private(set) var diskReadHistory: [Double] = []
    @Published private(set) var itemsHistory: [Double] = []
    @Published var selection: Set<String> = []

    @Published private(set) var cleaning = false
    @Published private(set) var lastClean: CleanupRun?

    @Published private(set) var trashItems: [JunkItem] = []
    @Published private(set) var trashState: LoadState = .idle

    @Published private(set) var children: [String: [CleanupChild]] = [:]
    @Published private(set) var childState: [String: LoadState] = [:]

    @Published private(set) var rootEstimates: [CleanupRootEstimate] = []
    @Published private(set) var rootState: LoadState = .idle
    @Published private(set) var adminOutput: String?
    @Published private(set) var adminStatus: Int32?
    @Published private(set) var adminRunning = false

    @Published private(set) var scanLog: [CleanupScanRecord] = []

    let trace = ScanTrace.shared
    private var buffer = ScanEventBuffer()
    private var scanTask: Task<Void, Never>?
    private var samplerTask: Task<Void, Never>?
    private static let scanLogKey = "cleanup.scanlog.v1"

    init() {
        settings = CleanupSettings.load()
        if let data = UserDefaults.standard.data(forKey: Self.scanLogKey) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            scanLog = (try? decoder.decode([CleanupScanRecord].self, from: data)) ?? []
        }
    }

    // MARK: Derived

    var hasResults: Bool { scanState.loadedAt != nil || !items.isEmpty }

    /// Items honouring the "include caution" option.
    var visibleItems: [JunkItem] {
        settings.includeCaution ? items : items.filter { $0.risk == .safe }
    }

    var totalBytes: Int64 { visibleItems.reduce(0) { $0 + $1.bytes } }
    var totalFiles: Int { visibleItems.reduce(0) { $0 + $1.files } }

    var recommended: [JunkItem] {
        visibleItems.filter { isRecommended($0) }
    }

    var recommendedBytes: Int64 { recommended.reduce(0) { $0 + $1.bytes } }

    var selectedItems: [JunkItem] {
        visibleItems.filter { selection.contains($0.path) }
    }

    var selectedBytes: Int64 { selectedItems.reduce(0) { $0 + $1.bytes } }

    var cautionItems: [JunkItem] { items.filter { $0.risk == .caution } }

    func isRecommended(_ item: JunkItem) -> Bool {
        guard item.autoselect, !item.requiresRoot else { return false }
        if let rule = Rules.rule(id: item.ruleID) {
            if rule.scanOnly || !rule.autoselect { return false }
        }
        return true
    }

    func items(in category: JunkCategory) -> [JunkItem] {
        visibleItems.filter { $0.category == category }
    }

    func items(rule id: String) -> [JunkItem] {
        items.filter { $0.ruleID == id }
    }

    func bytes(_ list: [JunkItem]) -> Int64 { list.reduce(0) { $0 + $1.bytes } }
    func files(_ list: [JunkItem]) -> Int { list.reduce(0) { $0 + $1.files } }

    func tallies(_ list: [JunkItem]) -> [CleanupTally] {
        var map: [JunkCategory: CleanupTally] = [:]
        for item in list {
            map[item.category, default: CleanupTally(category: item.category, count: 0, bytes: 0)].count += 1
            map[item.category]?.bytes += item.bytes
        }
        return map.values.sorted { $0.category.order < $1.category.order }
    }

    struct RuleTally: Identifiable {
        let id: String
        let title: String
        let count: Int
        let bytes: Int64
    }

    func ruleTallies(_ list: [JunkItem]) -> [RuleTally] {
        Dictionary(grouping: list, by: \.ruleID).map { id, group in
            RuleTally(id: id, title: group.first?.ruleTitle ?? id, count: group.count, bytes: group.reduce(0) { $0 + $1.bytes })
        }
        .sorted { $0.bytes > $1.bytes }
    }

    // MARK: Selection

    func binding(_ path: String) -> Binding<Bool> {
        Binding(
            get: { CleanupStore.shared.selection.contains(path) },
            set: { on in
                if on { CleanupStore.shared.selection.insert(path) } else { CleanupStore.shared.selection.remove(path) }
            }
        )
    }

    func select(_ list: [JunkItem]) { selection.formUnion(list.map(\.path)) }
    func deselect(_ list: [JunkItem]) { selection.subtract(list.map(\.path)) }
    func selectRecommended() { selection = Set(recommended.map(\.path)) }

    var confirmMessage: String {
        settings.permanent
            ? "Permanent delete is ON in Scan Options: items are deleted immediately and cannot be recovered. Every path is re-validated by the engine against its rule roots first."
            : "Items are moved to the Trash (Trash contents are deleted). Every path is re-validated by the engine against its rule roots and file identity first."
    }

    // MARK: Scanning

    func scan() {
        guard !scanState.isLoading else { return }
        let categories = settings.enabledCategories
        guard !categories.isEmpty else {
            scanState = .failed("No categories enabled in Scan Options")
            return
        }
        progress = categories.map { CleanupCategoryProgress(category: $0) }
        items = []
        selection = []
        children = [:]
        childState = [:]
        scanStarted = Date()
        scanFinished = nil
        foundHistory = []
        diskReadHistory = []
        itemsHistory = []
        scanState = .loading("Preparing scan")
        startSampler()
        let minBytes = Int64(max(0, settings.minSizeMB)) * 1_048_576
        let threshold = Int64(max(1, settings.largeThresholdMB)) * 1_048_576
        buffer = ScanEventBuffer()
        let set = Set(categories)
        trace.begin(rulesTotal: Rules.all.filter { set.contains($0.category) }.count, categories: categories, minBytes: minBytes, threshold: threshold)
        scanTask = Task { await self.runScan(categories, minBytes: minBytes, threshold: threshold) }
    }

    func stopScan() {
        buffer.cancel()
        scanTask?.cancel()
        trace.note("Stop requested", level: .warn)
    }

    private var stopped: Bool { Task.isCancelled || buffer.isCancelled }

    private func scanCategory(_ category: JunkCategory, minBytes: Int64, threshold: Int64) async -> ScanReport {
        let observer = buffer.observer
        let cancel = buffer.cancelCheck
        let report = await engine {
            JunkScanner(largeFileThreshold: threshold).scan(categories: [category], minBytes: minBytes, rules: nil, observer: observer, isCancelled: cancel)
        }
        trace.ingest(buffer.drain())
        return report
    }

    private func runScan(_ categories: [JunkCategory], minBytes: Int64, threshold: Int64) async {
        for (index, category) in categories.enumerated() {
            if stopped { break }
            currentCategory = category
            progress[index].phase = .scanning
            scanState = .loading("Scanning \(category.title.lowercased()) (\(index + 1)/\(categories.count))")
            trace.note("── Category \(index + 1)/\(categories.count): \(category.title) · \(Rules.all.filter { $0.category == category }.count) rules", level: .info)
            let started = Date()
            let report = await scanCategory(category, minBytes: minBytes, threshold: threshold)
            let fresh = merge(report.items)
            let overlap = report.items.count - fresh.count
            trace.note(String(format: "── %@ done in %.2fs · %@ new items · %@", category.title, Date().timeIntervalSince(started), Format.count(fresh.count), Format.bytes(fresh.reduce(0) { $0 + $1.bytes })) + (overlap > 0 ? " · \(overlap) already reported by earlier categories" : ""))
            progress[index].phase = .done
            progress[index].items = fresh.count
            progress[index].files = fresh.reduce(0) { $0 + $1.files }
            progress[index].bytes = fresh.reduce(0) { $0 + $1.bytes }
            progress[index].seconds = Date().timeIntervalSince(started)
        }
        currentCategory = nil
        stopSampler()
        sample()
        let finished = Date()
        scanFinished = finished
        selection = Set(recommended.map(\.path))
        let wasStopped = stopped
        trace.ingest(buffer.drain())
        trace.note("Pre-selected \(Format.count(selection.count)) recommended items (safe, auto-select, no admin)")
        trace.finish(cancelled: wasStopped, items: items.count, bytes: bytes(items), recommended: recommendedBytes)
        if wasStopped {
            scanState = .loaded(finished)
            ToastCenter.shared.show("Scan stopped · \(Format.bytes(totalBytes)) found so far")
        } else {
            scanState = .loaded(finished)
        }
        let record = CleanupScanRecord(
            date: finished,
            duration: finished.timeIntervalSince(scanStarted ?? finished),
            items: items.count,
            files: files(items),
            bytes: bytes(items),
            recommendedBytes: recommendedBytes
        )
        scanLog.insert(record, at: 0)
        if scanLog.count > 60 { scanLog.removeLast(scanLog.count - 60) }
        saveScanLog()
    }

    /// Rescans a single category and replaces its items in the report.
    func rescan(_ category: JunkCategory) async {
        guard !scanState.isLoading else { return }
        scanState = .loading("Rescanning \(category.title.lowercased())")
        let minBytes = Int64(max(0, settings.minSizeMB)) * 1_048_576
        let threshold = Int64(max(1, settings.largeThresholdMB)) * 1_048_576
        buffer = ScanEventBuffer()
        trace.begin(rulesTotal: Rules.all.filter { $0.category == category }.count, categories: [category], minBytes: minBytes, threshold: threshold)
        startSampler()
        let report = await scanCategory(category, minBytes: minBytes, threshold: threshold)
        stopSampler()
        let old = Set(items.filter { $0.category == category }.map(\.path))
        items.removeAll { $0.category == category }
        selection.subtract(old)
        let fresh = merge(report.items)
        selection.formUnion(fresh.filter { isRecommended($0) }.map(\.path))
        if let index = progress.firstIndex(where: { $0.category == category }) {
            progress[index].items = fresh.count
            progress[index].bytes = bytes(fresh)
            progress[index].files = files(fresh)
            progress[index].phase = .done
        }
        scanState = .loaded(Date())
        trace.finish(cancelled: false, items: fresh.count, bytes: bytes(fresh), recommended: bytes(fresh.filter { isRecommended($0) }))
    }

    @discardableResult
    private func merge(_ incoming: [JunkItem]) -> [JunkItem] {
        var claimed = Set(items.map(\.path))
        var fresh: [JunkItem] = []
        for item in incoming {
            if claimed.contains(item.path) || Self.isUnder(item.path, claimed) { continue }
            claimed.insert(item.path)
            fresh.append(item)
        }
        items.append(contentsOf: fresh)
        items.sort { lhs, rhs in
            if lhs.category != rhs.category { return lhs.category.order < rhs.category.order }
            return lhs.bytes > rhs.bytes
        }
        return fresh
    }

    private static func isUnder(_ path: String, _ claimed: Set<String>) -> Bool {
        var current = (path as NSString).deletingLastPathComponent
        while current.count > 1 {
            if claimed.contains(current) { return true }
            current = (current as NSString).deletingLastPathComponent
        }
        return false
    }

    private func startSampler() {
        samplerTask?.cancel()
        samplerTask = Task {
            while !Task.isCancelled {
                self.trace.ingest(self.buffer.drain())
                self.sample()
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    private func stopSampler() {
        samplerTask?.cancel()
        samplerTask = nil
    }

    private func sample() {
        func push(_ value: Double, _ list: inout [Double]) {
            list.append(value)
            if list.count > SystemMonitor.historyLength { list.removeFirst(list.count - SystemMonitor.historyLength) }
        }
        push(Double(bytes(items)) / 1_048_576, &foundHistory)
        push(SystemMonitor.shared.latest.disk.readPerSec / 1_048_576, &diskReadHistory)
        push(Double(items.count), &itemsHistory)
    }

    private func saveScanLog() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(scanLog) {
            UserDefaults.standard.set(data, forKey: Self.scanLogKey)
        }
    }

    func clearScanLog() {
        scanLog = []
        saveScanLog()
    }

    // MARK: Cleaning

    /// Runs the engine `Cleaner` on the given items, records the result and
    /// drops removed items from every cached dataset.
    func clean(_ targets: [JunkItem], title: String) async {
        guard !targets.isEmpty, !cleaning else { return }
        cleaning = true
        defer { cleaning = false }
        let permanent = settings.permanent
        let list = targets
        let result = await engine {
            Cleaner().clean(list, options: CleanOptions(apply: true, permanent: permanent, includeCaution: true))
        }
        let removed = result.movedToTrash + result.deleted
        var summary = RemovalSummary()
        summary.removed = removed.count
        summary.bytes = result.trashedBytes + result.reclaimedBytes
        summary.failures = (result.failed + result.skipped).map { ($0.path, $0.reason) }
        let tallies = tallies(removed)
        lastClean = CleanupRun(
            date: Date(),
            title: title,
            permanent: permanent,
            requested: targets.count,
            removed: removed,
            bytes: summary.bytes,
            tallies: tallies,
            failures: summary.failures
        )
        let removedPaths = Set(removed.map(\.path))
        items.removeAll { item in removedPaths.contains(item.path) || removedPaths.contains(where: { item.path.hasPrefix($0 + "/") }) }
        trashItems.removeAll { removedPaths.contains($0.path) }
        selection.subtract(removedPaths)
        for path in removedPaths {
            children[path] = nil
            childState[path] = nil
        }
        for (parent, kids) in children where kids.contains(where: { removedPaths.contains($0.path) }) {
            children[parent] = kids.filter { !removedPaths.contains($0.path) }
        }
        for index in progress.indices {
            let list = items.filter { $0.category == progress[index].category }
            progress[index].items = list.count
            progress[index].bytes = bytes(list)
            progress[index].files = files(list)
        }
        let detail = tallies.map { "\($0.category.title): \($0.count) · \(Format.bytes($0.bytes))" }.joined(separator: "\n")
        ActivityLog.shared.record("Cleanup", title, summary, detail: detail)
    }

    // MARK: Item lookup + children

    func item(at path: String) -> JunkItem? {
        if let item = items.first(where: { $0.path == path }) ?? trashItems.first(where: { $0.path == path }) {
            return item
        }
        for (parentPath, kids) in children {
            guard let child = kids.first(where: { $0.path == path }), let parent = item(at: parentPath) else { continue }
            return JunkItem(
                path: child.path,
                bytes: child.bytes,
                files: child.files,
                ruleID: parent.ruleID,
                ruleTitle: parent.ruleTitle,
                category: parent.category,
                risk: parent.risk,
                autoselect: parent.autoselect,
                requiresRoot: parent.requiresRoot,
                isDirectory: child.isDirectory,
                modified: child.modified,
                device: child.device,
                inode: child.inode
            )
        }
        return nil
    }

    func parentItem(of path: String) -> JunkItem? {
        (items + trashItems).first { path.hasPrefix($0.path + "/") }
    }

    func loadChildren(_ path: String, force: Bool = false) async {
        if !force, children[path] != nil { return }
        if childState[path]?.isLoading == true { return }
        childState[path] = .loading("Measuring contents")
        let target = path
        let list = await engine { () -> [CleanupChild] in
            let fm = FileManager.default
            let urls = (try? fm.contentsOfDirectory(at: URL(fileURLWithPath: target), includingPropertiesForKeys: nil)) ?? []
            return urls.prefix(1_500).map { url in
                let size = FileSizer.measure(url)
                return CleanupChild(
                    path: url.standardizedFileURL.path,
                    bytes: size.bytes,
                    files: size.files,
                    isDirectory: size.isDirectory,
                    modified: size.modified,
                    device: size.device,
                    inode: size.inode
                )
            }
            .sorted { $0.bytes > $1.bytes }
        }
        children[path] = list
        childState[path] = .loaded(Date())
    }

    // MARK: Trash

    func loadTrash() async {
        guard !trashState.isLoading else { return }
        trashState = .loading("Measuring Trash bins")
        let report = await engine { JunkScanner().scan(categories: [.trash]) }
        trashItems = report.items
        trashState = .loaded(Date())
    }

    func emptyUserTrash() async {
        guard !cleaning else { return }
        cleaning = true
        let summary = await EngineActions.emptyTrash()
        cleaning = false
        let trashed = trashItems.filter { CleanupText.isUserTrash($0.path) }
        lastClean = CleanupRun(
            date: Date(),
            title: "Empty Trash",
            permanent: true,
            requested: trashed.count,
            removed: [],
            bytes: summary.bytes,
            tallies: [CleanupTally(category: .trash, count: summary.removed, bytes: summary.bytes)],
            failures: summary.failures
        )
        ActivityLog.shared.record("Cleanup", "Empty Trash", summary)
        items.removeAll { CleanupText.isUserTrash($0.path) }
        await loadTrash()
    }

    // MARK: Root-only rules

    var rootRules: [JunkRule] { Rules.all.filter(\.requiresRoot) }

    func loadRootEstimates() async {
        guard !rootState.isLoading else { return }
        rootState = .loading("Measuring protected locations (read-only)")
        let rules = rootRules.map { ($0.id, $0.title, RuleRoots(home: EngineActions.home).roots(for: $0).map(\.path)) }
        let estimates = await engine { () -> [CleanupRootEstimate] in
            let fm = FileManager.default
            var out: [CleanupRootEstimate] = []
            for (id, title, roots) in rules {
                for root in roots {
                    guard let names = try? fm.contentsOfDirectory(atPath: root) else {
                        out.append(CleanupRootEstimate(ruleID: id, title: title, root: root, readable: false, entries: 0, files: 0, bytes: 0))
                        continue
                    }
                    var bytes: Int64 = 0
                    var files = 0
                    for name in names {
                        let size = FileSizer.measure(URL(fileURLWithPath: root).appendingPathComponent(name))
                        bytes += size.bytes
                        files += size.files
                    }
                    out.append(CleanupRootEstimate(ruleID: id, title: title, root: root, readable: true, entries: names.count, files: files, bytes: bytes))
                }
            }
            return out
        }
        rootEstimates = estimates
        rootState = .loaded(Date())
    }

    var rootCategories: [JunkCategory] {
        let set = Set(rootRules.map(\.category))
        return JunkCategory.allCases.filter { set.contains($0) }
    }

    func rootCommand(cliPath: String, apply: Bool) -> String {
        var parts = [CleanupText.shellQuote(cliPath), "clean", "--category", rootCategories.map(\.rawValue).joined(separator: ","), "--include-caution"]
        if apply {
            parts += ["--apply", "--yes"]
            if settings.permanent { parts.append("--permanent") }
        }
        return parts.joined(separator: " ")
    }

    func runAdmin(apply: Bool) async {
        guard !adminRunning else { return }
        guard let cli = CLI.locate() else {
            adminOutput = "The maclean command-line tool was not found next to the app or in PATH. Build it with `swift build -c release`."
            adminStatus = 127
            return
        }
        adminRunning = true
        adminOutput = nil
        adminStatus = nil
        let command = rootCommand(cliPath: cli.path, apply: apply) + " 2>&1"
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"
        let result = await engine { ProcessRunner.run("/usr/bin/osascript", ["-e", script], timeout: 1_800) }
        adminRunning = false
        adminStatus = result.status
        let text = [result.stdout, result.stderr].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: "\n")
        adminOutput = text.isEmpty ? "(no output)" : text
        if apply, result.status == 0 {
            ActivityLog.shared.add(ActivityEntry(module: "Cleanup", title: "Admin clean (system, updates)", items: 0, bytes: 0, failures: 0, detail: text))
            ToastCenter.shared.show("Administrator clean finished")
            await loadRootEstimates()
        }
    }
}

// MARK: - Text helpers

enum CleanupText {
    static func name(_ path: String) -> String { (path as NSString).lastPathComponent }

    static func isUserTrash(_ path: String) -> Bool {
        path.hasPrefix(EngineActions.home.appendingPathComponent(".Trash").path + "/")
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func icon(_ category: JunkCategory) -> String {
        switch category {
        case .system: return "gearshape.2"
        case .dev: return "hammer"
        case .browser: return "globe"
        case .ai: return "cpu"
        case .updates: return "arrow.down.circle"
        case .trash: return "trash"
        case .large: return "doc.richtext"
        }
    }

    static func tint(_ category: JunkCategory) -> Color {
        switch category {
        case .system: return Theme.accent
        case .dev: return Theme.info
        case .browser: return Theme.success
        case .ai: return Color(red: 0.55, green: 0.42, blue: 0.78)
        case .updates: return Theme.warning
        case .trash: return Theme.danger
        case .large: return Theme.muted
        }
    }

    static func blurb(_ category: JunkCategory) -> String {
        switch category {
        case .system: return "User caches, logs, saved application state, crash reports, Mail downloads, sandbox container caches and device backups. Caches are rebuilt by apps on demand."
        case .dev: return "Xcode DerivedData, archives, device support files, simulator caches and package-manager caches (SwiftPM, Homebrew, npm, Gradle, Cargo and more). Build caches regenerate on the next build."
        case .browser: return "On-disk caches of Chrome, Firefox, Brave, Edge, Safari and Arc. History, cookies and passwords are not touched — those live in Privacy."
        case .ai: return "Model caches and app caches from local AI tools (Ollama, Hugging Face, PyTorch, Whisper, LM Studio, Cursor, Claude and ChatGPT desktop apps). Downloaded models must be re-downloaded if removed."
        case .updates: return "Software Update and Sparkle downloads that were left behind after updates were installed."
        case .trash: return "Items already in your Trash and in the Trash bins of mounted local volumes. Removing these deletes them permanently."
        case .large: return "Large files in Downloads, Desktop, Documents and Movies. These are never recommended automatically: review each one."
        }
    }

    static func cautionReason(_ ruleID: String) -> String {
        switch ruleID {
        case "xcode-archives": return "Archives hold the dSYMs needed to symbolicate crash reports of shipped builds."
        case "ios-device-support", "watchos-device-support", "tvos-device-support", "visionos-device-support":
            return "Re-downloaded by Xcode the next time that device and OS version is connected, which can take a while."
        case "ios-backups": return "These may be the only backup of an iPhone or iPad. Remove only backups of devices you no longer own."
        case "sandbox-autosave": return "Autosaved, possibly unsaved documents of sandboxed apps."
        case "simulator-runtimes": return "Simulator runtimes must be re-downloaded from Xcode Settings › Platforms."
        case "gradle-cache": return "Gradle will re-download every dependency on the next build."
        case "system-logs", "system-caches", "system-updates": return "Shared system locations; requires administrator rights and affects every user."
        default:
            if ruleID.hasPrefix("large-") { return "Personal files: the engine only reports these. Review before removing." }
            if let rule = Rules.rule(id: ruleID), rule.category == .ai { return "Downloaded models or app data that must be fetched again if removed." }
            return "Not auto-selected by the engine; review before removing."
        }
    }

    static func location(_ rule: JunkRule) -> String {
        switch rule.location {
        case .home(let relative): return "~/" + relative
        case .absolute(let path): return path
        case .volumeTrashes: return "/Volumes/*/.Trashes/<uid>"
        case .containerCaches: return "~/Library/Containers/*/Data/Library/Caches"
        case .containerSubpath(let relative): return "~/Library/Containers/*/" + relative
        }
    }

    static func mode(_ rule: JunkRule) -> String {
        switch rule.mode {
        case .contents: return "Each entry inside the folder"
        case .whole: return "The folder as a whole"
        case .largeFiles(let days):
            if let days { return "Large files older than \(days) days" }
            return "Large files (above threshold)"
        }
    }
}
