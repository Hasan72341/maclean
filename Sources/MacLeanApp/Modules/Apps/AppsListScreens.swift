import MacLeanCore
import SwiftUI

enum AppsListKind: Hashable {
    case all
    case large
    case recent
    case appStore
    case other
    case vendor(String)
    case architecture(String)

    var title: String {
        switch self {
        case .all: return "All Applications"
        case .large: return "Large Apps"
        case .recent: return "Recently Installed"
        case .appStore: return "App Store Apps"
        case .other: return "Other Sources"
        case .vendor(let v): return v
        case .architecture(let a): return a
        }
    }

    var subtitle: String {
        switch self {
        case .all: return "Every .app in /Applications and ~/Applications"
        case .large: return "Bundles larger than 500 MB, biggest first"
        case .recent: return "Sorted by the date each app was added"
        case .appStore: return "Apps with a Mac App Store receipt (Contents/_MASReceipt)"
        case .other: return "Apps installed from downloads, disk images or packages"
        case .vendor(let v): return "Apps whose bundle ID starts with \(v)"
        case .architecture(let a):
            switch a {
            case "Intel": return "Intel-only executables run through Rosetta 2 on Apple silicon"
            case "Universal": return "Native on both Apple silicon and Intel"
            case "Apple Silicon": return "arm64-only executables"
            default: return "Executables lipo could not read"
            }
        }
    }

    var defaultSort: AppsSort {
        switch self {
        case .recent: return .added
        case .all, .vendor, .appStore, .other, .architecture: return .name
        case .large: return .size
        }
    }
}

enum AppsSort: String, CaseIterable, Identifiable {
    case size = "Size"
    case name = "Name"
    case lastUsed = "Last used"
    case added = "Added"
    var id: String { rawValue }
}

struct AppsListScreen: View {
    let kind: AppsListKind
    @ObservedObject private var store = AppsStore.shared
    @EnvironmentObject private var nav: Navigator
    @State private var query = ""
    @State private var sort: AppsSort? = nil
    @State private var selected: Set<String> = []
    @State private var busy = false
    @State private var summary: RemovalSummary?

    private var base: [AppsApp] {
        switch kind {
        case .all: return store.apps
        case .large: return store.apps.filter { $0.bytes > 500_000_000 }
        case .recent: return store.apps
        case .appStore: return store.apps.filter(\.isAppStore)
        case .other: return store.apps.filter { !$0.isAppStore }
        case .vendor(let v): return store.apps.filter { $0.vendor == v }
        case .architecture(let a): return store.apps.filter { store.archMap[$0.path] != nil && store.architectureClass($0.path) == a }
        }
    }

    private var visible: [AppsApp] {
        let needle = query.lowercased()
        let filtered = needle.isEmpty ? base : base.filter {
            $0.name.lowercased().contains(needle) || ($0.bundleID?.lowercased().contains(needle) ?? false)
        }
        switch sort ?? kind.defaultSort {
        case .size: return filtered.sorted { $0.bytes > $1.bytes }
        case .name: return filtered.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .lastUsed: return filtered.sorted { ($0.lastUsed ?? .distantPast) > ($1.lastUsed ?? .distantPast) }
        case .added: return filtered.sorted { ($0.added ?? .distantPast) > ($1.added ?? .distantPast) }
        }
    }

