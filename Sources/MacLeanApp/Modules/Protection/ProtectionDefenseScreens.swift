import AppKit
import MacLeanCore
import SwiftUI

// MARK: - Quarantine

struct ProtectionQuarantineScreen: View {
    @ObservedObject private var store = ProtectionStore.shared
    @EnvironmentObject private var nav: Navigator
    @State private var query = ""
    @State private var selected: Set<String> = []
    @State private var failures: [(path: String, reason: String)] = []
    @State private var working = false

    var body: some View {
        let all = store.quarantine
        let list = query.isEmpty ? all : all.filter {
            $0.record.originalPath.localizedCaseInsensitiveContains(query) || $0.record.reason.localizedCaseInsensitiveContains(query)
        }
        ScreenScaffold("Quarantine", subtitle: Format.abbreviated(QuarantineManager.root.path)) {
            HStack(spacing: 8) {
                RefreshLine(state: store.quarantineState) { Task { await store.loadQuarantine() } }
                Button("Open Folder") {
                    try? FileManager.default.createDirectory(at: QuarantineManager.root, withIntermediateDirectories: true)
                    EngineActions.open(QuarantineManager.root.path)
                }
                .buttonStyle(EditorialButtonStyle(kind: .ghost))
            }
        } content: {
            TileGrid {
                StatTile(label: "Items", value: Format.count(all.count), icon: "archivebox")
                StatTile(label: "Total size", value: Format.bytes(store.quarantineBytes), icon: "externaldrive")
                StatTile(label: "Restorable", value: Format.count(all.filter { $0.present && !$0.originalOccupied }.count),
                         detail: "original location free", tint: Theme.success, icon: "arrow.uturn.backward")
                StatTile(label: "Last 7 days", value: Format.count(all.filter { $0.record.date > Date().addingTimeInterval(-7 * 86_400) }.count), icon: "calendar")
                StatTile(label: "Missing payload", value: Format.count(all.filter { !$0.present }.count),
                         tint: all.contains { !$0.present } ? Theme.warning : Theme.ink, icon: "questionmark.folder")
            }
            if store.quarantineState.isLoading && all.isEmpty {
                LoadingPanel(text: "Reading quarantine records…")
            } else if all.isEmpty {
                EmptyPanel(icon: "archivebox", title: "Quarantine is empty", message: "Files you quarantine from findings or realtime alerts appear here.")
            } else {
                let reasons = Dictionary(grouping: all) { $0.record.reason.components(separatedBy: ":").first ?? $0.record.reason }
                    .map { ($0.key, $0.value.count) }.sorted { $0.1 > $1.1 }
                Card("By reason") {
                    ForEach(reasons.prefix(6), id: \.0) { reason, count in
                        BarRow(label: reason, value: Double(count), total: Double(all.count), valueText: Format.count(count))
                    }
                }
                SearchField(text: $query, prompt: "Filter quarantined items")
                Card("Records", trailing: "\(list.count)") {
                    ForEach(list) { entry in
                        CheckRow(
                            isOn: Binding(get: { selected.contains(entry.id) },
                                          set: { on in if on { selected.insert(entry.id) } else { selected.remove(entry.id) } }),
                            title: URL(fileURLWithPath: entry.record.originalPath).lastPathComponent,
                            subtitle: "\(Format.date(entry.record.date)) · \(entry.record.reason)",
                            value: Format.bytes(entry.bytes),
                            badge: entry.present ? (entry.originalOccupied ? "PATH TAKEN" : nil) : "MISSING",
                            onOpen: { nav.push(.protection(.quarantineRecord(entry.id))) },
                            onReveal: entry.present ? { EngineActions.reveal(entry.record.quarantinedPath) } : nil
                        )
                    }
                }
                FailureList(failures: failures)
                SelectionBar(
                    selectedCount: selected.count, totalCount: all.count,
                    selectedBytes: all.filter { selected.contains($0.id) }.reduce(0) { $0 + $1.bytes },
                    actionTitle: "Delete Permanently",
                    confirmMessage: "Selected quarantined files are deleted permanently and cannot be restored.",
                    busy: working,
                    onSelectAll: { selected = Set(all.map(\.id)) },
                    onSelectNone: { selected = [] }
                ) {
                    let chosen = all.filter { selected.contains($0.id) }
                    working = true
                    Task {
                        failures = await store.deleteQuarantined(chosen).failures
                        selected = []
                        working = false
                    }
                }
            }
        }
        .task { await store.loadQuarantine() }
    }
}

