import AppKit
import MacLeanCore
import SwiftUI

// MARK: - Running apps

struct AppsRunningScreen: View {
    @ObservedObject private var store = AppsStore.shared
    @EnvironmentObject private var nav: Navigator
    @State private var showBackground = false
    @State private var query = ""

    var body: some View {
        let list = store.running.filter { (showBackground || $0.isRegular) && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)) }
        let regular = store.running.filter(\.isRegular)
        let memory = regular.reduce(Int64(0)) { $0 + $1.memory }
        let totalRAM = SystemMonitor.shared.latest.memory.total
        ScreenScaffold("Running Apps", subtitle: "Live from NSWorkspace, memory and CPU from the process sampler (refreshes every 3 s)") {
            Button("Refresh") { store.refreshRunning() }.buttonStyle(EditorialButtonStyle(kind: .ghost))
        } content: {
            TileGrid {
                StatTile(label: "Apps", value: Format.count(regular.count), detail: "\(store.running.count - regular.count) background agents", tint: Theme.info, history: store.runningCountHistory, icon: "app.badge")
                StatTile(label: "App memory", value: Format.bytes(memory), detail: totalRAM > 0 ? Format.percent(Double(memory) / Double(totalRAM)) + " of RAM" : nil, tint: Theme.accent, history: store.runningMemoryHistory, icon: "memorychip")
                StatTile(label: "App CPU", value: String(format: "%.1f%%", regular.reduce(0) { $0 + $1.cpu }), tint: Theme.warning, history: store.runningCPUHistory, icon: "cpu")
                StatTile(label: "Intel (Rosetta)", value: Format.count(store.running.filter { $0.arch == "x86_64" }.count), detail: "translated processes", icon: "cpu.fill")
            }
            Card("Live usage", trailing: "last 2 minutes") {
                LiveChart(series: [.init(values: store.runningMemoryHistory, color: Theme.info, label: "Memory")], format: { Format.bytes(Int64($0)) }, height: 100)
                LiveChart(series: [.init(values: store.runningCPUHistory, color: Theme.accent, label: "CPU %")], format: { String(format: "%.1f%%", $0) }, height: 100)
            }
            if !regular.isEmpty {
                Card("Memory by app", trailing: "top 8") {
                    let top = Array(regular.prefix(8))
                    let peak = Double(top.first?.memory ?? 1)
                    ForEach(top) { app in
                        BarRow(label: app.name, value: Double(app.memory), total: peak, valueText: Format.bytes(app.memory), tint: Theme.info) {
                            if let path = app.path, path.hasSuffix(".app") { nav.push(.apps(.appDetail(path))) }
                        }
                    }
                }
            }
            HStack {
                SearchField(text: $query, prompt: "Filter running apps")
                Toggle("Include background agents", isOn: $showBackground).toggleStyle(.checkbox)
            }
            if list.isEmpty {
                EmptyPanel(icon: "moon", title: "No matching apps running")
            }
            LazyVStack(spacing: 6) {
                ForEach(list) { app in
                    AppsRunningRow(app: app)
                }
            }
        }
        .onAppear { store.refreshRunning() }
    }
}

struct AppsRunningRow: View {
    let app: AppsRunning
    @ObservedObject private var store = AppsStore.shared
    @EnvironmentObject private var nav: Navigator

