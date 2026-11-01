import AppKit
import MacLeanCore
import SwiftUI

// MARK: - Saved application state

struct PrivacySavedStateScreen: View {
    @ObservedObject private var store = PrivacyStore.shared
    @EnvironmentObject private var nav: Navigator
    @State private var picked: Set<String> = []
    @State private var query = ""
    @State private var sort: PrivacySort = .size

    var body: some View {
        let all = store.savedStates
        var visible = all.filter { query.isEmpty || $0.bundleID.localizedCaseInsensitiveContains(query) || ($0.appName ?? "").localizedCaseInsensitiveContains(query) }
        switch sort {
        case .size: visible.sort { $0.bytes > $1.bytes }
        case .name: visible.sort { ($0.appName ?? $0.bundleID).localizedCaseInsensitiveCompare($1.appName ?? $1.bundleID) == .orderedAscending }
        case .date: visible.sort { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
        }
        let chosen = all.filter { picked.contains($0.path) }
        let total = all.reduce(0) { $0 + $1.bytes }
        return ScreenScaffold("Saved App State", subtitle: "Snapshots macOS keeps to reopen windows, which can include document contents and text you typed.") {
            SearchField(text: $query, prompt: "Filter apps")
        } content: {
            RefreshLine(state: store.savedStateState) { Task { await store.loadSavedStates() } }
            TileGrid(minWidth: 150) {
                StatTile(label: "Apps", value: Format.count(all.count), detail: "\(all.filter { $0.appName == nil }.count) uninstalled", icon: "macwindow.on.rectangle")
                StatTile(label: "Size", value: Format.bytes(total), tint: Theme.accent, icon: "externaldrive")
                StatTile(label: "Files", value: Format.count(all.reduce(0) { $0 + $1.files }), icon: "doc")
                StatTile(label: "Oldest", value: Format.relative(all.compactMap(\.modified).min()), icon: "clock")
            }
            if store.savedStateState.isLoading && all.isEmpty {
                LoadingPanel(text: "Measuring…")
            } else if all.isEmpty {
                EmptyPanel(icon: "checkmark.circle", title: "No saved application state")
            } else {
                Card(nil) {
                    HStack {
                        PrivacySortPicker(sort: $sort)
                        Spacer()
                        Button("Select uninstalled apps") { picked = Set(all.filter { $0.appName == nil }.map(\.path)) }
                            .buttonStyle(EditorialButtonStyle(kind: .inline))
                    }
                    ForEach(visible) { item in
                        CheckRow(
                            isOn: Binding(get: { picked.contains(item.path) }, set: { if $0 { picked.insert(item.path) } else { picked.remove(item.path) } }),
                            title: item.appName ?? item.bundleID,
                            subtitle: "\(item.bundleID) · \(item.files) files · \(Format.relative(item.modified))",
                            value: Format.bytes(item.bytes),
                            badge: item.appName == nil ? "app removed" : nil,
                            badgeTint: Theme.info,
                            onOpen: { nav.push(.privacy(.savedStateDetail(item.path))) },
                            onReveal: { EngineActions.reveal(item.path) }
                        )
                    }
                }
                SelectionBar(
                    selectedCount: chosen.count,
                    totalCount: all.count,
                    selectedBytes: chosen.reduce(0) { $0 + $1.bytes },
                    actionTitle: "Move to Trash",
                    confirmMessage: "Selected apps will reopen without their previous windows. Folders are moved to the Trash.",
                    busy: store.busy,
                    onSelectAll: { picked = Set(visible.map(\.path)) },
                    onSelectNone: { picked = [] },
                    action: {
                        let items = chosen
                        picked = []
                        Task { await store.trashSavedStates(items) }
                    }
                )
            }
        }
        .onAppear { if store.savedStateState == .idle { Task { await store.loadSavedStates() } } }
    }
}

struct PrivacySavedStateDetailScreen: View {
    let path: String
    @ObservedObject private var store = PrivacyStore.shared
    @EnvironmentObject private var nav: Navigator
    @State private var children: [PrivacyChild] = []