    var body: some View {
        let list = visible
        let all = base
        let total = all.reduce(Int64(0)) { $0 + $1.bytes }
        let selectedApps = all.filter { selected.contains($0.path) }
        ScreenScaffold(kind.title, subtitle: kind.subtitle) {
            RefreshLine(state: store.appsState) { store.loadApps(force: true) }
        } content: {
            TileGrid {
                StatTile(label: "Apps", value: Format.count(all.count), detail: list.count == all.count ? nil : "\(list.count) match filter", icon: "square.stack.3d.up")
                StatTile(label: "Total size", value: Format.bytes(total), detail: store.totalBytes > 0 ? Format.percent(Double(total) / Double(store.totalBytes)) + " of all apps" : nil, tint: Theme.accent, icon: "internaldrive")
                StatTile(label: "Largest", value: Format.bytes(all.map(\.bytes).max() ?? 0), detail: all.max { $0.bytes < $1.bytes }?.name, icon: "arrow.up.right")
                StatTile(label: "Opened this week", value: Format.count(all.filter { ($0.lastUsed ?? .distantPast) > Date().addingTimeInterval(-7 * 86_400) }.count), detail: "\(Format.count(all.filter { $0.lastUsed == nil }.count)) never recorded", tint: Theme.info, icon: "calendar")
            }

            if case .recent = kind, !all.isEmpty {
                Card("Installs per month", trailing: "last 12 months") {
                    AppsMonthBars(apps: all)
                }
            }

            HStack(spacing: 12) {
                SearchField(text: $query, prompt: "Filter by name or bundle ID")
                Picker("Sort", selection: Binding(get: { sort ?? kind.defaultSort }, set: { sort = $0 })) {
                    ForEach(AppsSort.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .flexibleWidth(320)
            }

            if let summary {
                Card("Last uninstall", trailing: summary.message) {
                    if !summary.failures.isEmpty { FailureList(failures: summary.failures) }
                }
            }

            AppsStateGate(state: store.appsState, isEmpty: all.isEmpty, emptyIcon: "square.stack.3d.up.slash", emptyTitle: "No apps in this group", retry: { store.loadApps(force: true) }) {
                LazyVStack(spacing: 6) {
                    ForEach(list) { app in
                        AppsAppRow(
                            app: app,
                            trailing: trailingText(app),
                            isOn: Binding(
                                get: { selected.contains(app.path) },
                                set: { if $0 { selected.insert(app.path) } else { selected.remove(app.path) } }
                            ),
                            badge: app.isAppStore ? "App Store" : nil,
                            badgeTint: Theme.success
                        )
                    }
                }
            }

            if !all.isEmpty {
                SelectionBar(
                    selectedCount: selectedApps.count,
                    totalCount: list.count,
                    selectedBytes: selectedApps.reduce(0) { $0 + $1.bytes },
                    actionTitle: "Uninstall Selected",
                    confirmMessage: "Each app and its automatically selected leftovers (caches, preferences, containers, user launch agents) are moved to the Trash. Running apps are skipped.",
                    busy: busy,
                    onSelectAll: { selected = Set(list.map(\.path)) },
                    onSelectNone: { selected = [] },
                    action: {
                        busy = true
                        let paths = Array(selected)
                        Task {
                            summary = await store.bulkUninstall(paths)
                            selected = []
                            busy = false
                        }
                    }
                )
            }
        }
        .onAppear {
            store.loadApps()
            if case .architecture = kind { store.loadArchitectures() }
        }
    }

    private func trailingText(_ app: AppsApp) -> String {
        switch sort ?? kind.defaultSort {
        case .added: return "Added \(Format.relative(app.added))"
        default: return "Used \(Format.relative(app.lastUsed))"
        }
    }
}

struct AppsMonthBars: View {
    let apps: [AppsApp]

    var body: some View {
        let calendar = Calendar.current
        let now = Date()
        let months: [(String, Int, Int64)] = (0..<12).reversed().map { offset in
            let start = calendar.date(byAdding: .month, value: -offset, to: calendar.date(from: calendar.dateComponents([.year, .month], from: now))!)!
            let end = calendar.date(byAdding: .month, value: 1, to: start)!
            let inMonth = apps.filter { ($0.added ?? .distantPast) >= start && ($0.added ?? .distantPast) < end }
            let label = start.formatted(.dateTime.month(.abbreviated))
            return (label, inMonth.count, inMonth.reduce(0) { $0 + $1.bytes })
        }
        let peak = max(1, months.map(\.1).max() ?? 1)
        HStack(alignment: .bottom, spacing: 8) {
            ForEach(Array(months.enumerated()), id: \.offset) { item in
                VStack(spacing: 4) {
                    Text("\(item.element.1)").font(Type.mono(10, weight: .semibold)).foregroundStyle(Theme.ink)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(item.element.1 > 0 ? Theme.accent : Theme.line)
                        .frame(height: max(3, CGFloat(item.element.1) / CGFloat(peak) * 80))
                    Text(item.element.0).font(Type.text(10)).foregroundStyle(Theme.muted)
                }
                .frame(maxWidth: .infinity)
                .help("\(item.element.1) apps · \(Format.bytes(item.element.2))")
            }
        }
        .frame(height: 120)
    }
}

// MARK: - Unused

struct AppsUnusedScreen: View {
    @ObservedObject private var store = AppsStore.shared
    @State private var days = 90
    @State private var selected: Set<String> = []
    @State private var busy = false
    @State private var summary: RemovalSummary?

    var body: some View {
        let list = store.unused(days: days)
        let never = store.neverOpened
        let bytes = list.reduce(Int64(0)) { $0 + $1.bytes }
        let selectedApps = (list + never).filter { selected.contains($0.path) }
        ScreenScaffold("Unused Apps", subtitle: "Based on Spotlight's last-used date (kMDItemLastUsedDate)") {
            RefreshLine(state: store.appsState) { store.loadApps(force: true) }
        } content: {
            Picker("Not opened in", selection: $days) {
                Text("30 days").tag(30)
                Text("90 days").tag(90)
                Text("180 days").tag(180)
                Text("1 year").tag(365)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 420)

            TileGrid {
                StatTile(label: "Unused apps", value: Format.count(list.count), detail: "of \(Format.count(store.apps.count)) installed", tint: Theme.warning, icon: "moon.zzz")
                StatTile(label: "Reclaimable", value: Format.bytes(bytes), detail: store.totalBytes > 0 ? Format.percent(Double(bytes) / Double(store.totalBytes)) + " of app storage" : nil, tint: Theme.accent, icon: "arrow.3.trianglepath")
                StatTile(label: "Never recorded", value: Format.count(never.count), detail: Format.bytes(never.reduce(0) { $0 + $1.bytes }), icon: "questionmark.circle")
                StatTile(label: "Oldest use", value: list.compactMap(\.daysSinceUse).max().map { "\($0)" } ?? "—", unit: "days", icon: "hourglass")
            }

            if !list.isEmpty {
                Card("Idle time distribution") {
                    let buckets: [(String, Int)] = [
                        ("< 6 months", list.filter { ($0.daysSinceUse ?? 0) < 180 }.count),
                        ("6–12 months", list.filter { (180..<365).contains($0.daysSinceUse ?? 0) }.count),
                        ("1–2 years", list.filter { (365..<730).contains($0.daysSinceUse ?? 0) }.count),
                        ("2+ years", list.filter { ($0.daysSinceUse ?? 0) >= 730 }.count),
                    ]
                    ForEach(buckets, id: \.0) { bucket in
                        BarRow(label: bucket.0, value: Double(bucket.1), total: Double(max(1, list.count)), valueText: "\(bucket.1) apps", tint: Theme.warning)
                    }
                }
            }

            if let summary {
                Card("Last uninstall", trailing: summary.message) {
                    if !summary.failures.isEmpty { FailureList(failures: summary.failures) }
                }
            }

            AppsStateGate(state: store.appsState, isEmpty: list.isEmpty && never.isEmpty, emptyIcon: "archivebox", emptyTitle: "Every app was used in the last \(days) days", retry: { store.loadApps(force: true) }) {
                if !list.isEmpty {
                    SectionHeader(title: "Not opened in \(days)+ days", detail: Format.bytes(bytes))
                    LazyVStack(spacing: 6) {
                        ForEach(list) { app in
                            AppsAppRow(app: app, trailing: "\(app.daysSinceUse ?? 0) days idle", isOn: binding(app.path))
                        }
                    }
                }
                if !never.isEmpty {
                    SectionHeader(title: "No usage record", detail: "Spotlight never saw these launch")
                    LazyVStack(spacing: 6) {
                        ForEach(never) { app in
                            AppsAppRow(app: app, trailing: "Added \(Format.relative(app.added))", isOn: binding(app.path))
                        }
                    }
                }
            }

            SelectionBar(
                selectedCount: selectedApps.count,
                totalCount: list.count + never.count,
                selectedBytes: selectedApps.reduce(0) { $0 + $1.bytes },
                actionTitle: "Uninstall Selected",
                confirmMessage: "Selected apps and their automatically selected leftovers move to the Trash.",
                busy: busy,
                onSelectAll: { selected = Set(list.map(\.path)) },
                onSelectNone: { selected = [] },
                action: {
                    busy = true
                    let paths = Array(selected)
                    Task {
                        summary = await store.bulkUninstall(paths)
                        selected = []
                        busy = false
                    }
                }
            )
        }
        .onAppear { store.loadApps() }
    }

    private func binding(_ path: String) -> Binding<Bool> {
        Binding(get: { selected.contains(path) }, set: { if $0 { selected.insert(path) } else { selected.remove(path) } })
    }
}

// MARK: - Vendors

struct AppsVendorsScreen: View {
    @ObservedObject private var store = AppsStore.shared
    @EnvironmentObject private var nav: Navigator
    @State private var query = ""

    var body: some View {
        let groups = Dictionary(grouping: store.apps, by: \.vendor)
            .map { (vendor: $0.key, apps: $0.value, bytes: $0.value.reduce(Int64(0)) { $0 + $1.bytes }) }
            .sorted { $0.bytes > $1.bytes }
        let filtered = query.isEmpty ? groups : groups.filter { $0.vendor.localizedCaseInsensitiveContains(query) || $0.apps.contains { $0.name.localizedCaseInsensitiveContains(query) } }
        let peak = Double(groups.first?.bytes ?? 1)
        ScreenScaffold("Vendors", subtitle: "Apps grouped by the first two parts of their bundle identifier") {
            RefreshLine(state: store.appsState) { store.loadApps(force: true) }
        } content: {
            TileGrid {
                StatTile(label: "Vendors", value: Format.count(groups.count), icon: "building.2")
                StatTile(label: "Top vendor", value: groups.first.map { Format.bytes($0.bytes) } ?? "—", detail: groups.first?.vendor, tint: Theme.accent, icon: "crown")
                StatTile(label: "Most apps", value: Format.count(groups.map(\.apps.count).max() ?? 0), detail: groups.max { $0.apps.count < $1.apps.count }?.vendor, icon: "square.grid.2x2")
                StatTile(label: "Single-app vendors", value: Format.count(groups.filter { $0.apps.count == 1 }.count), icon: "1.circle")
            }
            SearchField(text: $query, prompt: "Filter vendors or apps")
            AppsStateGate(state: store.appsState, isEmpty: groups.isEmpty, retry: { store.loadApps(force: true) }) {
                Card("By size", trailing: "\(filtered.count) vendors") {
                    ForEach(filtered, id: \.vendor) { group in
                        BarRow(
                            label: "\(group.vendor)  ·  \(group.apps.count) app\(group.apps.count == 1 ? "" : "s")",
                            value: Double(group.bytes),
                            total: peak,
                            valueText: Format.bytes(group.bytes)
                        ) {
                            nav.push(.apps(.vendorDetail(group.vendor)))
                        }
                    }
                }
            }
        }
        .onAppear { store.loadApps() }
    }
}

// MARK: - Architectures

struct AppsArchitecturesScreen: View {
    @ObservedObject private var store = AppsStore.shared

    var body: some View {
        let classes = ["Universal", "Apple Silicon", "Intel", "Unknown"]
        let counted = classes.map { name -> (String, [AppsApp]) in
            (name, store.apps.filter { store.archMap[$0.path] != nil && store.architectureClass($0.path) == name })
        }
        let isAppleSilicon = AppsArchitecturesScreen.hostIsARM
        ScreenScaffold("Architectures", subtitle: "Executable slices reported by lipo -archs") {
            RefreshLine(state: store.archState) { store.loadArchitectures(force: true) }
        } content: {
            TileGrid {
                ForEach(counted, id: \.0) { item in
                    StatTile(
                        label: item.0,
                        value: Format.count(item.1.count),
                        unit: "apps",
                        detail: Format.bytes(item.1.reduce(0) { $0 + $1.bytes }),
                        tint: item.0 == "Intel" ? Theme.warning : (item.0 == "Universal" ? Theme.success : Theme.ink),
                        icon: "cpu"
                    )
                }
            }
            if isAppleSilicon, let intel = counted.first(where: { $0.0 == "Intel" }), !intel.1.isEmpty {
                Card("Rosetta 2") {
                    Text("\(intel.1.count) Intel-only app\(intel.1.count == 1 ? "" : "s") run translated on this Mac. Check the vendors for Apple silicon builds — native apps launch faster and use less energy.")
                        .font(Type.text(12)).foregroundStyle(Theme.muted)
                }
            }
            AppsStateGate(state: store.archState, isEmpty: store.archMap.isEmpty, retry: { store.loadArchitectures(force: true) }) {
                let total = Double(max(1, store.archMap.count))
                Card("Breakdown", trailing: "\(store.archMap.count) executables") {
                    StackedBar(segments: counted.enumerated().map { index, item in
                        .init(label: item.0, value: Double(item.1.count), color: AppsPalette.color(index), text: "\(item.1.count)")
                    })
                    ForEach(counted, id: \.0) { item in
                        NavRow(icon: "cpu", title: item.0, subtitle: Format.percent(Double(item.1.count) / total, digits: 1) + " of apps", value: Format.count(item.1.count), route: .apps(.architectureGroup(item.0)))
                    }
                }
            }
        }
        .onAppear {
            store.loadApps()
            store.loadArchitectures()
        }
        .onChange(of: store.apps.count) { _ in store.loadArchitectures() }
    }

    static var hostIsARM: Bool {
        #if arch(arm64)
        return true
        #else
        var translated: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("sysctl.proc_translated", &translated, &size, nil, 0) == 0 && translated == 1
        #endif
    }
}