    var body: some View {
        HStack(spacing: 10) {
            if let path = app.path {
                AppsIcon(path: path, size: 26)
            } else {
                Image(systemName: "app").frame(width: 26, height: 26)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(app.name).font(Type.text(13, weight: .medium)).foregroundStyle(Theme.ink)
                    if app.isActive { RiskBadge(text: "front", tint: Theme.success) }
                    if app.isHidden { RiskBadge(text: "hidden", tint: Theme.muted) }
                    if app.arch == "x86_64" { RiskBadge(text: "Intel", tint: Theme.warning) }
                }
                Text("pid \(app.pid) · \(app.bundleID ?? "—") · up \(app.launched.map { Format.duration(Date().timeIntervalSince($0)) } ?? "—")")
                    .font(Type.mono(10)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            Spacer()
            Sparkline(values: store.pidMemory[app.pid] ?? [], tint: Theme.info).frame(width: 80, height: 20)
            VStack(alignment: .trailing, spacing: 2) {
                Text(Format.bytes(app.memory)).font(Type.mono(12, weight: .semibold)).foregroundStyle(Theme.ink).monospacedDigit()
                Text(String(format: "%.1f%% CPU", app.cpu)).font(Type.mono(10)).foregroundStyle(Theme.muted).monospacedDigit()
            }
            .frame(width: 90, alignment: .trailing)
            Button("Quit") { store.quit(pid: app.pid, force: false) }.buttonStyle(EditorialButtonStyle(kind: .ghost))
            ConfirmButton(title: "Force Quit", message: "Unsaved work in \(app.name) will be lost.", kind: .inlineDanger) {
                store.quit(pid: app.pid, force: true)
            }
            if let path = app.path, path.hasSuffix(".app") {
                Button { nav.push(.apps(.appDetail(path))) } label: { Image(systemName: "chevron.right") }.buttonStyle(.plain).foregroundStyle(Theme.faint)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.canvas))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line, lineWidth: 1))
    }
}

// MARK: - Launch items

struct AppsLoginItemsScreen: View {
    @ObservedObject private var store = AppsStore.shared
    @EnvironmentObject private var nav: Navigator
    @State private var selected: Set<String> = []
    @State private var busy = false
    @State private var summary: RemovalSummary?
    @State private var filter = 0

    var body: some View {
        let all = store.launchItems
        let shown: [AppsLaunchMatch] = {
            switch filter {
            case 1: return all.filter { $0.appPath != nil }
            case 2: return all.filter { $0.appPath == nil }
            case 3: return all.filter(\.item.broken)
            default: return all
            }
        }()
        let chosen = all.filter { selected.contains($0.item.path) }
        ScreenScaffold("Launch Items", subtitle: "LaunchAgents and LaunchDaemons from PerformanceScanner, matched to installed apps") {
            RefreshLine(state: store.launchState) { store.loadLaunchItems(force: true) }
        } content: {
            TileGrid {
                StatTile(label: "Launch items", value: Format.count(all.count), icon: "power")
                StatTile(label: "Belong to apps", value: Format.count(all.filter { $0.appPath != nil }.count), tint: Theme.info, icon: "link")
                StatTile(label: "No installed app", value: Format.count(all.filter { $0.appPath == nil }.count), detail: "possible leftovers", tint: Theme.warning, icon: "questionmark.app")
                StatTile(label: "Broken", value: Format.count(all.filter(\.item.broken).count), detail: "program missing", tint: Theme.danger, icon: "exclamationmark.triangle")
            }
            Picker("Show", selection: $filter) {
                Text("All").tag(0)
                Text("From apps").tag(1)
                Text("Unmatched").tag(2)
                Text("Broken").tag(3)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 460)
            if let summary {
                Card("Last removal", trailing: summary.message) {
                    if !summary.failures.isEmpty { FailureList(failures: summary.failures) }
                }
                AppsAdminPanel(paths: summary.failures.map(\.path))
            }
            AppsStateGate(state: store.launchState, isEmpty: shown.isEmpty, emptyIcon: "power", emptyTitle: "No launch items here", retry: { store.loadLaunchItems(force: true) }) {
                LazyVStack(spacing: 2) {
                    ForEach(shown) { match in
                        CheckRow(
                            isOn: Binding(get: { selected.contains(match.item.path) }, set: { if $0 { selected.insert(match.item.path) } else { selected.remove(match.item.path) } }),
                            title: match.item.label,
                            subtitle: "\(match.item.kind) · \(match.item.scope) · \(match.appName ?? "no installed app") · \(match.item.program.isEmpty ? "—" : Format.abbreviated(match.item.program))",
                            value: match.item.requiresRoot || match.item.scope == "system" ? "admin" : "user",
                            badge: match.item.broken ? "broken" : nil,
                            badgeTint: Theme.danger,
                            onOpen: match.appPath.map { path in { nav.push(.apps(.appDetail(path))) } },
                            onReveal: { EngineActions.reveal(match.item.path) }
                        )
                    }
                }
            }
            Card("Background items in System Settings") {
                Text("Apps registered with SMAppService appear under General › Login Items & Extensions rather than as plist files.")
                    .font(Type.text(12)).foregroundStyle(Theme.muted)
                HStack {
                    Button("Open Login Items Settings") {
                        SystemPane.loginItems.open()
                    }
                    .buttonStyle(EditorialButtonStyle(kind: .secondary))
                    Button("Performance section") { Navigator.shared.go(.performance) }
                        .buttonStyle(EditorialButtonStyle(kind: .ghost))
                }
            }
            SelectionBar(
                selectedCount: chosen.count,
                totalCount: shown.count,
                selectedBytes: 0,
                actionTitle: "Remove Selected",
                confirmMessage: "User launch agents move to the Trash and stop loading at next login. System items are offered for administrator removal afterwards.",
                busy: busy,
                onSelectAll: { selected = Set(shown.map(\.item.path)) },
                onSelectNone: { selected = [] },
                action: {
                    busy = true
                    let items = chosen.map(\.item)
                    Task {
                        summary = await store.trashLaunchItems(items)
                        selected = []
                        busy = false
                    }
                }
            )
        }
        .onAppear { store.loadLaunchItems() }
    }
}