    var body: some View {
        let item = store.savedStates.first { $0.path == path }
        ScreenScaffold(item?.appName ?? ((path as NSString).lastPathComponent as NSString).deletingPathExtension, subtitle: Format.abbreviated(path)) {
            Button("Reveal") { EngineActions.reveal(path) }.buttonStyle(EditorialButtonStyle(kind: .secondary))
        } content: {
            if let item {
                TileGrid(minWidth: 150) {
                    StatTile(label: "Size", value: Format.bytes(item.bytes), tint: Theme.accent, icon: "externaldrive")
                    StatTile(label: "Files", value: Format.count(item.files), icon: "doc")
                    StatTile(label: "Modified", value: Format.relative(item.modified), detail: Format.date(item.modified), icon: "clock")
                    StatTile(label: "App", value: item.appName == nil ? "Removed" : "Installed", tint: item.appName == nil ? Theme.info : Theme.ink, icon: "app")
                }
                Card("Contents", trailing: "\(children.count)") {
                    let peak = Double(children.first?.bytes ?? 1)
                    ForEach(Array(children.prefix(60).enumerated()), id: \.offset) { entry in
                        BarRow(label: entry.element.name, value: Double(entry.element.bytes), total: peak, valueText: Format.bytes(entry.element.bytes), tint: Theme.info)
                    }
                }
                ConfirmButton(title: "Move to Trash", message: "\(item.appName ?? item.bundleID) will reopen without its previous windows.", disabled: store.busy) {
                    Task { await store.trashSavedStates([item]) }
                }
            } else {
                EmptyPanel(icon: "checkmark.circle", title: "Removed", message: "This saved state no longer exists.", actionTitle: "Back") { nav.pop() }
            }
        }
        .task(id: path) {
            let target = path
            children = await engine { PrivacyProbe.directoryListing(target).map { PrivacyChild(name: $0.name, bytes: $0.bytes, modified: $0.modified) } }
        }
    }
}

// MARK: - Quarantine events (download history)

struct PrivacyQuarantineScreen: View {
    @ObservedObject private var store = PrivacyStore.shared
    @EnvironmentObject private var nav: Navigator
    @State private var query = ""

    var body: some View {
        let report = store.quarantine
        let events = (report?.events ?? []).filter { query.isEmpty || $0.origin.localizedCaseInsensitiveContains(query) || $0.dataURL.localizedCaseInsensitiveContains(query) || $0.agent.localizedCaseInsensitiveContains(query) }
        ScreenScaffold("Download History", subtitle: "macOS logs the origin of every downloaded file in LaunchServices' QuarantineEventsV2 database.") {
            SearchField(text: $query, prompt: "Filter URLs")
        } content: {
            RefreshLine(state: store.quarantineState) { Task { await store.loadQuarantine() } }
            TileGrid(minWidth: 150) {
                StatTile(label: "Events", value: Format.count(report?.count ?? 0), icon: "arrow.down.circle")
                StatTile(label: "Database", value: Format.bytes(report?.bytes ?? 0), tint: Theme.accent, icon: "cylinder")
                StatTile(label: "Apps", value: "\(report?.agents.count ?? 0)", detail: "that downloaded", icon: "app")
                StatTile(label: "Newest", value: Format.relative(report?.events.first?.date), detail: report?.events.last?.date.map { "oldest shown \(Format.date($0))" }, icon: "clock")
            }
            if let output = store.lastCommand, output.command.contains("LSQuarantineEvent") {
                PrivacyCommandCard(output: output)
            }
            if let report, !report.exists {
                EmptyPanel(icon: "checkmark.circle", title: "No quarantine database", message: Format.abbreviated(report.database))
            } else if let report {
                HStack(alignment: .top, spacing: 16) {
                    Card("By app", trailing: "\(report.agents.count)") {
                        let peak = Double(report.agents.first?.count ?? 1)
                        ForEach(report.agents, id: \.name) { agent in
                            BarRow(label: agent.name, value: Double(agent.count), total: peak, valueText: Format.count(agent.count)) {
                                nav.push(.privacy(.quarantineAgent(agent.name)))
                            }
                        }
                    }
                    Card("Top origins", trailing: "\(report.hosts.count)") {
                        let peak = Double(report.hosts.first?.count ?? 1)
                        ForEach(report.hosts, id: \.name) { host in
                            BarRow(label: host.name, value: Double(host.count), total: peak, valueText: Format.count(host.count), tint: Theme.info)
                        }
                    }
                }
                ConfirmButton(title: "Clear Download History", message: "Deletes all \(Format.count(report.count)) rows from LSQuarantineEvent with sqlite3. Downloaded files and their quarantine flags are not changed.", disabled: report.count == 0 || store.busy) {
                    Task { await store.clearQuarantine() }
                }
                PrivacyQuarantineList(events: Array(events.prefix(150)), title: "Recent downloads")
            } else {
                LoadingPanel(text: "Reading download history…")
            }
        }
        .onAppear { if store.quarantineState == .idle { Task { await store.loadQuarantine() } } }
    }
}

struct PrivacyQuarantineList: View {
    let events: [PrivacyQuarantineEvent]
    let title: String

