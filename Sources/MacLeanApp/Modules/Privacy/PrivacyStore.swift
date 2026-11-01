import AppKit
import Foundation
import MacLeanCore

@MainActor
final class PrivacyStore: ObservableObject {
    static let shared = PrivacyStore()

    // Browser + recent-items artifacts (PrivacyScanner)
    @Published private(set) var artifacts: [Artifact] = []
    @Published private(set) var artifactState: LoadState = .idle
    @Published var selected: Set<String> = []
    @Published var forceWhileRunning = false
    @Published var permanent = false
    @Published private(set) var busy = false
    @Published var blockedMessage: String?
    @Published private(set) var lastResult: PrivacyCleanResult?
    @Published private(set) var scanHistory: [Double] = []

    // Live
    @Published private(set) var running: Set<String> = []
    @Published private(set) var footprintHistory: [Double] = []
    @Published private(set) var runningHistory: [Double] = []
    @Published private(set) var pasteboardTypes: [PrivacyPasteboardType] = []
    @Published private(set) var pasteboardChangeCount = 0
    @Published private(set) var pasteboardChanges = 0
    @Published private(set) var pasteboardHistory: [Double] = []
    @Published private(set) var pasteboardPreview: String?

    // TCC
    @Published private(set) var permissions: PermissionReport = .empty
    @Published private(set) var permissionState: LoadState = .idle
    @Published var lastCommand: PrivacyCommandOutput?

    // Extras
    @Published private(set) var savedStates: [PrivacySavedState] = []
    @Published private(set) var savedStateState: LoadState = .idle
    @Published private(set) var quarantine: PrivacyQuarantineReport?
    @Published private(set) var quarantineState: LoadState = .idle
    @Published private(set) var shellFiles: [PrivacyShellFile] = []
    @Published private(set) var shellState: LoadState = .idle
    @Published private(set) var wifi: PrivacyWifiReport?
    @Published private(set) var wifiState: LoadState = .idle
    @Published private(set) var quickLook: PrivacyQuickLookReport?
    @Published private(set) var quickLookState: LoadState = .idle

    private var liveTask: Task<Void, Never>?
    private static let historyLength = 120

    // MARK: Derived

    var totalBytes: Int64 { artifacts.reduce(0) { $0 + $1.bytes } }

    var groups: [(name: String, items: [Artifact], bytes: Int64)] {
        Dictionary(grouping: artifacts, by: \.group)
            .map { ($0.key, $0.value, $0.value.reduce(0) { $0 + $1.bytes }) }
            .sorted { $0.2 > $1.2 }
    }

    var browserNames: [String] {
        let present = Set(artifacts.compactMap(PrivacyBrowsers.owner))
        return PrivacyBrowsers.all.map(\.name).filter { present.contains($0) }
    }

    func artifacts(browser: String) -> [Artifact] {
        artifacts.filter { PrivacyBrowsers.owner(of: $0) == browser }
    }

    func artifacts(group: String) -> [Artifact] {
        artifacts.filter { $0.group == group }
    }

    func artifact(_ path: String) -> Artifact? {
        artifacts.first { $0.path == path }
    }

    var safeArtifacts: [Artifact] {
        artifacts.filter { !PrivacyGroupStyle.unsafeGroups.contains($0.group) }
    }

    func selectedArtifacts(in items: [Artifact]) -> [Artifact] {
        items.filter { selected.contains($0.path) }
    }

    var allowedGrants: Int { permissions.grants.filter(\.allowed).count }

    // MARK: Loading

    func loadAllIfNeeded() {
        if artifactState == .idle { Task { await loadArtifacts() } }
        if permissionState == .idle { Task { await loadPermissions() } }
        if savedStateState == .idle { Task { await loadSavedStates() } }
        if quarantineState == .idle { Task { await loadQuarantine() } }
        if shellState == .idle { Task { await loadShell() } }
        if wifiState == .idle { Task { await loadWifi() } }
        if quickLookState == .idle { Task { await loadQuickLook() } }
        startLive()
    }

    func rescanAll() {
        Task { await loadArtifacts() }
        Task { await loadPermissions() }
        Task { await loadSavedStates() }
        Task { await loadQuarantine() }
        Task { await loadShell() }
        Task { await loadWifi() }
        Task { await loadQuickLook() }
    }

    func loadArtifacts() async {
        guard !artifactState.isLoading else { return }
        artifactState = .loading("Scanning browsers and recent items…")
        let found = await engine(priority: .userInitiated) { PrivacyScanner.scan() }
        artifacts = found
        let present = Set(found.map(\.path))
        selected = selected.intersection(present)
        append(&scanHistory, Double(found.reduce(0) { $0 + $1.bytes }))
        artifactState = .loaded(Date())
        await refreshRunning()
    }

    func loadPermissions() async {
        guard !permissionState.isLoading else { return }
        permissionState = .loading("Reading TCC database…")
        permissions = await engine { PermissionsScanner.scan() }
        permissionState = .loaded(Date())
    }

