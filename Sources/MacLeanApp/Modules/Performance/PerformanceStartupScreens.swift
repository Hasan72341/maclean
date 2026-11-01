import AppKit
import MacLeanCore
import SwiftUI

// MARK: - Startup list

enum PerformanceStartupSort: String, CaseIterable, Hashable {
    case name = "Name"
    case location = "Location"
    case status = "Status"
}

struct PerformanceStartupListScreen: View {
    let filter: PerformanceStartupFilter
    @ObservedObject private var store = PerformanceStore.shared
    @EnvironmentObject private var nav: Navigator
    @State private var query = ""
    @State private var sort: PerformanceStartupSort = .location
    @State private var selected: Set<String> = []
    @State private var failures: [(path: String, reason: String)] = []

    private var items: [StartupItem] {
        var list = store.items(filter)
        if !query.isEmpty {
            list = list.filter { $0.label.localizedCaseInsensitiveContains(query) || $0.program.localizedCaseInsensitiveContains(query) || $0.path.localizedCaseInsensitiveContains(query) }
        }
        switch sort {
        case .name: return list.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
        case .location: return list.sorted { ($0.path as NSString).deletingLastPathComponent == ($1.path as NSString).deletingLastPathComponent ? $0.label < $1.label : $0.path < $1.path }
        case .status: return list.sorted { rank($0) > rank($1) }
        }
    }

    private func rank(_ item: StartupItem) -> Int {
        (item.broken ? 4 : 0) + ((store.launchStatus[item.label]?.pid ?? 0) > 0 ? 2 : 0) + (store.launchStatus[item.label] != nil ? 1 : 0)
    }

    private var groups: [(String, [StartupItem])] {
        let list = items
        let dirs = list.map { ($0.path as NSString).deletingLastPathComponent }
        var seen: [String] = []
        for dir in dirs where !seen.contains(dir) { seen.append(dir) }
        return seen.map { dir in (dir, list.filter { ($0.path as NSString).deletingLastPathComponent == dir }) }
    }

    var body: some View {
        let all = store.items(filter)
        ScreenScaffold(filter.title, subtitle: filter.subtitle) {
            RefreshLine(state: store.startupState) { Task { await store.loadStartup() } }
        } content: {
            TileGrid {
                StatTile(label: "Items", value: Format.count(all.count), icon: filter.icon)
                StatTile(label: "Running", value: Format.count(all.filter { (store.launchStatus[$0.label]?.pid ?? 0) > 0 }.count),
                         detail: "live pid in launchctl", tint: Theme.success, icon: "play.circle")
                StatTile(label: "Loaded", value: Format.count(all.filter { store.launchStatus[$0.label] != nil }.count),
                         detail: "in your launchd domain", icon: "checkmark.circle")
                StatTile(label: "Broken", value: Format.count(all.filter(\.broken).count), detail: "program missing",
                         tint: all.contains(where: \.broken) ? Theme.warning : Theme.success, icon: "exclamationmark.triangle")
                StatTile(label: "Need admin", value: Format.count(all.filter { !store.isUserDomain($0) }.count),
                         detail: "system-wide locations", icon: "lock")
            }

            if filter == .all {
                HStack(spacing: 8) {
                    ForEach([PerformanceStartupFilter.userAgents, .globalAgents, .daemons, .running, .broken], id: \.self) { f in
                        Button("\(f.title) (\(store.items(f).count))") { nav.push(.performance(PerformanceStartupFilter.route(f))) }
                            .buttonStyle(EditorialButtonStyle(kind: .secondary))
                    }
                }
            }

            HStack {
                SearchField(text: $query, prompt: "Filter by label, program or path")
                Picker("Sort", selection: $sort) {
                    ForEach(PerformanceStartupSort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 240)
                Spacer()
                Text("\(Format.count(items.count)) shown").font(Type.mono(10)).foregroundStyle(Theme.faint)
            }

            FailureList(failures: failures)

            switch store.startupState {
            case .loading where store.startupItems.isEmpty, .idle:
                LoadingPanel(text: "Reading launchd property lists…")
            case .failed(let message):
                ErrorPanel(message: message) { Task { await store.loadStartup() } }
            default:
                if items.isEmpty {
                    EmptyPanel(icon: "checkmark.seal", title: query.isEmpty ? "Nothing here" : "No matches",
                               message: query.isEmpty ? "No \(filter.title.lowercased()) were found on this Mac." : "Try a different filter.")
                } else {
                    ForEach(groups, id: \.0) { group in
                        Card(Format.abbreviated(group.0), trailing: "\(group.1.count) items") {
                            VStack(spacing: 0) {
                                ForEach(group.1, id: \.path) { item in row(item) }
                            }
                        }
                    }
                }
            }

            if !selected.isEmpty || !items.isEmpty {
                let chosen = store.startupItems.filter { selected.contains($0.path) }
                SelectionBar(selectedCount: chosen.count, totalCount: items.count,
                             selectedBytes: chosen.reduce(0) { $0 + PerformanceStartupListScreen.size($1.path) },
                             actionTitle: "Remove Selected",
                             confirmMessage: "Selected jobs are unloaded from launchd and their plists moved to the Trash. User items go through the engine's ArtifactCleaner; system items (\(chosen.filter { !store.isUserDomain($0) }.count)) need your administrator password.",
                             busy: store.busy,
                             onSelectAll: { selected = Set(items.map(\.path)) },
                             onSelectNone: { selected = [] }) {
                    Task {
                        let summary = await store.remove(chosen)
                        failures = summary.failures
                        selected = []
                    }
                }
            }
        }
        .onAppear { store.loadStartupIfNeeded() }
    }

    static func size(_ path: String) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0
    }