struct ProtectionQuarantineRecordScreen: View {
    let recordID: String
    @ObservedObject private var store = ProtectionStore.shared
    @EnvironmentObject private var nav: Navigator
    @State private var error: String?
    @State private var working = false

    var body: some View {
        if let entry = store.quarantineEntry(recordID) {
            let record = entry.record
            ScreenScaffold(URL(fileURLWithPath: record.originalPath).lastPathComponent, subtitle: record.reason) {
                if entry.present {
                    Button("Reveal") { EngineActions.reveal(record.quarantinedPath) }.buttonStyle(EditorialButtonStyle(kind: .secondary))
                }
            } content: {
                TileGrid {
                    StatTile(label: "Size", value: Format.bytes(entry.bytes), icon: "doc")
                    StatTile(label: "Quarantined", value: Format.relative(record.date), detail: Format.date(record.date), icon: "calendar")
                    StatTile(label: "Payload", value: entry.present ? "Present" : "Missing", tint: entry.present ? Theme.success : Theme.warning, icon: "archivebox")
                    StatTile(label: "Original path", value: entry.originalOccupied ? "Taken" : "Free",
                             tint: entry.originalOccupied ? Theme.warning : Theme.success, icon: "arrow.uturn.backward")
                }
                Card("Record") {
                    KeyValueRow(key: "ID", value: record.id.uuidString, mono: true)
                    KeyValueRow(key: "Original", value: record.originalPath, mono: true)
                    KeyValueRow(key: "Stored at", value: record.quarantinedPath, mono: true)
                    KeyValueRow(key: "Reason", value: record.reason)
                    KeyValueRow(key: "Date", value: Format.date(record.date))
                }
                if let error { ErrorPanel(message: error) }
                Card("Actions") {
                    HStack(spacing: 10) {
                        ConfirmButton(
                            title: "Restore",
                            message: "Move this file back to \(record.originalPath)? It was quarantined as: \(record.reason)",
                            kind: .secondary,
                            disabled: working || !entry.present || entry.originalOccupied
                        ) {
                            working = true
                            Task {
                                error = await store.restore(entry)
                                working = false
                                if error == nil { nav.pop() }
                            }
                        }
                        ConfirmButton(
                            title: "Delete Permanently",
                            message: "Delete \(URL(fileURLWithPath: record.originalPath).lastPathComponent) (\(Format.bytes(entry.bytes))) permanently? This cannot be undone.",
                            kind: .destructive,
                            disabled: working
                        ) {
                            working = true
                            Task {
                                let summary = await store.deleteQuarantined([entry])
                                working = false
                                if summary.failures.isEmpty { nav.pop() } else { error = summary.failures.first?.reason }
                            }
                        }
                        if working { ProgressView().controlSize(.small) }
                    }
                    if entry.originalOccupied {
                        Text("Restore is disabled because a file already exists at the original location.")
                            .font(Type.text(11)).foregroundStyle(Theme.warning)
                    }
                }
            }
        } else {
            ScreenScaffold("Quarantined Item") {
                EmptyPanel(icon: "archivebox", title: "Record not found", message: "It may have been restored or deleted.")
            }
            .task { if store.quarantine.isEmpty { await store.loadQuarantine() } }
        }
    }
}

// MARK: - Realtime

struct ProtectionRealtimeScreen: View {
    @ObservedObject private var store = ProtectionStore.shared
    @ObservedObject private var monitor = ProtectionStore.shared.monitor
    @ObservedObject private var metrics = SystemMonitor.shared
    @State private var installing = false