    func loadSavedStates() async {
        guard !savedStateState.isLoading else { return }
        savedStateState = .loading("Measuring saved application state…")
        savedStates = await engine { PrivacyProbe.savedStates() }
        savedStateState = .loaded(Date())
    }

    func loadQuarantine() async {
        guard !quarantineState.isLoading else { return }
        quarantineState = .loading("Reading download history…")
        let report = await engine { PrivacyProbe.quarantine() }
        quarantine = report
        quarantineState = report.error.map { .failed($0) } ?? .loaded(Date())
    }

    func loadShell() async {
        guard !shellState.isLoading else { return }
        shellState = .loading("Counting history lines…")
        shellFiles = await engine { PrivacyProbe.shellFiles() }
        shellState = .loaded(Date())
    }

    func loadWifi() async {
        guard !wifiState.isLoading else { return }
        wifiState = .loading("Querying networksetup…")
        let report = await engine { PrivacyProbe.wifi() }
        wifi = report
        wifiState = report.error.map { .failed($0) } ?? .loaded(Date())
    }

    func loadQuickLook() async {
        guard !quickLookState.isLoading else { return }
        quickLookState = .loading("Measuring Quick Look cache…")
        quickLook = await engine { PrivacyProbe.quickLook() }
        quickLookState = .loaded(Date())
    }

    // MARK: Live sampling