    var body: some View {
        Card(title, trailing: "\(events.count) shown") {
            if events.isEmpty { Text("No events.").font(Type.text(12)).foregroundStyle(Theme.muted) }
            ForEach(events) { event in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(URL(string: event.dataURL)?.lastPathComponent.removingPercentEncoding ?? (event.dataURL.isEmpty ? "(unnamed)" : event.dataURL))
                            .font(Type.text(12, weight: .medium)).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(Format.date(event.date)).font(Type.mono(10)).foregroundStyle(Theme.muted)
                    }
                    Text("\(event.agent) · \(event.origin.isEmpty ? event.dataURL : event.origin)")
                        .font(Type.mono(10)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
                .padding(.vertical, 3)
            }
        }
    }
}

struct PrivacyQuarantineAgentScreen: View {
    let agent: String
    @ObservedObject private var store = PrivacyStore.shared

    var body: some View {
        let events = (store.quarantine?.events ?? []).filter { $0.agent == agent }
        let total = store.quarantine?.agents.first { $0.name == agent }?.count ?? events.count
        ScreenScaffold(agent, subtitle: "Downloads recorded for this app") {
            TileGrid(minWidth: 150) {
                StatTile(label: "Events", value: Format.count(total), icon: "arrow.down.circle")
                StatTile(label: "In recent 300", value: Format.count(events.count), icon: "list.bullet")
                StatTile(label: "Newest", value: Format.relative(events.first?.date), icon: "clock")
                StatTile(label: "Share", value: Format.percent(Double(total) / Double(max(1, store.quarantine?.count ?? 1))), icon: "chart.pie")
            }
            PrivacyQuarantineList(events: events, title: "Downloads")
        }
    }
}

// MARK: - Shell history

struct PrivacyShellHistoryScreen: View {
    @ObservedObject private var store = PrivacyStore.shared
    @EnvironmentObject private var nav: Navigator
    @State private var picked: Set<String> = []