    private func row(_ item: StartupItem) -> some View {
        let status = store.launchStatus[item.label]
        let running = (status?.pid ?? 0) > 0
        let badge: String? = item.broken ? "broken" : running ? "running" : status != nil ? "loaded" : nil
        let tint: Color = item.broken ? Theme.warning : running ? Theme.success : Theme.info
        return CheckRow(
            isOn: Binding(get: { selected.contains(item.path) }, set: { on in
                if on { selected.insert(item.path) } else { selected.remove(item.path) }
            }),
            title: item.label,
            subtitle: "\(item.kind) · \(item.scope)\(item.requiresRoot ? " · root" : "") · \(item.program.isEmpty ? Format.abbreviated(item.path) : Format.abbreviated(item.program))",
            value: running ? "pid \(status?.pid ?? 0)" : nil,
            badge: badge,
            badgeTint: tint,
            onOpen: { nav.push(.performance(.startupItemDetail(item.path))) },
            onReveal: { EngineActions.reveal(item.path) }
        )
    }
}

// MARK: - Startup item detail

struct PerformanceStartupDetailScreen: View {
    let path: String
    @ObservedObject private var store = PerformanceStore.shared
    @EnvironmentObject private var nav: Navigator
    @State private var output: String = ""
    @State private var working = false
    @State private var showRaw = false
    @State private var failures: [(path: String, reason: String)] = []

