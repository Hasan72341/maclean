import AppKit
import MacLeanCore
import SwiftUI

// MARK: - History

struct SettingsHistoryScreen: View {
    @ObservedObject private var log = ActivityLog.shared
    @ObservedObject private var store = SettingsStore.shared
    @State private var query = ""
    @State private var module = "All"
    @State private var sort = "Newest"
    @State private var failuresOnly = false

    private var modules: [String] { ["All"] + Array(Set(log.entries.map(\.module))).sorted() }

    private var filtered: [ActivityEntry] {
        var list = log.entries.filter { entry in
            (module == "All" || entry.module == module)
                && (!failuresOnly || entry.failures > 0)
                && (query.isEmpty || entry.title.localizedCaseInsensitiveContains(query) || entry.module.localizedCaseInsensitiveContains(query) || entry.detail.localizedCaseInsensitiveContains(query))
        }
        switch sort {
        case "Oldest": list.sort { $0.date < $1.date }
        case "Largest": list.sort { $0.bytes > $1.bytes }
        case "Most items": list.sort { $0.items > $1.items }
        default: list.sort { $0.date > $1.date }
        }
        return list
    }

    var body: some View {
        let list = filtered
        ScreenScaffold("History", subtitle: "Every clean recorded by MacLean") {
            Button("Export JSON") { SettingsStore.save(text: SettingsStore.historyJSON(list), suggestedName: "maclean-history.json") }
                .disabled(list.isEmpty)
        } content: {
            TileGrid {
                StatTile(label: "Entries", value: Format.count(list.count), detail: "of \(Format.count(log.entries.count)) total", icon: "list.bullet")
                StatTile(label: "Freed", value: Format.bytes(list.reduce(0) { $0 + $1.bytes }), tint: Theme.success, icon: "arrow.down.circle")
                StatTile(label: "Items", value: Format.count(list.reduce(0) { $0 + $1.items }), icon: "doc.on.doc")
                StatTile(label: "Failures", value: Format.count(list.reduce(0) { $0 + $1.failures }), tint: Theme.danger, icon: "exclamationmark.triangle")
                StatTile(label: "Last run", value: Format.relative(log.entries.first?.date), icon: "clock")
            }

            HStack(spacing: 12) {
                SearchField(text: $query, prompt: "Search title, module or paths")
                EditorialPicker(label: "Module", selection: $module, options: modules) { $0 }
                EditorialPicker(label: "Sort", selection: $sort, options: ["Newest", "Oldest", "Largest", "Most items"]) { $0 }
                Toggle("Failures only", isOn: $failuresOnly).toggleStyle(EditorialToggleStyle())
            }

            if log.entries.isEmpty {
                EmptyPanel(icon: "clock.arrow.circlepath", title: "No history yet", message: "Cleans you run in any module appear here with what was freed.", actionTitle: "Go to Cleanup") { Navigator.shared.go(.cleanup) }
            } else if list.isEmpty {
                EmptyPanel(icon: "magnifyingglass", title: "No entries match", actionTitle: "Reset filters") {
                    query = ""; module = "All"; failuresOnly = false
                }
            } else {
                VStack(spacing: 8) {
                    ForEach(list.prefix(300)) { entry in
                        NavRow(icon: SettingsHistoryScreen.icon(entry.module), title: entry.title,
                               subtitle: "\(entry.module) · \(Format.date(entry.date)) · \(Format.count(entry.items)) items\(entry.failures > 0 ? " · \(entry.failures) failed" : "")",
                               value: Format.bytes(entry.bytes),
                               tint: entry.failures > 0 ? Theme.warning : Theme.accent,
                               route: .settings(.historyEntry(entry.id.uuidString)))
                    }
                    if list.count > 300 {
                        Text("Showing 300 of \(Format.count(list.count)). Narrow the search to see more.").font(Type.text(11)).foregroundStyle(Theme.muted)
                    }
                }
                HStack {
                    NavRow(icon: "chart.bar.xaxis", title: "Statistics", subtitle: "Charts for this history", route: .settings(.statistics))
                    ConfirmButton(title: "Clear History", message: "Deletes all \(log.entries.count) history entries. Freed files are not affected.", kind: .destructive) {
                        store.clearHistory()
                    }
                }
            }
        }
    }