    var body: some View {
        let files = store.shellFiles.filter(\.exists)
        let missing = store.shellFiles.filter { !$0.exists }
        let chosen = files.filter { picked.contains($0.path) }
        let peak = Double(files.map(\.lines).max() ?? 1)
        ScreenScaffold("Shell History", subtitle: "Commands typed in terminals and REPLs. These can contain tokens and passwords passed on the command line.") {
            EmptyView()
        } content: {
            RefreshLine(state: store.shellState) { Task { await store.loadShell() } }
            TileGrid(minWidth: 150) {
                StatTile(label: "Files", value: "\(files.count)", detail: "of \(store.shellFiles.count) checked", icon: "terminal")
                StatTile(label: "Lines", value: Format.count(files.reduce(0) { $0 + $1.lines }), tint: Theme.accent, icon: "text.alignleft")
                StatTile(label: "Size", value: Format.bytes(files.reduce(0) { $0 + $1.bytes }), icon: "externaldrive")
                StatTile(label: "Last write", value: Format.relative(files.compactMap(\.modified).max()), icon: "clock")
            }
            if files.isEmpty {
                EmptyPanel(icon: "checkmark.circle", title: store.shellState.isLoading ? "Checking…" : "No shell history files")
            } else {
                Card("Lines per file") {
                    ForEach(files) { file in
                        BarRow(label: "\(file.name) · \(file.shell)", value: Double(file.lines), total: peak, valueText: "\(Format.count(file.lines)) lines") {
                            nav.push(.privacy(.shellHistoryFile(file.path)))
                        }
                    }
                }
                Card(nil) {
                    ForEach(files) { file in
                        CheckRow(
                            isOn: Binding(get: { picked.contains(file.path) }, set: { if $0 { picked.insert(file.path) } else { picked.remove(file.path) } }),
                            title: "\(file.name) — \(file.shell)",
                            subtitle: "\(Format.count(file.lines)) lines · modified \(Format.relative(file.modified))",
                            value: Format.bytes(file.bytes),
                            onOpen: { nav.push(.privacy(.shellHistoryFile(file.path))) },
                            onReveal: { EngineActions.reveal(file.path) }
                        )
                    }
                }
                Text("Open shells keep history in memory and write it back on exit. Close terminal windows (or run `history -p` / `fc -p`) after clearing.")
                    .font(Type.text(11)).foregroundStyle(Theme.muted)
                SelectionBar(
                    selectedCount: chosen.count,
                    totalCount: files.count,
                    selectedBytes: chosen.reduce(0) { $0 + $1.bytes },
                    actionTitle: "Clear History",
                    confirmMessage: "Selected files are truncated to zero bytes. This cannot be undone.",
                    busy: store.busy,
                    onSelectAll: { picked = Set(files.map(\.path)) },
                    onSelectNone: { picked = [] },
                    action: {
                        let items = chosen
                        picked = []
                        Task { await store.truncateHistory(items) }
                    }
                )
            }
            if !missing.isEmpty {
                Text("Not present: " + missing.map(\.name).joined(separator: ", "))
                    .font(Type.mono(10)).foregroundStyle(Theme.faint)
            }
        }
        .onAppear { if store.shellState == .idle { Task { await store.loadShell() } } }
    }
}

struct PrivacyShellFileScreen: View {
    let path: String
    @ObservedObject private var store = PrivacyStore.shared
    @EnvironmentObject private var nav: Navigator
    @State private var insight: PrivacyShellInsight?