    var body: some View {
        let item = store.item(path: path)
        let info = store.plistInfo[path]
        let label = info?.label ?? item?.label ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let status = store.launchStatus[label]
        let dump = store.serviceDump[path] ?? ""
        let loaded = status != nil || !dump.isEmpty
        let exists = FileManager.default.fileExists(atPath: path)
        ScreenScaffold(label, subtitle: Format.abbreviated(path)) {
            Button("Reveal") { EngineActions.reveal(path) }.buttonStyle(EditorialButtonStyle(kind: .secondary)).disabled(!exists)
            Button("Reload") { Task { await store.loadPlist(path: path) } }.buttonStyle(EditorialButtonStyle(kind: .ghost))
        } content: {
            TileGrid {
                StatTile(label: "State", value: !exists ? "Removed" : (status?.pid ?? 0) > 0 ? "Running" : loaded ? "Loaded" : "Not loaded",
                         tint: (status?.pid ?? 0) > 0 ? Theme.success : loaded ? Theme.info : Theme.muted, icon: "power")
                StatTile(label: "PID", value: (status?.pid).map { "\($0)" } ?? "—", detail: status?.lastExit.map { "last exit \($0)" }, icon: "number")
                StatTile(label: "Run at load", value: info?.runAtLoad.map { $0 ? "Yes" : "No" } ?? "—", detail: "KeepAlive \(info?.keepAlive ?? "—")", icon: "bolt")
                StatTile(label: "Program", value: item?.broken == true ? "Missing" : "Present",
                         detail: info.map { Format.bytes($0.fileSize) + " plist" },
                         tint: item?.broken == true ? Theme.warning : Theme.success, icon: "terminal")
            }

            if info == nil {
                LoadingPanel(text: "Reading property list and launchd state…")
            }

            Card("Job", trailing: item.map { "\($0.kind) · \($0.scope)" }) {
                KeyValueRow(key: "Label", value: label, mono: true)
                KeyValueRow(key: "Program", value: info?.program.isEmpty == false ? info!.program : (item?.program ?? "—"), mono: true)
                if let args = info?.arguments, args.count > 1 {
                    KeyValueRow(key: "Arguments", value: args.dropFirst().joined(separator: " "), mono: true)
                }
                KeyValueRow(key: "RunAtLoad", value: info?.runAtLoad.map { $0 ? "true" : "false" } ?? "not set")
                KeyValueRow(key: "KeepAlive", value: info?.keepAlive ?? "—")
                if let interval = info?.startInterval { KeyValueRow(key: "StartInterval", value: Format.duration(TimeInterval(interval))) }
                if let cal = info?.calendarInterval { KeyValueRow(key: "StartCalendarInterval", value: cal, mono: true) }
                if let disabled = info?.disabled { KeyValueRow(key: "Disabled key", value: disabled ? "true" : "false") }
                if let bundle = info?.bundleID { KeyValueRow(key: "Associated bundles", value: bundle, mono: true) }
                if let paths = info?.watchPaths, !paths.isEmpty { KeyValueRow(key: "WatchPaths", value: paths.joined(separator: "\n"), mono: true) }
                if let out = info?.stdoutPath { KeyValueRow(key: "Stdout log", value: out, mono: true) }
                if let err = info?.stderrPath { KeyValueRow(key: "Stderr log", value: err, mono: true) }
                KeyValueRow(key: "Domain", value: item.map(store.domainTarget) ?? "—", mono: true)
                KeyValueRow(key: "Modified", value: Format.date(info?.modified))
                KeyValueRow(key: "Requires root", value: item?.requiresRoot == true ? "Yes" : "No")
            }

            if let others = info?.otherKeys, !others.isEmpty {
                Card("Other keys", trailing: "\(others.count)") {
                    ForEach(others, id: \.0) { pair in KeyValueRow(key: pair.0, value: pair.1, mono: true) }
                }
            }

            Card("Actions") {
                HStack(spacing: 10) {
                    if let item {
                        if loaded {
                            ConfirmButton(title: "Disable (unload)", message: "Runs launchctl bootout \(store.domainTarget(item)) on this plist. The file is kept; it may load again at next login unless removed.", kind: .secondary, disabled: working || !exists) {
                                act { await store.disable(item) }
                            }
                        } else {
                            Button("Enable (load)") { act { await store.enable(item) } }
                                .buttonStyle(EditorialButtonStyle(kind: .secondary)).disabled(working || !exists)
                        }
                        ConfirmButton(title: "Remove", message: store.isUserDomain(item)
                                      ? "Unloads the job and moves \(URL(fileURLWithPath: path).lastPathComponent) to the Trash via the engine's ArtifactCleaner."
                                      : "This is a system-wide job. It is unloaded and moved to your Trash as root — macOS will ask for your administrator password.",
                                      kind: .destructive, disabled: working || !exists) {
                            working = true
                            Task {
                                let summary = await store.remove([item])
                                failures = summary.failures
                                working = false
                                if summary.failures.isEmpty { nav.pop() }
                            }
                        }
                    }
                    if let program = info?.program, program.hasPrefix("/"), FileManager.default.fileExists(atPath: program) {
                        Button("Reveal program") { EngineActions.reveal(program) }.buttonStyle(EditorialButtonStyle(kind: .ghost))
                    }
                    if let out = info?.stdoutPath, FileManager.default.fileExists(atPath: out) {
                        Button("Open log") { EngineActions.open(out) }.buttonStyle(EditorialButtonStyle(kind: .ghost))
                    }
                    Spacer()
                    if working { ProgressView().controlSize(.small) }
                }
                if !output.isEmpty {
                    PerformanceOutputPanel(text: output, height: 90)
                }
            }

            FailureList(failures: failures)

            if !dump.isEmpty {
                Card("launchctl print", trailing: "\(dump.split(separator: "\n").count) lines") {
                    PerformanceOutputPanel(text: dump, height: 220)
                }
            }

            if let raw = info?.raw, !raw.isEmpty {
                Card("Property list", trailing: Format.bytes(info?.fileSize ?? 0)) {
                    Button(showRaw ? "Hide XML" : "Show XML") { showRaw.toggle() }.buttonStyle(EditorialButtonStyle(kind: .inline))
                    if showRaw { PerformanceOutputPanel(text: raw, height: 260) }
                }
            }
        }
        .task {
            store.loadStartupIfNeeded()
            await store.loadPlist(path: path)
        }
    }