    static func icon(_ module: String) -> String {
        switch module.lowercased() {
        case let m where m.contains("clean"): return "archivebox"
        case let m where m.contains("app"): return "square.stack.3d.up"
        case let m where m.contains("privacy"): return "hand.raised"
        case let m where m.contains("perf"): return "speedometer"
        case let m where m.contains("space"): return "internaldrive"
        case let m where m.contains("protect"): return "shield.lefthalf.filled"
        case let m where m.contains("setting"): return "gearshape"
        default: return "clock"
        }
    }
}

struct SettingsHistoryEntryScreen: View {
    let entryID: String
    @ObservedObject private var log = ActivityLog.shared

    var body: some View {
        let entry = log.entries.first { $0.id.uuidString == entryID }
        ScreenScaffold(entry?.title ?? "History Entry", subtitle: entry.map { "\($0.module) · \(Format.date($0.date))" }) {
            if let entry {
                Button("Copy") { SettingsStore.copy(Self.text(entry)) }
            }
        } content: {
            if let entry {
                let paths = entry.detail.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
                TileGrid {
                    StatTile(label: "Freed", value: Format.bytes(entry.bytes), tint: Theme.success, icon: "arrow.down.circle")
                    StatTile(label: "Items", value: Format.count(entry.items), icon: "doc.on.doc")
                    StatTile(label: "Failures", value: Format.count(entry.failures), tint: entry.failures > 0 ? Theme.danger : Theme.ink, icon: "exclamationmark.triangle")
                    StatTile(label: "When", value: Format.relative(entry.date), detail: Format.date(entry.date), icon: "clock")
                }
                Card("Details") {
                    VStack(spacing: 0) {
                        KeyValueRow(key: "Module", value: entry.module)
                        KeyValueRow(key: "Action", value: entry.title)
                        KeyValueRow(key: "Date", value: entry.date.formatted(date: .complete, time: .standard))
                        KeyValueRow(key: "Bytes", value: "\(CountFormat.string(entry.bytes)) bytes", mono: true)
                        KeyValueRow(key: "Average per item", value: entry.items > 0 ? Format.bytes(entry.bytes / Int64(entry.items)) : "—")
                        KeyValueRow(key: "Success rate", value: entry.items + entry.failures > 0 ? Format.percent(Double(entry.items) / Double(entry.items + entry.failures), digits: 1) : "—")
                        KeyValueRow(key: "Entry ID", value: entry.id.uuidString, mono: true)
                    }
                }
                if !paths.isEmpty {
                    Card("Recorded detail", trailing: "\(paths.count) lines") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(paths.prefix(400).enumerated()), id: \.offset) { item in
                                let expanded = (item.element as NSString).expandingTildeInPath
                                HStack {
                                    Text(item.element).font(Type.mono(11)).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                                    Spacer()
                                    if FileManager.default.fileExists(atPath: expanded) {
                                        Button("Reveal") { EngineActions.reveal(expanded) }.buttonStyle(EditorialButtonStyle(kind: .inline))
                                    }
                                }
                            }
                        }
                    }
                }
                HStack(spacing: 10) {
                    NavRow(icon: "line.3.horizontal.decrease", title: "All \(entry.module) statistics", route: .settings(.statisticsModule(entry.module)))
                    Button("Open Trash") { EngineActions.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash").path) }
                }
            } else {
                EmptyPanel(icon: "questionmark.folder", title: "Entry not found", message: "It may have been cleared from history.")
            }
        }
    }

    static func text(_ entry: ActivityEntry) -> String {
        """
        \(entry.title) [\(entry.module)]
        \(Format.date(entry.date))
        Freed: \(Format.bytes(entry.bytes)) · Items: \(entry.items) · Failures: \(entry.failures)
        \(entry.detail)
        """
    }
}