    var body: some View {
        let file = store.shellFiles.first { $0.path == path }
        ScreenScaffold((path as NSString).lastPathComponent, subtitle: file?.shell) {
            Button("Reveal") { EngineActions.reveal(path) }.buttonStyle(EditorialButtonStyle(kind: .secondary))
        } content: {
            TileGrid(minWidth: 150) {
                StatTile(label: "Lines", value: Format.count(file?.lines ?? 0), tint: Theme.accent, icon: "text.alignleft")
                StatTile(label: "Size", value: Format.bytes(file?.bytes ?? 0), icon: "externaldrive")
                StatTile(label: "Unique commands", value: insight.map { Format.count($0.uniqueCommands) } ?? "…", icon: "number")
                StatTile(label: "Span", value: insight.flatMap { i in i.first.flatMap { f in i.last.map { Format.duration($0.timeIntervalSince(f)) } } } ?? "—", detail: insight.map { "\(Format.count($0.timestamped)) timestamped" }, icon: "calendar")
            }
            if let insight {
                Card("Most used programs", trailing: "top \(insight.topCommands.count)") {
                    let peak = Double(insight.topCommands.first?.count ?? 1)
                    ForEach(insight.topCommands, id: \.name) { entry in
                        BarRow(label: entry.name, value: Double(entry.count), total: peak, valueText: Format.count(entry.count))
                    }
                }
                if let first = insight.first, let last = insight.last {
                    Card("Recorded period") {
                        KeyValueRow(key: "First entry", value: Format.date(first))
                        KeyValueRow(key: "Last entry", value: Format.date(last))
                    }
                }
            } else {
                LoadingPanel(text: "Analysing history…")
            }
            if let file, file.exists {
                ConfirmButton(title: "Clear \(file.name)", message: "Truncates \(Format.abbreviated(file.path)) (\(Format.count(file.lines)) lines) to zero bytes. This cannot be undone.", disabled: store.busy) {
                    Task { await store.truncateHistory([file]) }
                }
            }
        }
        .task(id: file?.bytes ?? -1) {
            let target = path
            insight = await engine { PrivacyProbe.shellInsight(target) }
        }
    }
}

// MARK: - Clipboard

struct PrivacyClipboardScreen: View {
    @ObservedObject private var store = PrivacyStore.shared

    var body: some View {
        let total = store.pasteboardTypes.reduce(0) { $0 + $1.bytes }
        let peak = Double(store.pasteboardTypes.map(\.bytes).max() ?? 1)
        ScreenScaffold("Clipboard", subtitle: "What is on the general pasteboard right now. Any app can read it.") {
            ConfirmButton(title: "Clear Clipboard", message: "Empties the general pasteboard (\(store.pasteboardTypes.count) types, \(Format.bytes(Int64(total)))).", disabled: store.pasteboardTypes.isEmpty) {
                store.clearPasteboard()
            }
        } content: {
            TileGrid(minWidth: 150) {
                StatTile(label: "Types", value: "\(store.pasteboardTypes.count)", icon: "doc.on.clipboard")
                StatTile(label: "Size", value: Format.bytes(Int64(total)), tint: Theme.accent, history: store.pasteboardHistory.count > 1 ? store.pasteboardHistory : nil, icon: "externaldrive")
                StatTile(label: "Change count", value: Format.count(store.pasteboardChangeCount), icon: "number")
                StatTile(label: "Changes seen", value: Format.count(store.pasteboardChanges), detail: "since MacLean opened", icon: "waveform.path.ecg")
            }
            Card("Clipboard size (live)", trailing: "1 s samples") {
                LiveChart(series: [LiveChart.Series(values: store.pasteboardHistory, color: Theme.info, label: "Bytes")], format: { Format.bytes(Int64($0)) }, height: 110)
            }
            if store.pasteboardTypes.isEmpty {
                EmptyPanel(icon: "clipboard", title: "Clipboard is empty")
            } else {
                Card("Types", trailing: "\(store.pasteboardTypes.count)") {
                    ForEach(store.pasteboardTypes) { type in
                        BarRow(label: type.type, value: Double(type.bytes), total: peak, valueText: Format.bytes(Int64(type.bytes)), tint: Theme.info)
                    }
                }
                if let preview = store.pasteboardPreview {
                    Card("Text preview", trailing: "first 280 characters") {
                        Text(preview).font(Type.mono(11)).foregroundStyle(Theme.ink).textSelection(.enabled)
                    }
                }
            }
        }
        .onAppear { store.startLive() }
    }
}

// MARK: - Wi-Fi

struct PrivacyWifiScreen: View {
    @ObservedObject private var store = PrivacyStore.shared
    @State private var picked: Set<String> = []
    @State private var query = ""