    private func act(_ work: @escaping @MainActor () async -> ProcessResult) {
        working = true
        Task {
            let result = await work()
            let text = (result.stdout + result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            output = "exit \(result.status)" + (text.isEmpty ? "" : "\n" + text)
            working = false
        }
    }
}

// MARK: - Login items

struct PerformanceLoginItemsScreen: View {
    @ObservedObject private var store = PerformanceStore.shared
    @State private var selected: Set<String> = []
    @State private var query = ""

    private var items: [PerformanceLoginItem] {
        query.isEmpty ? store.loginItems : store.loginItems.filter { $0.name.localizedCaseInsensitiveContains(query) || $0.path.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        ScreenScaffold("Login Items", subtitle: "Apps and helpers that open automatically when you log in") {
            RefreshLine(state: store.loginState) { Task { await store.loadLoginItems() } }
        } content: {
            TileGrid {
                StatTile(label: "Login items", value: Format.count(store.loginItems.count), icon: "person.crop.square")
                StatTile(label: "Hidden", value: Format.count(store.loginItems.filter(\.hidden).count), detail: "launch hidden", icon: "eye.slash")
                StatTile(label: "Missing", value: Format.count(store.loginItems.filter { !$0.exists }.count),
                         detail: "target not found", icon: "questionmark.folder")
                StatTile(label: "Bundled bytes", value: Format.bytes(store.loginItems.reduce(Int64(0)) { $0 + $1.bytes }),
                         detail: "of item targets", icon: "shippingbox")
            }

            Card {
                HStack(spacing: 10) {
                    Image(systemName: "info.circle").foregroundStyle(Theme.info)
                    Text("Read through System Events. Background items registered by apps (SMAppService) are managed in System Settings.")
                        .font(Type.text(11)).foregroundStyle(Theme.muted)
                    Spacer()
                    Button("Open Login Items Settings") {
                        SystemPane.loginItems.open()
                    }
                    .buttonStyle(EditorialButtonStyle(kind: .secondary))
                }
            }

            SearchField(text: $query, prompt: "Filter login items")
            FailureList(failures: store.lastFailures)

            switch store.loginState {
            case .idle, .loading:
                LoadingPanel(text: "Asking System Events…", detail: "macOS may ask you to allow MacLean to control System Events.")
            case .failed(let message):
                ErrorPanel(message: "System Events refused: \(message). Allow MacLean under System Settings › Privacy & Security › Automation.") {
                    Task { await store.loadLoginItems() }
                }
            case .loaded:
                if items.isEmpty {
                    EmptyPanel(icon: "checkmark.seal", title: "No login items", message: "Nothing opens automatically at login.")
                } else {
                    Card(nil) {
                        VStack(spacing: 0) {
                            ForEach(items) { item in
                                CheckRow(isOn: Binding(get: { selected.contains(item.id) }, set: { on in
                                    if on { selected.insert(item.id) } else { selected.remove(item.id) }
                                }), title: item.name, subtitle: item.path.isEmpty ? "path unavailable" : Format.abbreviated(item.path),
                                         value: item.exists ? Format.bytes(item.bytes) : nil,
                                         badge: item.hidden ? "hidden" : (!item.exists ? "missing" : nil),
                                         badgeTint: item.hidden ? Theme.info : Theme.warning,
                                         onReveal: item.path.isEmpty ? nil : { EngineActions.reveal(item.path) })
                            }
                        }
                    }
                }
            }

            if !store.loginItems.isEmpty {
                let chosen = store.loginItems.filter { selected.contains($0.id) }
                SelectionBar(selectedCount: chosen.count, totalCount: items.count, selectedBytes: 0,
                             actionTitle: "Remove from Login Items",
                             confirmMessage: "Removes the selected entries from your login items via System Events. The apps themselves are not deleted.",
                             busy: store.busy,
                             onSelectAll: { selected = Set(items.map(\.id)) },
                             onSelectNone: { selected = [] }) {
                    Task {
                        await store.removeLoginItems(chosen)
                        selected = []
                    }
                }
            }
        }
        .onAppear { store.loadLoginIfNeeded() }
    }
}

// MARK: - Shared output panel

struct PerformanceOutputPanel: View {
    let text: String
    var height: CGFloat = 200

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(text.isEmpty ? "(no output)" : text)
                    .font(Type.mono(10))
                    .foregroundStyle(Theme.ink)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                Color.clear.frame(height: 1).id("end")
            }
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.paper))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.line))
            .onChange(of: text) { _ in proxy.scrollTo("end", anchor: .bottom) }
        }
    }
}