// MARK: - Statistics

struct SettingsDailyBars: View {
    let days: [(Date, Int64, Int)]
    var tint: Color = Theme.accent
    @State private var hover: Int?

    var body: some View {
        let peak = max(1, days.map(\.1).max() ?? 1)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if let hover, days.indices.contains(hover) {
                    Text("\(days[hover].0.formatted(date: .abbreviated, time: .omitted)): \(Format.bytes(days[hover].1)) in \(days[hover].2) run\(days[hover].2 == 1 ? "" : "s")")
                } else {
                    Text("Peak \(Format.bytes(peak)) · total \(Format.bytes(days.reduce(0) { $0 + $1.1 }))")
                }
                Spacer()
            }
            .font(Type.mono(11)).foregroundStyle(Theme.muted)
            GeometryReader { geo in
                Canvas { context, size in
                    let count = max(1, days.count)
                    let slot = size.width / CGFloat(count)
                    let barWidth = max(2, slot * 0.7)
                    for line in 1...3 {
                        let y = size.height * CGFloat(line) / 4
                        var path = Path()
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: size.width, y: y))
                        context.stroke(path, with: .color(Theme.line), lineWidth: 0.5)
                    }
                    for (index, day) in days.enumerated() {
                        let h = day.1 > 0 ? max(2, size.height * CGFloat(Double(day.1) / Double(peak))) : 1
                        let rect = CGRect(x: CGFloat(index) * slot + (slot - barWidth) / 2, y: size.height - h, width: barWidth, height: h)
                        let color = index == hover ? Theme.ink : (day.1 > 0 ? tint : Theme.line)
                        context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(color))
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point):
                        let slot = geo.size.width / CGFloat(max(1, days.count))
                        hover = min(days.count - 1, max(0, Int(point.x / slot)))
                    case .ended:
                        hover = nil
                    }
                }
            }
            .frame(height: 140)
            HStack {
                Text(days.first?.0.formatted(date: .abbreviated, time: .omitted) ?? "")
                Spacer()
                Text("Today")
            }
            .font(Type.text(10)).foregroundStyle(Theme.faint)
        }
    }
}

struct SettingsStatisticsScreen: View {
    @ObservedObject private var log = ActivityLog.shared
    @State private var range = 30