    var body: some View {
        let status = monitor.status
        let running = status?.running == true
        ScreenScaffold("Realtime Monitor", subtitle: "Background agent watching downloads and persistence folders") {
            Button("Refresh") { Task { await store.refreshRealtime() } }.buttonStyle(EditorialButtonStyle(kind: .ghost))
        } content: {
            TileGrid {
                StatTile(label: "Agent", value: monitor.agentInstalled ? "Installed" : "Not installed",
                         tint: monitor.agentInstalled ? Theme.success : Theme.warning, icon: "shippingbox")
                StatTile(label: "Monitoring", value: running ? "Running" : (status == nil ? "Unreachable" : "Stopped"),
                         tint: running ? Theme.success : Theme.warning, icon: "dot.radiowaves.left.and.right")
                StatTile(label: "Watched folders", value: Format.count(status?.watchedPaths.count ?? 0), icon: "folder")
                StatTile(label: "Alerts", value: Format.count(status?.alertCount ?? store.alerts.count),
                         tint: store.alerts.isEmpty ? Theme.ink : Theme.danger, icon: "bell.badge")
                StatTile(label: "Last check", value: Format.relative(status?.lastScan), detail: Format.date(status?.lastScan), icon: "clock")
                StatTile(label: "Corpus", value: status?.corpusVersion.map { "v\($0)" } ?? "—", icon: "server.rack")
            }
            if let message = monitor.message {
                Text(message).font(Type.text(12)).foregroundStyle(Theme.success)
            }
            if let error = monitor.errorMessage ?? status?.error {
                ErrorPanel(message: error) { Task { await store.refreshRealtime() } }
            }
            Card("Live file activity", trailing: "disk write · read") {
                LiveChart(series: [
                    .init(values: metrics.diskWriteHistory, color: Theme.accent, label: "Write"),
                    .init(values: metrics.diskReadHistory, color: Theme.info, label: "Read", fill: false),
                ], format: { Format.rate($0) }, height: 110)
                HStack {
                    Text("Write \(Format.rate(metrics.latest.disk.writePerSec))").font(Type.mono(11))
                    Spacer()
                    Text("Read \(Format.rate(metrics.latest.disk.readPerSec))").font(Type.mono(11))
                }
                .foregroundStyle(Theme.muted)
            }
            Card("Controls") {
                HStack(spacing: 10) {
                    if !monitor.agentInstalled {
                        ConfirmButton(title: "Install Agent", message: "Write a LaunchAgent to ~/Library/LaunchAgents and start it with launchctl? No administrator rights are needed.", disabled: installing) {
                            installing = true
                            Task { await monitor.installAgent(); installing = false; await store.refreshRealtime() }
                        }
                    } else {
                        if running {
                            ConfirmButton(title: "Stop Monitoring", message: "Stop watching folders for new threats?", kind: .destructive) { monitor.stop() }
                        } else {
                            Button("Start Monitoring") { monitor.start() }.buttonStyle(EditorialButtonStyle(kind: .primary))
                        }
                        Button("Scan Watched Now") { monitor.scanWatched() }
                            .buttonStyle(EditorialButtonStyle(kind: .secondary)).disabled(status?.watchedPaths.isEmpty ?? true)
                        ConfirmButton(title: "Reinstall Agent", message: "Rewrite the LaunchAgent and restart it?", kind: .ghost, disabled: installing) {
                            installing = true
                            Task { await monitor.installAgent(); installing = false; await store.refreshRealtime() }
                        }
                    }
                    if installing { ProgressView().controlSize(.small) }
                }
                KeyValueRow(key: "LaunchAgent", value: Format.abbreviated(MonitorClient.agentPlistURL.path), mono: true)
                KeyValueRow(key: "Mach service", value: MonitorDefaults.machServiceName, mono: true)
            }
            VStack(spacing: 8) {
                NavRow(icon: "folder", title: "Watched folders", value: Format.count(status?.watchedPaths.count ?? 0), route: .protection(.watchedPaths))
                NavRow(icon: "bell.badge", title: "Alerts", value: Format.count(store.alerts.count),
                       tint: store.alerts.isEmpty ? Theme.accent : Theme.danger, route: .protection(.alerts))
                NavRow(icon: "archivebox", title: "Quarantine", value: Format.count(store.quarantine.count), route: .protection(.quarantine))
            }
        }
        .task {
            while !Task.isCancelled {
                await store.refreshRealtime()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }
}

struct ProtectionWatchedPathsScreen: View {
    @ObservedObject private var monitor = ProtectionStore.shared.monitor
    @State private var counts: [String: Int] = [:]

    var body: some View {
        let paths = monitor.status?.watchedPaths ?? []
        ScreenScaffold("Watched Folders", subtitle: "Folders the realtime agent checks for new files") {
            TileGrid {
                StatTile(label: "Folders", value: Format.count(paths.count), icon: "folder")
                StatTile(label: "Present", value: Format.count(counts.count), icon: "checkmark.circle")
                StatTile(label: "Entries", value: Format.count(counts.values.reduce(0, +)), detail: "top-level items", icon: "doc.on.doc")
            }
            if paths.isEmpty {
                EmptyPanel(icon: "folder", title: "No watched folders", message: "Start the realtime monitor to see what it watches.")
            } else {
                Card("Folders") {
                    ForEach(paths, id: \.self) { path in
                        HStack {
                            Image(systemName: counts[path] == nil ? "folder.badge.questionmark" : "folder").foregroundStyle(Theme.accent)
                            Text(Format.abbreviated(path)).font(Type.mono(11)).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(counts[path].map { "\(Format.count($0)) items" } ?? "missing").font(Type.mono(11)).foregroundStyle(Theme.muted)
                            Button("Reveal") { EngineActions.reveal(path) }.buttonStyle(EditorialButtonStyle(kind: .inline))
                        }
                    }
                }
            }
        }
        .task(id: paths) {
            let list = paths
            counts = await engine { () -> [String: Int] in
                var result: [String: Int] = [:]
                for path in list {
                    if let entries = try? FileManager.default.contentsOfDirectory(atPath: path) { result[path] = entries.count }
                }
                return result
            }
        }
    }
}

struct ProtectionAlertsScreen: View {
    @ObservedObject private var store = ProtectionStore.shared
    @ObservedObject private var monitor = ProtectionStore.shared.monitor
    @EnvironmentObject private var nav: Navigator
    @State private var query = ""

    var body: some View {
        let all = store.alerts
        let list = query.isEmpty ? all : all.filter { $0.title.localizedCaseInsensitiveContains(query) || $0.path.localizedCaseInsensitiveContains(query) }
        let days = (0..<14).map { offset -> Double in
            let start = Calendar.current.startOfDay(for: Date().addingTimeInterval(Double(offset - 13) * 86_400))
            let end = start.addingTimeInterval(86_400)
            return Double(all.filter { $0.date >= start && $0.date < end }.count)
        }
        ScreenScaffold("Alerts", subtitle: "Files flagged by the realtime monitor") {
            ConfirmButton(title: "Clear Alerts", message: "Clear all \(all.count) alerts from the monitor? Files are not touched.", kind: .ghost, disabled: all.isEmpty) {
                monitor.clearAlerts()
            }
        } content: {
            TileGrid {
                StatTile(label: "Alerts", value: Format.count(all.count), history: days, icon: "bell.badge")
                ForEach(ProtectionUI.severities, id: \.self) { severity in
                    StatTile(label: severity.rawValue.capitalized, value: Format.count(all.filter { $0.severity == severity }.count),
                             tint: ProtectionUI.tint(severity), icon: "circle.fill")
                }
                StatTile(label: "Today", value: Format.count(Int(days.last ?? 0)), icon: "calendar")
            }
            if all.isEmpty {
                EmptyPanel(icon: "bell.slash", title: "No alerts", message: "When a changed file matches the corpus, it appears here.")
            } else {
                Card("Alerts per day", trailing: "last 14 days") {
                    LiveChart(series: [.init(values: days, color: Theme.danger, label: "Alerts")], capacity: 14, height: 90)
                }
                SearchField(text: $query, prompt: "Filter alerts")
                Card("Alerts", trailing: "\(list.count)") {
                    ForEach(list) { alert in
                        Button { nav.push(.protection(.alertDetail(alert.id.uuidString))) } label: {
                            HStack(spacing: 10) {
                                RiskBadge(text: alert.severity.label, tint: ProtectionUI.tint(alert.severity))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(alert.title).font(Type.text(12, weight: .medium)).foregroundStyle(Theme.ink).lineLimit(1)
                                    Text(Format.abbreviated(alert.path)).font(Type.mono(10)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
                                }
                                Spacer()
                                Text(Format.relative(alert.date)).font(Type.text(11)).foregroundStyle(Theme.muted)
                                Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(Theme.faint)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .task { await store.refreshRealtime() }
    }
}

struct ProtectionAlertDetailScreen: View {
    let alertID: String
    @ObservedObject private var store = ProtectionStore.shared
    @ObservedObject private var monitor = ProtectionStore.shared.monitor
    @State private var error: String?
    @State private var working = false
    @State private var exists = false

    var body: some View {
        if let alert = store.alert(alertID) {
            ScreenScaffold(alert.title, subtitle: alert.kind) {
                HStack(spacing: 8) {
                    if exists { Button("Reveal") { EngineActions.reveal(alert.path) }.buttonStyle(EditorialButtonStyle(kind: .secondary)) }
                    Button("Copy Path") { ProtectionUI.copy(alert.path) }.buttonStyle(EditorialButtonStyle(kind: .ghost))
                }
            } content: {
                TileGrid {
                    StatTile(label: "Severity", value: alert.severity.rawValue.capitalized, tint: ProtectionUI.tint(alert.severity), icon: "exclamationmark.shield")
                    StatTile(label: "Detected", value: Format.relative(alert.date), detail: Format.date(alert.date), icon: "clock")
                    StatTile(label: "File", value: exists ? "Present" : "Gone", tint: exists ? Theme.danger : Theme.success, icon: "doc")
                }
                Card("Alert") {
                    KeyValueRow(key: "ID", value: alert.id.uuidString, mono: true)
                    KeyValueRow(key: "Title", value: alert.title)
                    KeyValueRow(key: "Kind", value: alert.kind)
                    KeyValueRow(key: "Path", value: alert.path, mono: true)
                    if !alert.detail.isEmpty {
                        Text(alert.detail).font(Type.mono(11)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let error { ErrorPanel(message: error) }
                HStack(spacing: 10) {
                    ConfirmButton(title: "Quarantine", message: "Move \(URL(fileURLWithPath: alert.path).lastPathComponent) into quarantine?", kind: .destructive, disabled: !exists || working) {
                        working = true
                        Task {
                            error = await store.quarantinePath(alert.path, reason: "Realtime alert: \(alert.title)")
                            exists = FileManager.default.fileExists(atPath: alert.path)
                            working = false
                        }
                    }
                    if working { ProgressView().controlSize(.small) }
                }
            }
            .task { exists = FileManager.default.fileExists(atPath: alert.path) }
        } else {
            ScreenScaffold("Alert") { EmptyPanel(icon: "bell.slash", title: "Alert no longer present") }
        }
    }
}

// MARK: - YARA rules

struct ProtectionRulesScreen: View {
    @ObservedObject private var store = ProtectionStore.shared
    @EnvironmentObject private var nav: Navigator
    @State private var query = ""
    @State private var sortByRules = true

    var body: some View {
        let files = store.ruleFiles
        var list = query.isEmpty ? files : files.filter { $0.name.localizedCaseInsensitiveContains(query) || $0.rules.contains { $0.localizedCaseInsensitiveContains(query) } }
        list.sort { sortByRules ? $0.rules.count > $1.rules.count : $0.name < $1.name }
        let maxRules = Double(files.map(\.rules.count).max() ?? 1)
        return ScreenScaffold("YARA Rules", subtitle: store.rulesDirectory.map { Format.abbreviated($0) } ?? "Bundled signature base") {
            RefreshLine(state: store.rulesState) { Task { await store.loadRules() } }
        } content: {
            TileGrid {
                StatTile(label: "Rule files", value: Format.count(files.count), icon: "doc.text")
                StatTile(label: "Rules", value: Format.count(store.totalRuleCount), icon: "list.bullet.rectangle")
                StatTile(label: "Size", value: Format.bytes(files.reduce(0) { $0 + $1.bytes }), icon: "externaldrive")
                StatTile(label: "Newest", value: Format.relative(files.compactMap(\.modified).max()), icon: "calendar")
            }
            if case .failed(let message) = store.rulesState {
                ErrorPanel(message: message) { Task { await store.loadRules() } }
            } else if files.isEmpty {
                LoadingPanel(text: "Reading rules…")
            } else {
                HStack {
                    SearchField(text: $query, prompt: "Filter files or rule names")
                    Picker("", selection: $sortByRules) {
                        Text("Most rules").tag(true)
                        Text("Name").tag(false)
                    }
                    .pickerStyle(.segmented).flexibleWidth(200)
                }
                Card("Files", trailing: "\(list.count)") {
                    ForEach(list) { file in
                        BarRow(label: file.name, value: Double(file.rules.count), total: maxRules,
                               valueText: "\(file.rules.count) rules · \(Format.bytes(file.bytes))") {
                            nav.push(.protection(.yaraRuleFile(file.name)))
                        }
                    }
                }
            }
        }
        .task { if store.rulesState == .idle { await store.loadRules() } }
    }
}

struct ProtectionRuleFileScreen: View {
    let name: String
    @ObservedObject private var store = ProtectionStore.shared
    @State private var text = ""

    var body: some View {
        if let file = store.ruleFiles.first(where: { $0.name == name }) {
            ScreenScaffold(file.name, subtitle: Format.abbreviated(file.path)) {
                HStack(spacing: 8) {
                    Button("Reveal") { EngineActions.reveal(file.path) }.buttonStyle(EditorialButtonStyle(kind: .secondary))
                    Button("Copy") { ProtectionUI.copy(text) }.buttonStyle(EditorialButtonStyle(kind: .ghost))
                }
            } content: {
                TileGrid {
                    StatTile(label: "Rules", value: Format.count(file.rules.count), icon: "list.bullet.rectangle")
                    StatTile(label: "Size", value: Format.bytes(file.bytes), icon: "doc")
                    StatTile(label: "Lines", value: Format.count(text.split(separator: "\n", omittingEmptySubsequences: false).count), icon: "text.alignleft")
                    StatTile(label: "Modified", value: Format.relative(file.modified), detail: Format.date(file.modified), icon: "calendar")
                }
                if !file.rules.isEmpty {
                    Card("Rule names", trailing: "\(file.rules.count)") {
                        ForEach(file.rules, id: \.self) { rule in
                            Text(rule).font(Type.mono(11)).foregroundStyle(Theme.ink).textSelection(.enabled)
                        }
                    }
                }
                Card("Source") {
                    ScrollView(.horizontal) {
                        Text(text).font(Type.mono(11)).foregroundStyle(Theme.ink).textSelection(.enabled)
                            .fixedSize(horizontal: true, vertical: true)
                    }
                }
            }
            .task {
                let path = file.path
                text = await engine { () -> String in
                    let data = (try? Data(contentsOf: URL(fileURLWithPath: path))) ?? Data()
                    let slice = data.prefix(400_000)
                    let body = String(data: slice, encoding: .utf8) ?? String(decoding: slice, as: UTF8.self)
                    return data.count > slice.count ? body + "\n… truncated (\(data.count) bytes total)" : body
                }
            }
        } else {
            ScreenScaffold(name) { LoadingPanel(text: "Loading rules…") }
                .task { if store.ruleFiles.isEmpty { await store.loadRules() } }
        }
    }
}

// MARK: - Corpus

struct ProtectionCorpusScreen: View {
    @ObservedObject private var store = ProtectionStore.shared

    var body: some View {
        let status = store.corpus
        let info = status?.info
        ScreenScaffold("Malware Corpus", subtitle: "Panther signature database used by scans and the realtime agent") {
            HStack(spacing: 8) {
                if store.corpusState.isLoading { ProgressView().controlSize(.small) }
                Button("Refresh Now") { Task { await store.loadCorpus(refresh: true) } }
                    .buttonStyle(EditorialButtonStyle(kind: .primary)).disabled(store.corpusState.isLoading)
            }
        } content: {
            TileGrid {
                StatTile(label: "Version", value: info?.version.map { "v\($0)" } ?? "—", detail: info?.updateDate, icon: "server.rack")
                StatTile(label: "Cache age", value: status?.age.map { Format.duration($0) } ?? (status?.cached == true ? "local" : "Not cached"),
                         detail: status.map { $0.isFresh ? "fresh (< 24 h)" : "will refresh on next scan" },
                         tint: status?.isFresh == true ? Theme.success : Theme.warning, icon: "clock")
                StatTile(label: "Database size", value: Format.bytes(status?.cacheBytes ?? 0), icon: "externaldrive")
                StatTile(label: "Total rules", value: Format.count(totalRules(info)), icon: "list.bullet.rectangle")
                StatTile(label: "Scan targets", value: Format.count(info?.scanTargets ?? 0), icon: "scope")
            }
            if case .failed(let message) = store.corpusState { ErrorPanel(message: message) { Task { await store.loadCorpus(refresh: true) } } }
            if let error = status?.infoError { ErrorPanel(message: "Could not open cached corpus: \(error)") }
            Card("Source") {
                TextField("Corpus URL or local path", text: $store.corpusSource)
                    .textFieldStyle(.roundedBorder).font(Type.mono(11))
                    .onSubmit { Task { await store.loadCorpus() } }
                KeyValueRow(key: "Type", value: status?.remote == false ? "Local file" : "Remote (HTTPS)")
                KeyValueRow(key: "Cache file", value: status?.cachePath.map { Format.abbreviated($0) } ?? "—", mono: true)
                KeyValueRow(key: "Downloaded", value: Format.date(status?.meta?.downloadedAt))
                KeyValueRow(key: "ETag", value: status?.meta?.etag ?? "—", mono: true)
                KeyValueRow(key: "Last-Modified", value: status?.meta?.lastModified ?? "—")
                KeyValueRow(key: "SHA-256", value: status?.meta?.sha256 ?? "—", mono: true)
                KeyValueRow(key: "Cache lifetime", value: Format.duration(CorpusFetcher.cacheLifetime))
                HStack {
                    if let path = status?.cachePath, status?.cached == true {
                        Button("Reveal Cache") { EngineActions.reveal(path) }.buttonStyle(EditorialButtonStyle(kind: .secondary))
                    }
                    Button("Reset to Default") { store.corpusSource = MonitorDefaults.corpusURL; Task { await store.loadCorpus() } }
                        .buttonStyle(EditorialButtonStyle(kind: .ghost))
                }
            }
            if let info {
                let rows: [(String, Int)] = [
                    ("Hash", info.hashRules), ("Path", info.pathRules), ("Launch agent", info.launchAgentRules),
                    ("Safari extension", info.safariExtensionRules), ("Chrome extension", info.chromeExtensionRules),
                    ("Homepage", info.homepageRules), ("Profile", info.profileRules), ("Team ID", info.teamIDRules),
                    ("Section hash", info.sectionHashRules), ("YARA", info.yaraRules),
                ]
                let peak = Double(rows.map(\.1).max() ?? 1)
                Card("Rules by type", trailing: Format.count(totalRules(info))) {
                    ForEach(rows, id: \.0) { row in
                        BarRow(label: row.0, value: Double(row.1), total: max(peak, 1), valueText: Format.count(row.1))
                    }
                }
            } else if status?.cached == false {
                EmptyPanel(icon: "icloud.and.arrow.down", title: "Corpus not downloaded yet", message: "Refresh to download it now, or it will download on the next scan.",
                           actionTitle: "Download") { Task { await store.loadCorpus(refresh: true) } }
            }
        }
        .task { if store.corpusState == .idle || store.corpus?.source != store.corpusSource { await store.loadCorpus() } }
    }

    private func totalRules(_ info: CorpusInfo?) -> Int {
        guard let info else { return 0 }
        return info.hashRules + info.pathRules + info.launchAgentRules + info.safariExtensionRules + info.chromeExtensionRules
            + info.homepageRules + info.profileRules + info.teamIDRules + info.sectionHashRules + info.yaraRules
    }
}