    func startLive() {
        guard liveTask == nil else { return }
        liveTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                guard let self else { return }
                self.samplePasteboard()
                if tick % 3 == 0 {
                    await self.refreshRunning()
                    let paths = self.artifacts.filter { !$0.isDirectory }.map(\.path)
                    let bytes = await engine(priority: .utility) { PrivacyProbe.footprint(paths) }
                    self.append(&self.footprintHistory, Double(bytes))
                }
                tick += 1
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    func refreshRunning() async {
        let names = await engine(priority: .utility) { PrivacyBrowsers.runningNames() }
        if names != running { running = names }
        append(&runningHistory, Double(names.count))
    }

    private func samplePasteboard() {
        let board = NSPasteboard.general
        let change = board.changeCount
        if change != pasteboardChangeCount || pasteboardTypes.isEmpty {
            if pasteboardChangeCount != 0, change != pasteboardChangeCount { pasteboardChanges += 1 }
            pasteboardChangeCount = change
            let types = board.types ?? []
            pasteboardTypes = types.map { PrivacyPasteboardType(type: $0.rawValue, bytes: board.data(forType: $0)?.count ?? 0) }
            if let text = board.string(forType: .string) {
                pasteboardPreview = String(text.prefix(280))
            } else {
                pasteboardPreview = nil
            }
        }
        append(&pasteboardHistory, Double(pasteboardTypes.reduce(0) { $0 + $1.bytes }))
    }

    func clearPasteboard() {
        let bytes = Int64(pasteboardTypes.reduce(0) { $0 + $1.bytes })
        NSPasteboard.general.clearContents()
        pasteboardTypes = []
        samplePasteboard()
        var summary = RemovalSummary()
        summary.removed = 1
        summary.bytes = bytes
        ActivityLog.shared.record("Privacy", "Clear clipboard", summary)
        setResult("Clear clipboard", summary, detail: "Pasteboard change count \(pasteboardChangeCount)")
    }

    private func append(_ array: inout [Double], _ value: Double) {
        array.append(value)
        if array.count > Self.historyLength { array.removeFirst(array.count - Self.historyLength) }
    }

    // MARK: Actions

    func quit(browser: String) {
        guard let info = PrivacyBrowsers.info(browser) else { return }
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: info.bundleID) {
            app.terminate()
        }
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await refreshRunning()
        }
    }

    /// Cleans artifacts through ArtifactCleaner. Mirrors `maclean privacy --apply`:
    /// refuses while an owning browser is running unless the user forces it.
    func clean(_ items: [Artifact], title: String) async {
        guard !items.isEmpty, !busy else { return }
        blockedMessage = nil
        let owners = Set(items.compactMap(PrivacyBrowsers.owner))
        await refreshRunning()
        let blocking = owners.intersection(running)
        if !blocking.isEmpty, !forceWhileRunning {
            blockedMessage = "Quit \(blocking.sorted().joined(separator: ", ")) before cleaning its data, or turn on “Clean while browsers are running”. Running browsers rewrite these files and may restore or corrupt them."
            return
        }
        busy = true
        let summary = await EngineActions.cleanArtifacts(items, permanent: permanent)
        busy = false
        let detail = Dictionary(grouping: items, by: \.group).map { "\($0.key): \($0.value.count)" }.sorted().joined(separator: ", ")
        ActivityLog.shared.record("Privacy", title, summary, detail: detail)
        selected.subtract(items.map(\.path))
        setResult(title, summary, detail: detail)
        await loadArtifacts()
        Navigator.shared.push(.privacy(.result))
    }

    func resetPermission(service: String, client: String) async {
        let result = await engine { PermissionsScanner.reset(service: service, bundle: client) }
        let tool = PermissionsScanner.tccutilServiceName(service)
        lastCommand = PrivacyCommandOutput(
            title: "Reset \(PrivacyTCC.name(service)) for \(client)",
            command: "tccutil reset \(tool) \(client)",
            status: result.status,
            output: (result.stdout + result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        )
        var summary = RemovalSummary()
        if result.status == 0 { summary.removed = 1 } else { summary.failures = [(client, result.stderr.isEmpty ? "tccutil exited \(result.status)" : result.stderr)] }
        ActivityLog.shared.record("Privacy", "Reset \(PrivacyTCC.name(service))", summary, detail: client)
        await loadPermissions()
    }

    func resetAllPermissions(client: String, services: [String]) async {
        var summary = RemovalSummary()
        var outputs: [String] = []
        for service in services {
            let result = await engine { PermissionsScanner.reset(service: service, bundle: client) }
            outputs.append("\(PermissionsScanner.tccutilServiceName(service)): \(result.status == 0 ? "ok" : (result.stderr + result.stdout).trimmingCharacters(in: .whitespacesAndNewlines))")
            if result.status == 0 { summary.removed += 1 } else { summary.failures.append((service, result.stderr.isEmpty ? "tccutil exited \(result.status)" : result.stderr)) }
        }
        lastCommand = PrivacyCommandOutput(
            title: "Reset \(services.count) permissions for \(client)",
            command: services.map { "tccutil reset \(PermissionsScanner.tccutilServiceName($0)) \(client)" }.joined(separator: "\n"),
            status: summary.failures.isEmpty ? 0 : 1,
            output: outputs.joined(separator: "\n")
        )
        ActivityLog.shared.record("Privacy", "Reset permissions", summary, detail: client)
        await loadPermissions()
    }

    func trashSavedStates(_ items: [PrivacySavedState]) async {
        guard !items.isEmpty else { return }
        busy = true
        var sizes: [String: Int64] = [:]
        for item in items { sizes[item.path] = item.bytes }
        let summary = await EngineActions.trashFiles(items.map(\.path), bytes: sizes)
        busy = false
        ActivityLog.shared.record("Privacy", "Remove saved app state", summary)
        setResult("Remove saved app state", summary, detail: "\(items.count) apps")
        await loadSavedStates()
        Navigator.shared.push(.privacy(.result))
    }

    func clearQuarantine() async {
        busy = true
        let before = quarantine?.count ?? 0
        let output = await engine { PrivacyProbe.clearQuarantine() }
        busy = false
        lastCommand = output
        var summary = RemovalSummary()
        if output.status == 0 {
            summary.removed = before
        } else {
            summary.failures = [(PrivacyProbe.quarantineDB, output.output.isEmpty ? "sqlite3 exited \(output.status)" : output.output)]
        }
        ActivityLog.shared.record("Privacy", "Clear download history", summary, detail: "\(before) quarantine events")
        setResult("Clear download history", summary, detail: "\(Format.count(before)) LSQuarantineEvent rows")
        await loadQuarantine()
    }

    func truncateHistory(_ files: [PrivacyShellFile]) async {
        let paths = files.map(\.path)
        busy = true
        let summary = await engine { PrivacyProbe.truncateHistory(paths) }
        busy = false
        let lines = files.reduce(0) { $0 + $1.lines }
        ActivityLog.shared.record("Privacy", "Clear shell history", summary, detail: "\(lines) lines")
        setResult("Clear shell history", summary, detail: "\(Format.count(lines)) lines in \(files.count) files")
        await loadShell()
        Navigator.shared.push(.privacy(.result))
    }

    func removeWifi(_ names: [String]) async {
        guard let device = wifi?.device, !names.isEmpty else { return }
        busy = true
        let output = await engine { PrivacyProbe.removeWifi(device: device, names: names) }
        busy = false
        lastCommand = output
        var summary = RemovalSummary()
        if output.status == 0 {
            summary.removed = names.count
        } else {
            summary.failures = names.map { ($0, output.output.isEmpty ? "osascript exited \(output.status)" : output.output) }
        }
        ActivityLog.shared.record("Privacy", "Remove Wi-Fi networks", summary, detail: names.joined(separator: ", "))
        await loadWifi()
    }

    func resetQuickLook() async {
        busy = true
        let before = quickLook?.bytes ?? 0
        let output = await engine { PrivacyProbe.resetQuickLook() }
        lastCommand = output
        await loadQuickLook()
        busy = false
        let after = quickLook?.bytes ?? 0
        var summary = RemovalSummary()
        if output.status == 0 {
            summary.removed = 1
            summary.bytes = max(0, before - after)
        } else {
            summary.failures = [("qlmanage", output.output)]
        }
        ActivityLog.shared.record("Privacy", "Reset Quick Look cache", summary)
        setResult("Reset Quick Look cache", summary, detail: "\(Format.bytes(before)) → \(Format.bytes(after))")
    }

    private func setResult(_ title: String, _ summary: RemovalSummary, detail: String) {
        lastResult = PrivacyCleanResult(
            title: title,
            date: Date(),
            removed: summary.removed,
            bytes: summary.bytes,
            failures: summary.failures.map { PrivacyFailure(path: $0.path, reason: $0.reason) },
            detail: detail
        )
    }
}