    var body: some View {
        let entries = log.entries
        let modules = SettingsStats.byModule(entries)
        let days = SettingsStats.daily(entries, days: range)
        let total = entries.reduce(Int64(0)) { $0 + $1.bytes }
        let items = entries.reduce(0) { $0 + $1.items }
        let failures = entries.reduce(0) { $0 + $1.failures }
        let windowBytes = days.reduce(Int64(0)) { $0 + $1.1 }
        ScreenScaffold("Statistics", subtitle: "What MacLean has freed over time") {
            EditorialPicker(label: "Range", selection: $range, options: [7, 30, 90]) { "\($0) days" }
        } content: {
            TileGrid {
                StatTile(label: "Total freed", value: Format.bytes(total), tint: Theme.success, icon: "arrow.down.circle")
                StatTile(label: "Last \(range) days", value: Format.bytes(windowBytes), detail: "avg \(Format.bytes(windowBytes / Int64(range)))/day", history: days.map { Double($0.1) }, icon: "calendar")
                StatTile(label: "Items cleaned", value: Format.count(items), icon: "doc.on.doc")
                StatTile(label: "Failures", value: Format.count(failures), detail: items + failures > 0 ? Format.percent(Double(failures) / Double(items + failures), digits: 1) + " failure rate" : nil, tint: failures > 0 ? Theme.danger : Theme.ink, icon: "exclamationmark.triangle")
                StatTile(label: "Runs", value: Format.count(entries.count), detail: "\(modules.count) modules", icon: "play.circle")
            }

            if entries.isEmpty {
                EmptyPanel(icon: "chart.bar.xaxis", title: "No statistics yet", message: "Run a clean in any module to start collecting numbers.", actionTitle: "Go to Cleanup") { Navigator.shared.go(.cleanup) }
            } else {
                Card("Freed per day", trailing: "last \(range) days") {
                    SettingsDailyBars(days: days)
                }
                Card("Freed per module", trailing: "\(modules.count) modules") {
                    if total > 0 {
                        StackedBar(segments: modules.enumerated().map { index, stat in
                            .init(label: stat.module, value: Double(stat.bytes), color: SettingsStatisticsScreen.palette[index % SettingsStatisticsScreen.palette.count], text: Format.bytes(stat.bytes))
                        })
                    }
                    VStack(spacing: 6) {
                        ForEach(Array(modules.enumerated()), id: \.element.id) { index, stat in
                            BarRow(label: "\(stat.module) · \(stat.runs) runs", value: Double(stat.bytes), total: Double(max(1, modules.first?.bytes ?? 1)),
                                   valueText: Format.bytes(stat.bytes), tint: SettingsStatisticsScreen.palette[index % SettingsStatisticsScreen.palette.count]) {
                                Navigator.shared.push(.settings(.statisticsModule(stat.module)))
                            }
                        }
                    }
                }
                Card("Items and failures per module") {
                    VStack(spacing: 0) {
                        ForEach(modules) { stat in
                            KeyValueRow(key: stat.module, value: "\(Format.count(stat.items)) items · \(Format.count(stat.failures)) failed", mono: true)
                        }
                    }
                }
                NavRow(icon: "clock.arrow.circlepath", title: "Full history", value: Format.count(entries.count), route: .settings(.history))
            }
        }
    }

    static let palette: [Color] = [Theme.accent, Theme.info, Theme.success, Theme.warning, Theme.danger, Theme.muted]
}

struct SettingsStatisticsModuleScreen: View {
    let module: String
    @ObservedObject private var log = ActivityLog.shared

    var body: some View {
        let entries = log.entries.filter { $0.module == module }
        let titles = SettingsStats.byTitle(entries)
        let total = entries.reduce(Int64(0)) { $0 + $1.bytes }
        ScreenScaffold(module, subtitle: "Statistics for this module") {
            TileGrid {
                StatTile(label: "Freed", value: Format.bytes(total), tint: Theme.success, icon: "arrow.down.circle")
                StatTile(label: "Runs", value: Format.count(entries.count), icon: "play.circle")
                StatTile(label: "Items", value: Format.count(entries.reduce(0) { $0 + $1.items }), icon: "doc.on.doc")
                StatTile(label: "Failures", value: Format.count(entries.reduce(0) { $0 + $1.failures }), tint: Theme.danger, icon: "exclamationmark.triangle")
                StatTile(label: "Largest run", value: Format.bytes(entries.map(\.bytes).max() ?? 0), icon: "arrow.up.circle")
            }
            if entries.isEmpty {
                EmptyPanel(icon: "chart.bar", title: "No runs recorded for \(module)")
            } else {
                Card("Freed per day", trailing: "last 30 days") {
                    SettingsDailyBars(days: SettingsStats.daily(entries), tint: Theme.info)
                }
                Card("By action") {
                    VStack(spacing: 6) {
                        ForEach(titles) { stat in
                            BarRow(label: "\(stat.module) · \(stat.runs)×", value: Double(stat.bytes), total: Double(max(1, titles.first?.bytes ?? 1)), valueText: Format.bytes(stat.bytes))
                        }
                    }
                }
                Card("Runs") {
                    VStack(spacing: 8) {
                        ForEach(entries.prefix(100)) { entry in
                            NavRow(icon: "clock", title: entry.title, subtitle: Format.date(entry.date), value: Format.bytes(entry.bytes), route: .settings(.historyEntry(entry.id.uuidString)))
                        }
                    }
                }
            }
        }
    }
}