// MARK: - System updates

struct AppsUpdatesScreen: View {
    @ObservedObject private var store = AppsStore.shared

    var body: some View {
        let pending = store.updates.filter { $0.contains("—") }
        let messages = store.updates.filter { !$0.contains("—") }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        ScreenScaffold("System Updates", subtitle: "Pending updates from softwareupdate -l and installation history") {
            RefreshLine(state: store.updatesState) { store.loadUpdates(force: true) }
        } content: {
            TileGrid {
                StatTile(label: "macOS", value: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)", detail: ProcessInfo.processInfo.operatingSystemVersionString, icon: "apple.logo")
                StatTile(label: "Pending", value: store.updatesState.loadedAt == nil ? "…" : Format.count(pending.count), unit: "updates", tint: pending.isEmpty ? Theme.success : Theme.warning, icon: "arrow.down.circle")
                StatTile(label: "Installed history", value: Format.count(store.updateHistory.count), unit: "entries", icon: "clock.arrow.circlepath")
                StatTile(label: "Checked", value: Format.relative(store.updatesState.loadedAt), icon: "checkmark.seal")
            }
            HStack {
                Button("Open Software Update") {
                    SystemPane.softwareUpdate.open()
                }
                .buttonStyle(EditorialButtonStyle(kind: .primary))
                Button("Open App Store Updates") {
                    if let url = URL(string: "macappstore://showUpdatesPage") { NSWorkspace.shared.open(url) }
                }
                .buttonStyle(EditorialButtonStyle(kind: .secondary))
            }
            AppsStateGate(state: store.updatesState, isEmpty: store.updates.isEmpty, retry: { store.loadUpdates(force: true) }) {
                Card("Pending", trailing: "\(pending.count)") {
                    if pending.isEmpty {
                        Text(messages.first ?? "No system updates available.").font(Type.text(12)).foregroundStyle(Theme.success)
                    }
                    ForEach(pending, id: \.self) { line in
                        let label = line.components(separatedBy: " — ").first ?? line
                        VStack(alignment: .leading, spacing: 4) {
                            Text(line).font(Type.text(12, weight: .medium)).foregroundStyle(Theme.ink)
                            AppsCopyBox(title: "Install from Terminal", text: "sudo softwareupdate -i \(AppsAdmin.quote(label))")
                        }
                    }
                    if pending.count > 1 {
                        AppsCopyBox(title: "Install all", text: "sudo softwareupdate -i -a")
                    }
                    if !pending.isEmpty {
                        Text("Updates that need a restart are best installed from System Settings, which schedules the restart for you.")
                            .font(Type.text(11)).foregroundStyle(Theme.faint)
                    }
                }
            }
            if !store.updateHistory.isEmpty {
                Card("Installation history", trailing: "most recent \(min(40, store.updateHistory.count))") {
                    ForEach(Array(store.updateHistory.suffix(40).reversed().enumerated()), id: \.offset) { item in
                        Text(item.element).font(Type.mono(10)).foregroundStyle(Theme.muted).lineLimit(1)
                    }
                }
            }
        }
        .onAppear { store.loadUpdates() }
    }
}
