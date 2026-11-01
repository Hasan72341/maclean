import AppKit
import Combine
import Foundation
import MacLeanCore
import SwiftUI

@MainActor
final class AppsStore: ObservableObject {
    static let shared = AppsStore()

    @Published private(set) var apps: [AppsApp] = []
    @Published private(set) var appsState: LoadState = .idle
    @Published private(set) var extraApps: [String: AppsApp] = [:]

    @Published private(set) var bundleInfos: [String: AppsBundleInfo] = [:]
    @Published private(set) var bundleStates: [String: LoadState] = [:]

    @Published private(set) var plans: [String: [Artifact]] = [:]
    @Published private(set) var planStates: [String: LoadState] = [:]
    @Published private(set) var outcomes: [String: AppsUninstallOutcome] = [:]
    @Published private(set) var busyPaths: Set<String> = []

    @Published private(set) var archMap: [String: [String]] = [:]
    @Published private(set) var archState: LoadState = .idle

    @Published private(set) var orphans: [LeftoverGroup] = []
    @Published private(set) var orphansState: LoadState = .idle
    @Published var leftoverSelection: Set<String> = []
    @Published private(set) var ignoredLeftovers: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "apps.leftovers.ignored") ?? [])
    @Published private(set) var lastLeftoverClean: AppsLeftoverClean?

    @Published private(set) var extensions: [AppsExtension] = []
    @Published private(set) var extensionsState: LoadState = .idle

    @Published private(set) var launchItems: [AppsLaunchMatch] = []
    @Published private(set) var launchState: LoadState = .idle

    @Published private(set) var updates: [String] = []
    @Published private(set) var updateHistory: [String] = []
    @Published private(set) var updatesState: LoadState = .idle

    @Published private(set) var running: [AppsRunning] = []
    @Published private(set) var runningMemoryHistory: [Double] = []
    @Published private(set) var runningCPUHistory: [Double] = []
    @Published private(set) var runningCountHistory: [Double] = []
    @Published private(set) var pidCPU: [Int32: [Double]] = [:]
    @Published private(set) var pidMemory: [Int32: [Double]] = [:]

    @Published var lastFailures: [(path: String, reason: String)] = []
    @Published var lastAdminOutput: String?

    private var cancellables = Set<AnyCancellable>()
    private var iconCache: [String: NSImage] = [:]

    init() {
        // Items removed later with administrator rights: refresh what is listed.
        NotificationCenter.default.publisher(for: .macleanAdminRemoved)
            .receive(on: RunLoop.main)
            .sink { [weak self] note in
                let paths = note.object as? [String] ?? []
                Task { @MainActor in self?.refreshAfterRemoval(appRemoved: paths.contains { $0.hasSuffix(".app") }) }
            }
            .store(in: &cancellables)
        SystemMonitor.shared.start()
        SystemMonitor.shared.$processes
            .receive(on: RunLoop.main)
            .sink { [weak self] list in
                Task { @MainActor in self?.ingest(list) }
            }
            .store(in: &cancellables)
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            center.publisher(for: name)
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in
                    Task { @MainActor in self?.ingest(SystemMonitor.shared.processes) }
                }
                .store(in: &cancellables)
        }
    }

    // MARK: Lookups

    var totalBytes: Int64 { apps.reduce(0) { $0 + $1.bytes } }
    var visibleOrphans: [LeftoverGroup] { orphans.filter { !ignoredLeftovers.contains($0.appID) } }
    var orphanBytes: Int64 { visibleOrphans.reduce(0) { $0 + $1.bytes } }
    var orphanItemCount: Int { visibleOrphans.reduce(0) { $0 + $1.items.count } }
    func orphanGroup(_ id: String) -> LeftoverGroup? { orphans.first { $0.appID == id } }
    func orphanItem(_ path: String) -> (group: LeftoverGroup, item: Artifact)? {
        for group in orphans { if let item = group.items.first(where: { $0.path == path }) { return (group, item) } }
        return nil
    }
    var extensionBytes: Int64 { extensions.reduce(0) { $0 + $1.bytes } }

    func app(_ path: String) -> AppsApp? {
        apps.first { $0.path == path } ?? extraApps[path]
    }

    func unused(days: Int) -> [AppsApp] {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        return apps.filter { ($0.lastUsed ?? .distantFuture) < cutoff }.sorted { $0.bytes > $1.bytes }
    }

    var neverOpened: [AppsApp] { apps.filter { $0.lastUsed == nil } }

    func icon(_ path: String) -> NSImage {
        if let cached = iconCache[path] { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        iconCache[path] = image
        return image
    }

    func runningApp(for path: String) -> AppsRunning? {
        running.first { $0.path == path }
    }

    func launchItems(for app: AppsApp) -> [AppsLaunchMatch] {
        launchItems.filter { $0.appPath == app.path }
    }

    func architectureClass(_ path: String) -> String {
        guard let archs = archMap[path] else { return "Unknown" }
        return AppsScan.architectureClass(archs)
    }

    // MARK: Loading

    func loadApps(force: Bool = false) {
        if appsState.isLoading { return }
        if !force, appsState.loadedAt != nil { return }
        appsState = .loading("Reading /Applications and ~/Applications, measuring bundles…")
        Task {
            let list = await engine { AppsScan.installedApps() }
            apps = list
            appsState = .loaded(Date())
            iconCache = [:]
        }
    }

    func ensureApp(_ path: String) {
        if app(path) != nil { return }
        if appsState.loadedAt == nil { loadApps() }
        Task {
            if let single = await engine({ AppsScan.singleApp(path: path) }) {
                extraApps[path] = single
            }
        }
    }

    func loadBundleInfo(_ path: String, force: Bool = false) {
        if bundleStates[path]?.isLoading == true { return }
        if !force, bundleInfos[path] != nil { return }
        bundleStates[path] = .loading("Checking signature, Gatekeeper, architectures and bundle contents…")
        Task {
            let info = await engine { AppsScan.bundleInfo(path: path) }
            bundleInfos[path] = info
            bundleStates[path] = .loaded(Date())
        }
    }

    func loadPlan(_ path: String, force: Bool = false) {
        if planStates[path]?.isLoading == true { return }
        if !force, plans[path] != nil { return }
        guard let app = app(path) else {
            ensureApp(path)
            return
        }
        let info = app.appInfo
        planStates[path] = .loading("Finding everything \(app.name) left on this Mac…")
        Task {
            let artifacts = await engine { Uninstaller.plan(for: info) }
            plans[path] = artifacts
            planStates[path] = .loaded(Date())
        }
    }

    func loadArchitectures(force: Bool = false) {
        if archState.isLoading { return }
        if !force, archState.loadedAt != nil, archMap.count >= apps.count { return }
        let paths = apps.map(\.path)
        guard !paths.isEmpty else { return }
        archState = .loading("Inspecting \(paths.count) executables with lipo…")
        Task {
            archMap = await engine { AppsScan.architectureMap(paths: paths) }
            archState = .loaded(Date())
        }
    }

    func loadOrphans(force: Bool = false) {
        if orphansState.isLoading { return }
        if !force, orphansState.loadedAt != nil { return }
        orphansState = .loading("Reading installed apps and their helpers…")
        Task {
            if appsState.loadedAt == nil { loadApps() }
            while appsState.isLoading { try? await Task.sleep(nanoseconds: 300_000_000) }
            var installed = Set(apps.compactMap(\.bundleID))
            installed.formUnion(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
            orphansState = .loading("Matching \(Leftovers.userLocations.count) Library locations against \(installed.count) installed bundle IDs…")
            let known = installed
            let groups = await engine { () -> [LeftoverGroup] in
                var ids = known
                ids.formUnion(Leftovers.installedBundleIDs())
                ids.formUnion(AppsScan.systemBundleIDs())
                return Leftovers.orphans(installedIDs: ids, isInstalled: { id in
                    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return false }
                    return FileManager.default.fileExists(atPath: url.path) && !url.path.contains("/.Trash/")
                })
            }
            orphans = groups
            let valid = Set(groups.flatMap { $0.items.map(\.path) })
            leftoverSelection.formIntersection(valid)
            orphansState = .loaded(Date())
        }
    }

    /// Pre-selects leftovers the engine is confident about.
    func selectRecommendedLeftovers() {
        leftoverSelection = Set(visibleOrphans.filter { $0.confidence >= .medium && !$0.vendorInstalled }.flatMap { $0.items.map(\.path) })
    }

    func ignoreLeftovers(_ id: String, _ ignore: Bool) {
        if ignore { ignoredLeftovers.insert(id) } else { ignoredLeftovers.remove(id) }
        UserDefaults.standard.set(Array(ignoredLeftovers), forKey: "apps.leftovers.ignored")
        if ignore, let group = orphanGroup(id) { leftoverSelection.subtract(group.items.map(\.path)) }
    }

    /// Removes leftovers through the engine's ArtifactCleaner (root-scoped,
    /// identity-checked, Trash by default).
    func cleanLeftovers(_ items: [Artifact], title: String) async -> RemovalSummary {
        let summary = await EngineActions.cleanArtifacts(items)
        let failed = Set(summary.failures.map(\.path))
        let removed = items.filter { !failed.contains($0.path) }
        let removedPaths = Set(removed.map(\.path))
        let apps = Set(orphans.filter { g in g.items.contains { removedPaths.contains($0.path) } }.map(\.displayName))
        ActivityLog.shared.record("Apps", title, summary, detail: removed.map { "\($0.group): \(Format.abbreviated($0.path))" }.joined(separator: "\n"))
        lastFailures = summary.failures
        lastLeftoverClean = AppsLeftoverClean(date: Date(), title: title, apps: apps.sorted(), removed: removed, summary: summary)
        leftoverSelection.subtract(removedPaths)
        orphans = orphans.compactMap { group in
            let rest = group.items.filter { !removedPaths.contains($0.path) }
            if rest.isEmpty { return nil }
            if rest.count == group.items.count { return group }
            return LeftoverGroup(appID: group.appID, displayName: group.displayName, items: rest, confidence: group.confidence, reasons: group.reasons, vendorInstalled: group.vendorInstalled, trashedApp: group.trashedApp)
        }
        return summary
    }

    func loadExtensions(force: Bool = false) {
        if extensionsState.isLoading { return }
        if !force, extensionsState.loadedAt != nil { return }
        extensionsState = .loading("Scanning plug-in folders in ~/Library and /Library…")
        Task {
            extensions = await engine { AppsScan.extensions() }
            extensionsState = .loaded(Date())
        }
    }

    func loadLaunchItems(force: Bool = false) {
        if launchState.isLoading { return }
        if !force, launchState.loadedAt != nil { return }
        launchState = .loading("Reading LaunchAgents and LaunchDaemons…")
        Task {
            if appsState.loadedAt == nil { loadApps() }
            while appsState.isLoading { try? await Task.sleep(nanoseconds: 300_000_000) }
            let catalog = apps.map { ($0.path, $0.name, $0.bundleID?.lowercased() ?? "", $0.executable?.lowercased() ?? "") }
            let matches = await engine { () -> [AppsLaunchMatch] in
                let items = PerformanceScanner.startupItems()
                return items.map { item in
                    let hay = (item.label + " " + item.path + " " + item.program).lowercased()
                    let owner = catalog.first { entry in
                        if item.program.hasPrefix(entry.0 + "/") { return true }
                        if entry.2.count >= 3, hay.contains(entry.2) { return true }
                        if entry.3.count >= 4, item.label.lowercased().contains(entry.3) { return true }
                        return false
                    }
                    return AppsLaunchMatch(item: item, appPath: owner?.0, appName: owner?.1)
                }
            }
            launchItems = matches
            launchState = .loaded(Date())
        }
    }

    func loadUpdates(force: Bool = false) {
        if updatesState.isLoading { return }
        if !force, updatesState.loadedAt != nil { return }
        updatesState = .loading("Asking softwareupdate for pending updates (can take a minute)…")
        Task {
            async let pending = engine { UpdateChecker.pendingSystemUpdates() }
            async let history = engine { AppsScan.updateHistory() }
            updates = await pending
            updateHistory = await history
            updatesState = .loaded(Date())
        }
    }

    // MARK: Running apps (live)

    private func ingest(_ processes: [ProcessSample]) {
        let byPID = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        let list = NSWorkspace.shared.runningApplications.compactMap { app -> AppsRunning? in
            guard app.activationPolicy != .prohibited else { return nil }
            let sample = byPID[app.processIdentifier]
            let arch: String
            switch app.executableArchitecture {
            case NSBundleExecutableArchitectureARM64: arch = "arm64"
            case NSBundleExecutableArchitectureX86_64: arch = "x86_64"
            default: arch = "—"
            }
            return AppsRunning(
                pid: app.processIdentifier,
                name: app.localizedName ?? app.bundleIdentifier ?? "pid \(app.processIdentifier)",
                bundleID: app.bundleIdentifier,
                path: app.bundleURL?.path,
                isActive: app.isActive,
                isHidden: app.isHidden,
                isRegular: app.activationPolicy == .regular,
                launched: app.launchDate,
                arch: arch,
                memory: sample?.memory ?? 0,
                cpu: sample?.cpu ?? 0
            )
        }.sorted { $0.memory > $1.memory }
        running = list
        let regular = list.filter(\.isRegular)
        push(&runningMemoryHistory, Double(regular.reduce(0) { $0 + $1.memory }))
        push(&runningCPUHistory, regular.reduce(0) { $0 + $1.cpu })
        push(&runningCountHistory, Double(regular.count))
        var cpu = pidCPU
        var mem = pidMemory
        let alive = Set(list.map(\.pid))
        for app in list {
            var c = cpu[app.pid] ?? []
            push(&c, app.cpu)
            cpu[app.pid] = c
            var m = mem[app.pid] ?? []
            push(&m, Double(app.memory))
            mem[app.pid] = m
        }
        cpu = cpu.filter { alive.contains($0.key) }
        mem = mem.filter { alive.contains($0.key) }
        pidCPU = cpu
        pidMemory = mem
    }

    private func push(_ array: inout [Double], _ value: Double) {
        array.append(value)
        if array.count > SystemMonitor.historyLength { array.removeFirst(array.count - SystemMonitor.historyLength) }
    }

    func refreshRunning() {
        Task { await SystemMonitor.shared.refreshProcesses() }
    }

    func quit(pid: Int32, force: Bool) {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return }
        let ok = force ? app.forceTerminate() : app.terminate()
        ToastCenter.shared.show(ok ? "\(force ? "Force quit" : "Asked to quit") \(app.localizedName ?? "app")" : "Could not quit \(app.localizedName ?? "app")", error: !ok)
        Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            refreshRunning()
        }
    }

    func quit(appPath: String, force: Bool) {
        for app in NSWorkspace.shared.runningApplications where app.bundleURL?.path == appPath {
            quit(pid: app.processIdentifier, force: force)
        }
    }

    func isRunning(_ path: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleURL?.path == path }
    }

    func launch(_ path: String) {
        let config = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: config) { _, error in
            if let error {
                let message = error.localizedDescription
                Task { @MainActor in ToastCenter.shared.show("Could not open: \(message)", error: true) }
            }
        }
    }

    // MARK: Removal

    /// Mirrors `maclean uninstall --apply --yes --include-caution [--force]`:
    /// refuses while the app is running unless forced, then removes the chosen
    /// artifacts through ArtifactCleaner.
    func uninstall(_ path: String, artifacts: [Artifact], force: Bool) async -> Bool {
        guard let app = app(path) else { return false }
        if !force {
            let runningPS = await engine { AppsScan.isRunningByPS(appPath: path) }
            if runningPS || isRunning(path) {
                ToastCenter.shared.show("\(app.name) is running. Quit it first or enable Force.", error: true)
                return false
            }
        }
        busyPaths.insert(path)
        defer { busyPaths.remove(path) }
        let summary = await EngineActions.cleanArtifacts(artifacts)
        let failedPaths = Set(summary.failures.map(\.path))
        let title = "Uninstall \(app.name)"
        ActivityLog.shared.record("Apps", title, summary, detail: app.bundleID ?? app.path)
        outcomes[path] = AppsUninstallOutcome(
            appName: app.name,
            appPath: path,
            title: title,
            summary: summary,
            removedPaths: artifacts.map(\.path).filter { !failedPaths.contains($0) },
            adminEligible: summary.failures.map(\.path).filter(AppsAdmin.isEligible)
        )
        plans[path] = nil
        planStates[path] = nil
        if !FileManager.default.fileExists(atPath: path) { extraApps[path] = nil }
        refreshAfterRemoval(appRemoved: !FileManager.default.fileExists(atPath: path))
        return true
    }

    func reset(_ path: String, artifacts: [Artifact]) async {
        guard let app = app(path) else { return }
        busyPaths.insert(path)
        defer { busyPaths.remove(path) }
        let summary = await EngineActions.cleanArtifacts(artifacts)
        let title = "Reset \(app.name)"
        ActivityLog.shared.record("Apps", title, summary, detail: app.bundleID ?? app.path)
        lastFailures = summary.failures
        outcomes[path] = AppsUninstallOutcome(
            appName: app.name,
            appPath: path,
            title: title,
            summary: summary,
            removedPaths: artifacts.map(\.path).filter { p in !summary.failures.contains { $0.path == p } },
            adminEligible: summary.failures.map(\.path).filter(AppsAdmin.isEligible)
        )
        plans[path] = nil
        loadPlan(path, force: true)
        if orphansState.loadedAt != nil { loadOrphans(force: true) }
    }

    func bulkUninstall(_ paths: [String]) async -> RemovalSummary {
        var total = RemovalSummary()
        for path in paths {
            guard let app = app(path) else { continue }
            if isRunning(path) {
                total.failures.append((path, "\(app.name) is running — quit it first"))
                continue
            }
            let info = app.appInfo
            let artifacts = await engine { Uninstaller.plan(for: info).filter(\.autoselect) }
            let summary = await EngineActions.cleanArtifacts(artifacts)
            total.removed += summary.removed
            total.bytes += summary.bytes
            total.failures += summary.failures
        }
        ActivityLog.shared.record("Apps", "Uninstall \(paths.count) app\(paths.count == 1 ? "" : "s")", total)
        lastFailures = total.failures
        refreshAfterRemoval(appRemoved: true)
        return total
    }

    func trashExtensions(_ items: [AppsExtension]) async -> RemovalSummary {
        let user = items.filter { !$0.isSystem }
        let sizes = Dictionary(user.map { ($0.path, $0.bytes) }, uniquingKeysWith: { a, _ in a })
        var summary = await EngineActions.trashFiles(user.map(\.path), bytes: sizes)
        for item in items where item.isSystem {
            summary.failures.append((item.path, "installed for all users — needs administrator rights"))
        }
        ActivityLog.shared.record("Apps", "Remove extensions", summary)
        lastFailures = summary.failures
        loadExtensions(force: true)
        return summary
    }

    func trashLaunchItems(_ items: [StartupItem]) async -> RemovalSummary {
        let user = items.filter { $0.path.hasPrefix(AppsScan.home.path + "/") }
        var summary = await EngineActions.trashFiles(user.map(\.path))
        for item in items where !user.contains(item) {
            summary.failures.append((item.path, "system launch item — needs administrator rights"))
        }
        ActivityLog.shared.record("Apps", "Remove launch items", summary, detail: "Takes full effect after logout or restart")
        lastFailures = summary.failures
        loadLaunchItems(force: true)
        return summary
    }

    /// Moves root-owned paths to the Trash behind the macOS administrator prompt.
    func adminRemove(_ paths: [String], outcomeKey: String? = nil) async {
        let eligible = paths.filter(AppsAdmin.isEligible)
        guard !eligible.isEmpty else { return }
        let (ok, output) = await engine { AppsAdmin.moveToTrash(eligible) }
        lastAdminOutput = output
        var summary = RemovalSummary()
        if ok {
            summary.removed = eligible.count
        } else {
            summary.failures = eligible.map { ($0, output) }
        }
        ActivityLog.shared.record("Apps", "Remove system items (admin)", summary, detail: output)
        if let key = outcomeKey, var outcome = outcomes[key] {
            outcome.adminOutput = output
            if ok {
                outcome.removedPaths += eligible
                outcome.adminEligible = []
                outcome.summary.failures.removeAll { eligible.contains($0.path) }
                outcome.summary.removed += eligible.count
            }
            outcomes[key] = outcome
        }
        if extensionsState.loadedAt != nil { loadExtensions(force: true) }
        if launchState.loadedAt != nil { loadLaunchItems(force: true) }
        refreshAfterRemoval(appRemoved: ok)
    }

    private func refreshAfterRemoval(appRemoved: Bool) {
        if appRemoved {
            loadApps(force: true)
        }
        if orphansState.loadedAt != nil { loadOrphans(force: true) }
        if launchState.loadedAt != nil { loadLaunchItems(force: true) }
    }
}