// MARK: - App data

struct SettingsAppDataScreen: View {
    @ObservedObject private var store = SettingsStore.shared
    @ObservedObject private var log = ActivityLog.shared
    @State private var selected: Set<String> = []

    var body: some View {
        let entries = store.appDataEntries
        let total = entries.reduce(Int64(0)) { $0 + $1.bytes }
        let selectedBytes = entries.filter { selected.contains($0.path) }.reduce(Int64(0)) { $0 + $1.bytes }
        ScreenScaffold("App Data", subtitle: Format.abbreviated(SettingsStore.appSupport.path)) {
            RefreshLine(state: store.appDataState) { Task { await store.loadAppData() } }
        } content: {
            TileGrid {
                StatTile(label: "Total size", value: Format.bytes(total), icon: "folder")
                StatTile(label: "Entries", value: Format.count(entries.count), detail: "\(Format.count(entries.reduce(0) { $0 + $1.files })) files", icon: "doc.on.doc")
                StatTile(label: "History", value: Format.count(log.entries.count), detail: "activity.json", icon: "clock.arrow.circlepath")
                StatTile(label: "Largest", value: entries.first.map { Format.bytes($0.bytes) } ?? "—", detail: entries.first?.name, icon: "arrow.up.circle")
            }

            HStack(spacing: 10) {
                Button("Reveal in Finder") {
                    let path = SettingsStore.appSupport.path
                    if FileManager.default.fileExists(atPath: path) { EngineActions.reveal(path) } else { ToastCenter.shared.show("Folder does not exist yet", error: true) }
                }
                ConfirmButton(title: "Clear History", message: "Deletes all \(log.entries.count) history entries and resets statistics. Freed files are not affected.", kind: .destructive, disabled: log.entries.isEmpty) {
                    store.clearHistory()
                }
            }

            if store.appDataState.isLoading && entries.isEmpty {
                LoadingPanel(text: "Measuring app data…")
            } else if entries.isEmpty {
                EmptyPanel(icon: "folder", title: "No app data", message: "MacLean has not written anything to Application Support yet.")
            } else {
                if total > 0 {
                    Card("Breakdown") {
                        VStack(spacing: 6) {
                            ForEach(entries) { entry in
                                BarRow(label: entry.name, value: Double(entry.bytes), total: Double(max(1, total)), valueText: Format.bytes(entry.bytes))
                            }
                        }
                    }
                }
                Card("Contents") {
                    VStack(spacing: 6) {
                        ForEach(entries) { entry in
                            CheckRow(isOn: Binding(get: { selected.contains(entry.path) }, set: { on in
                                if on { selected.insert(entry.path) } else { selected.remove(entry.path) }
                            }), title: entry.name,
                                     subtitle: "\(entry.isDirectory ? "\(Format.count(entry.files)) files" : "file") · modified \(Format.relative(entry.modified))",
                                     value: Format.bytes(entry.bytes),
                                     onOpen: { EngineActions.open(entry.path) },
                                     onReveal: { EngineActions.reveal(entry.path) })
                        }
                    }
                }
                if !store.lastFailures.isEmpty {
                    FailureList(failures: store.lastFailures)
                }
                SelectionBar(selectedCount: selected.count, totalCount: entries.count, selectedBytes: selectedBytes,
                             actionTitle: "Move to Trash",
                             confirmMessage: "Selected MacLean data files are moved to the Trash. Removing activity.json also clears history on next launch.",
                             busy: store.removalBusy,
                             onSelectAll: { selected = Set(entries.map(\.path)) },
                             onSelectNone: { selected = [] }) {
                    let paths = Array(selected)
                    selected = []
                    Task { await store.trashAppData(paths) }
                }
            }
        }
        .onAppear { store.loadAppDataIfNeeded() }
    }
}