    var body: some View {
        let report = store.wifi
        let networks = (report?.networks ?? []).filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }
        let chosen = (report?.networks ?? []).filter { picked.contains($0) }
        ScreenScaffold("Wi-Fi Networks", subtitle: "Networks this Mac rejoins automatically. Their names reveal places you have been.") {
            SearchField(text: $query, prompt: "Filter networks")
        } content: {
            RefreshLine(state: store.wifiState) { Task { await store.loadWifi() } }
            TileGrid(minWidth: 150) {
                StatTile(label: "Remembered", value: "\(report?.networks.count ?? 0)", icon: "wifi")
                StatTile(label: "Connected to", value: report?.current ?? "—", icon: "antenna.radiowaves.left.and.right")
                StatTile(label: "Interface", value: report?.device ?? "—", icon: "network")
                StatTile(label: "Selected", value: "\(chosen.count)", icon: "checkmark.square")
            }
            if let output = store.lastCommand, output.command.contains("removepreferredwirelessnetwork") {
                PrivacyCommandCard(output: output)
            }
            if let report, report.device == nil {
                EmptyPanel(icon: "wifi.slash", title: "No Wi-Fi interface", message: report.error)
            } else if let report {
                if let error = report.error { ErrorPanel(message: error) { Task { await store.loadWifi() } } }
                Card(nil) {
                    if networks.isEmpty { Text("No remembered networks.").font(Type.text(12)).foregroundStyle(Theme.muted) }
                    ForEach(Array(networks.enumerated()), id: \.offset) { entry in
                        let name = entry.element
                        CheckRow(
                            isOn: Binding(get: { picked.contains(name) }, set: { if $0 { picked.insert(name) } else { picked.remove(name) } }),
                            title: name,
                            subtitle: "priority #\(entry.offset + 1)",
                            badge: name == report.current ? "connected" : nil,
                            badgeTint: Theme.success
                        )
                    }
                }
                if !chosen.isEmpty, let device = report.device {
                    Card("Equivalent Terminal command") {
                        PrivacyCopyBlock(text: PrivacyProbe.removeWifiCommand(device: device, names: chosen))
                    }
                }
                SelectionBar(
                    selectedCount: chosen.count,
                    totalCount: report.networks.count,
                    selectedBytes: 0,
                    actionTitle: "Forget Networks",
                    confirmMessage: "macOS will ask for an administrator password. Forgotten networks need their password again to rejoin.",
                    busy: store.busy,
                    onSelectAll: { picked = Set(networks) },
                    onSelectNone: { picked = [] },
                    action: {
                        let names = chosen
                        picked = []
                        Task { await store.removeWifi(names) }
                    }
                )
            } else {
                LoadingPanel(text: "Querying networksetup…")
            }
        }
        .onAppear { if store.wifiState == .idle { Task { await store.loadWifi() } } }
    }
}

// MARK: - Quick Look cache

struct PrivacyQuickLookScreen: View {
    @ObservedObject private var store = PrivacyStore.shared

    var body: some View {
        let report = store.quickLook
        ScreenScaffold("Quick Look Cache", subtitle: "Thumbnails of files you previewed stay cached even after the files are deleted.") {
            ConfirmButton(title: "Reset Cache", message: "Runs qlmanage -r cache. Thumbnails are regenerated on demand.", disabled: store.busy) {
                Task { await store.resetQuickLook() }
            }
        } content: {
            RefreshLine(state: store.quickLookState) { Task { await store.loadQuickLook() } }
            TileGrid(minWidth: 150) {
                StatTile(label: "Cache size", value: Format.bytes(report?.bytes ?? 0), tint: Theme.accent, icon: "photo.stack")
                StatTile(label: "Files", value: Format.count(report?.files ?? 0), icon: "doc")
                StatTile(label: "Modified", value: Format.relative(report?.modified), icon: "clock")
                StatTile(label: "Generators", value: "\(report?.generators ?? 0)", detail: "qlmanage -m plugins", icon: "puzzlepiece.extension")
            }
            if let output = store.lastCommand, output.command.hasPrefix("qlmanage") {
                PrivacyCommandCard(output: output)
            }
            Card("Location") {
                if let path = report?.path {
                    KeyValueRow(key: "Cache folder", value: path, mono: true)
                    Button("Reveal in Finder") { EngineActions.reveal(path) }.buttonStyle(EditorialButtonStyle(kind: .inline))
                } else {
                    Text(store.quickLookState.isLoading ? "Measuring…" : "No thumbnail cache folder found in DARWIN_USER_CACHE_DIR (it may be protected or empty).")
                        .font(Type.text(12)).foregroundStyle(Theme.muted)
                }
            }
        }
        .onAppear { if store.quickLookState == .idle { Task { await store.loadQuickLook() } } }
    }
}

// MARK: - Results

struct PrivacyResultScreen: View {
    @ObservedObject private var store = PrivacyStore.shared
    @EnvironmentObject private var nav: Navigator

    var body: some View {
        ScreenScaffold("Clean Result", subtitle: store.lastResult.map { "\($0.title) · \(Format.date($0.date))" }) {
            Button("Privacy Overview") { nav.popToRoot() }.buttonStyle(EditorialButtonStyle(kind: .secondary))
        } content: {
            if let result = store.lastResult {
                TileGrid(minWidth: 150) {
                    StatTile(label: "Cleaned", value: Format.count(result.removed), tint: Theme.success, icon: "checkmark.circle")
                    StatTile(label: "Freed", value: Format.bytes(result.bytes), tint: Theme.accent, icon: "externaldrive")
                    StatTile(label: "Failed", value: Format.count(result.failures.count), tint: result.failures.isEmpty ? Theme.ink : Theme.danger, icon: "exclamationmark.triangle")
                    StatTile(label: "Remaining traces", value: Format.count(store.artifacts.count), detail: Format.bytes(store.totalBytes), icon: "hand.raised")
                }
                Card("Summary") {
                    KeyValueRow(key: "Action", value: result.title)
                    KeyValueRow(key: "When", value: Format.date(result.date))
                    if !result.detail.isEmpty { KeyValueRow(key: "Details", value: result.detail) }
                    KeyValueRow(key: "Destination", value: store.permanent ? "Deleted permanently" : "Trash (where applicable)")
                }
                FailureList(failures: result.failures.map { ($0.path, $0.reason) })
                if result.failures.contains(where: { $0.reason.localizedCaseInsensitiveContains("permission") || $0.reason.localizedCaseInsensitiveContains("operation not permitted") }) {
                    Card("Why some items failed") {
                        Text("Safari and some system lists are protected. Grant MacLean Full Disk Access and try again.")
                            .font(Type.text(12)).foregroundStyle(Theme.muted)
                        Button("Open Full Disk Access Settings") {
                            SystemPane.privacy(.fullDiskAccess).open()
                        }
                        .buttonStyle(EditorialButtonStyle(kind: .secondary))
                    }
                }
                if let command = store.lastCommand {
                    NavRow(icon: "terminal", title: "Last command output", subtitle: command.title, value: "exit \(command.status)", route: .privacy(.commandOutput))
                }
            } else {
                EmptyPanel(icon: "tray", title: "Nothing cleaned yet", message: "Results of privacy cleaning appear here.", actionTitle: "Back to overview") { nav.popToRoot() }
            }
        }
    }
}

struct PrivacyCommandOutputScreen: View {
    @ObservedObject private var store = PrivacyStore.shared

    var body: some View {
        ScreenScaffold("Command Output") {
            if let output = store.lastCommand {
                PrivacyCommandCard(output: output)
            } else {
                EmptyPanel(icon: "terminal", title: "No command has run yet")
            }
        }
    }
}
