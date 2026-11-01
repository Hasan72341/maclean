import MacLeanCore
import SwiftUI

enum LeftoverText {
    static func tint(_ confidence: LeftoverGroup.Confidence) -> Color {
        switch confidence {
        case .high: return Theme.success
        case .medium: return Theme.info
        case .low: return Theme.warning
        }
    }

    static func icon(_ location: String) -> String {
        switch location {
        case "Sandbox container", "Group container": return "shippingbox"
        case "Caches", "Cached updates (Sparkle)": return "internaldrive"
        case "Preferences", "Preferences (ByHost)": return "slider.horizontal.3"
        case "Logs", "Crash reports", "Crash reporter": return "doc.text"
        case "Saved state", "Autosave": return "rectangle.stack"
        case "HTTP storage", "WebKit data", "Cookies": return "globe"
        case "Launch agent", "Launch agent (all users)", "Launch daemon", "Privileged helper": return "gearshape.2"
        case "System Application Support", "System Caches", "System Preferences", "System Logs": return "lock.shield"
        case "Internet plug-in", "Preference pane", "Quick Look plug-in", "Spotlight importer", "Service", "Screen saver": return "puzzlepiece"
        default: return "folder"
        }
    }
}

// MARK: - All leftovers, grouped by app

struct AppsOrphansScreen: View {
    @ObservedObject private var store = AppsStore.shared
    @EnvironmentObject private var nav: Navigator
    @State private var query = ""
    @State private var filter: Filter = .all
    @State private var sort: Sort = .size
    @State private var hideVendor = false
    @State private var showIgnored = false
    @State private var busy = false

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", high = "High", medium = "Medium", low = "Low", trashed = "App in Trash"
        var id: String { rawValue }
    }

    enum Sort: String, CaseIterable, Identifiable {
        case size = "Size", name = "Name", age = "Oldest", confidence = "Confidence"
        var id: String { rawValue }
    }

    private var groups: [LeftoverGroup] {
        let base = (showIgnored ? store.orphans : store.visibleOrphans).filter { group in
            let text = query.isEmpty || group.displayName.localizedCaseInsensitiveContains(query) || group.appID.localizedCaseInsensitiveContains(query)
            guard text, !(hideVendor && group.vendorInstalled) else { return false }
            switch filter {
            case .all: return true
            case .high: return group.confidence == .high
            case .medium: return group.confidence == .medium
            case .low: return group.confidence == .low
            case .trashed: return group.trashedApp != nil
            }
        }
        switch sort {
        case .size: return base.sorted { $0.bytes > $1.bytes }
        case .name: return base.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        case .age: return base.sorted { ($0.newest ?? .distantPast) < ($1.newest ?? .distantPast) }
        case .confidence: return base.sorted { $0.confidence != $1.confidence ? $0.confidence > $1.confidence : $0.bytes > $1.bytes }
        }
    }

    var body: some View {
        let shown = groups
        let all = store.visibleOrphans
        let allItems = shown.flatMap(\.items)
        let chosen = allItems.filter { store.leftoverSelection.contains($0.path) }
        ScreenScaffold("Leftovers", subtitle: "Files left behind by apps that are no longer installed, grouped by app") {
            HStack(spacing: 8) {
                Button("Select recommended") { store.selectRecommendedLeftovers() }
                    .buttonStyle(EditorialButtonStyle(kind: .secondary))
                    .disabled(all.isEmpty)
                RefreshLine(state: store.orphansState) { store.loadOrphans(force: true) }
            }
        } content: {
            TileGrid {
                StatTile(label: "Apps", value: Format.count(all.count), detail: "\(Format.count(store.orphanItemCount)) items", icon: "square.stack.3d.up")
                StatTile(label: "Reclaimable", value: Format.bytes(store.orphanBytes), tint: Theme.danger, icon: "internaldrive")
                StatTile(label: "High confidence", value: Format.bytes(all.filter { $0.confidence == .high }.reduce(0) { $0 + $1.bytes }), detail: "\(all.filter { $0.confidence == .high }.count) apps", tint: Theme.success, icon: "checkmark.seal")
                StatTile(label: "App in Trash", value: Format.count(all.filter { $0.trashedApp != nil }.count), detail: "leftovers of trashed apps", tint: Theme.accent, icon: "trash")
                StatTile(label: "Vendor installed", value: Format.count(all.filter(\.vendorInstalled).count), detail: "review before removing", tint: Theme.warning, icon: "exclamationmark.triangle")
                StatTile(label: "Ignored", value: Format.count(store.ignoredLeftovers.count), icon: "eye.slash")
            }

            if !all.isEmpty {
                let byLocation = Dictionary(grouping: all.flatMap(\.items), by: \.group)
                    .map { (name: $0.key, bytes: $0.value.reduce(Int64(0)) { $0 + $1.bytes }, count: $0.value.count) }
                    .sorted { $0.bytes > $1.bytes }
                Card("Where leftovers live", trailing: "\(byLocation.count) locations") {
                    StackedBar(segments: byLocation.prefix(6).enumerated().map { index, entry in
                        .init(label: entry.name, value: Double(entry.bytes), color: AppsPalette.color(index), text: Format.bytes(entry.bytes))
                    })
                    let peak = Double(byLocation.first?.bytes ?? 1)
                    ForEach(byLocation.prefix(8), id: \.name) { entry in
                        BarRow(label: "\(entry.name) · \(entry.count)", value: Double(entry.bytes), total: peak, valueText: Format.bytes(entry.bytes), tint: Theme.warning)
                    }
                }
            }

            if let last = store.lastLeftoverClean {
                LeftoverResultCard(result: last)
            }

            HStack(spacing: 10) {
                SearchField(text: $query, prompt: "Filter by app or bundle ID")
                Picker("Confidence", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().flexibleWidth(380)
                Picker("Sort", selection: $sort) {
                    ForEach(Sort.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden().frame(width: 120)
            }
            HStack(spacing: 16) {
                Toggle("Hide apps whose developer still has an app installed", isOn: $hideVendor).toggleStyle(EditorialToggleStyle())
                Toggle("Show ignored", isOn: $showIgnored).toggleStyle(EditorialToggleStyle())
                Spacer()
                Text("\(Format.count(shown.count)) apps shown").font(Type.text(11)).foregroundStyle(Theme.muted)
            }

            SelectionBar(
                selectedCount: chosen.count,
                totalCount: allItems.count,
                selectedBytes: chosen.reduce(0) { $0 + $1.bytes },
                actionTitle: "Remove Leftovers",
                confirmMessage: "\(Format.count(chosen.count)) leftover items of \(Set(shown.filter { g in g.items.contains { store.leftoverSelection.contains($0.path) } }.map(\.appID)).count) apps move to the Trash. The engine re-checks every path and file identity first; restore from the Trash if an app needs them.",
                busy: busy,
                onSelectAll: { store.leftoverSelection.formUnion(allItems.map(\.path)) },
                onSelectNone: { store.leftoverSelection.subtract(allItems.map(\.path)) },
                action: {
                    busy = true
                    let items = chosen
                    Task {
                        _ = await store.cleanLeftovers(items, title: "Remove app leftovers")
                        busy = false
                    }
                }
            )

            AppsStateGate(state: store.orphansState, isEmpty: shown.isEmpty, emptyIcon: "archivebox", emptyTitle: all.isEmpty ? "No leftovers found" : "Nothing matches", emptyMessage: all.isEmpty ? "Every app-named file in ~/Library belongs to an installed app." : "Change the filter or search.", retry: { store.loadOrphans(force: true) }) {
                LazyVStack(spacing: 6) {
                    ForEach(shown) { group in
                        LeftoverGroupRow(group: group)
                    }
                }
            }
        }
        .onAppear { store.loadOrphans() }
    }
}

/// One app's leftovers: tri-state checkbox, confidence, locations, size.
private struct LeftoverGroupRow: View {
    let group: LeftoverGroup
    @ObservedObject private var store = AppsStore.shared
    @EnvironmentObject private var nav: Navigator
    @State private var hovering = false

    var body: some View {
        let paths = group.items.map(\.path)
        let selected = paths.filter { store.leftoverSelection.contains($0) }.count
        let ignored = store.ignoredLeftovers.contains(group.appID)
        HStack(spacing: 12) {
            Button {
                if selected == paths.count { store.leftoverSelection.subtract(paths) } else { store.leftoverSelection.formUnion(paths) }
            } label: {
                Image(systemName: selected == 0 ? "square" : (selected == paths.count ? "checkmark.square.fill" : "minus.square.fill"))
                    .font(.system(size: 15))
                    .foregroundStyle(selected == 0 ? Theme.faint : Theme.accent)
            }
            .buttonStyle(.plain)
            .help(selected == paths.count ? "Deselect all \(paths.count) items" : "Select all \(paths.count) items")
            Button { nav.push(.apps(.orphanGroup(group.appID))) } label: {
                HStack(spacing: 12) {
                    Image(systemName: group.trashedApp != nil ? "trash.circle.fill" : "app.dashed")
                        .font(.system(size: 22))
                        .foregroundStyle(group.trashedApp != nil ? Theme.accent : Theme.muted)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(group.displayName).font(Type.text(13, weight: .semibold)).foregroundStyle(ignored ? Theme.muted : Theme.ink).lineLimit(1)
                            RiskBadge(text: group.confidence.title, tint: LeftoverText.tint(group.confidence))
                            if group.vendorInstalled { RiskBadge(text: "Vendor installed", tint: Theme.warning) }
                            if ignored { RiskBadge(text: "Ignored", tint: Theme.faint) }
                        }
                        Text("\(group.appID) · \(group.items.count) item\(group.items.count == 1 ? "" : "s") in \(group.locations.count) location\(group.locations.count == 1 ? "" : "s") · modified \(Format.relative(group.newest))")
                            .font(Type.mono(10)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
                        HStack(spacing: 4) {
                            ForEach(group.locations.prefix(6), id: \.self) { location in
                                Label(location, systemImage: LeftoverText.icon(location))
                                    .font(Type.text(9)).foregroundStyle(Theme.faint)
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Capsule().fill(Theme.line.opacity(0.5)))
                            }
                        }
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(Format.bytes(group.bytes)).font(Type.mono(12, weight: .semibold)).foregroundStyle(Theme.ink).monospacedDigit()
                        if selected > 0 {
                            Text("\(selected)/\(paths.count) selected").font(Type.text(10)).foregroundStyle(Theme.accent)
                        }
                    }
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.faint)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 9).fill(hovering ? Theme.line.opacity(0.45) : Theme.canvas))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(selected > 0 ? Theme.accent.opacity(0.5) : Theme.line, lineWidth: 1))
        .onHover { hovering = $0 }
        .contextMenu {
            Button(ignored ? "Stop ignoring" : "Ignore this app") { store.ignoreLeftovers(group.appID, !ignored) }
            if let first = group.items.first { Button("Reveal largest item") { EngineActions.reveal(first.path) } }
        }
    }
}

struct LeftoverResultCard: View {
    let result: AppsLeftoverClean
    @EnvironmentObject private var nav: Navigator

    var body: some View {
        Card("Last removal", trailing: "\(Format.relative(result.date)) · \(Format.bytes(result.summary.bytes))") {
            TileGrid(minWidth: 130) {
                StatTile(label: "Freed", value: Format.bytes(result.summary.bytes), tint: Theme.success, icon: "checkmark.circle")
                StatTile(label: "Removed", value: Format.count(result.summary.removed))
                StatTile(label: "Apps", value: Format.count(result.apps.count))
                StatTile(label: "Failed", value: Format.count(result.summary.failures.count), tint: result.summary.failures.isEmpty ? Theme.muted : Theme.danger)
            }
            if !result.apps.isEmpty {
                Text(result.apps.joined(separator: " · ")).font(Type.text(11)).foregroundStyle(Theme.muted).lineLimit(2)
            }
            if !result.summary.failures.isEmpty {
                FailureList(failures: result.summary.failures)
                AppsAdminPanel(paths: result.summary.failures.map(\.path))
            }
            HStack {
                Button("Open Trash") { EngineActions.open(EngineActions.home.appendingPathComponent(".Trash").path) }
                    .buttonStyle(EditorialButtonStyle(kind: .inline))
                Button("Cleanup history") { nav.push(.settings(.history)) }
                    .buttonStyle(EditorialButtonStyle(kind: .inline))
            }
        }
    }
}

// MARK: - One app's leftovers

struct AppsOrphanGroupScreen: View {
    let appID: String
    @ObservedObject private var store = AppsStore.shared
    @EnvironmentObject private var nav: Navigator
    @State private var busy = false

    var body: some View {
        let group = store.orphanGroup(appID)
        ScreenScaffold(group?.displayName ?? appID, subtitle: appID) {
            if let group {
                let ignored = store.ignoredLeftovers.contains(group.appID)
                Button(ignored ? "Stop Ignoring" : "Ignore App") {
                    store.ignoreLeftovers(group.appID, !ignored)
                    if !ignored { nav.pop() }
                }
                .buttonStyle(EditorialButtonStyle(kind: .ghost))
            }
            RefreshLine(state: store.orphansState) { store.loadOrphans(force: true) }
        } content: {
            if let group {
                content(group)
            } else if store.orphansState.isLoading {
                LoadingPanel(text: "Scanning leftovers…")
            } else {
                EmptyPanel(icon: "checkmark.circle", title: "No leftovers left", message: "Everything from \(appID) has been removed.", actionTitle: "All leftovers") {
                    nav.pop()
                }
            }
        }
        .onAppear { store.loadOrphans() }
    }

    @ViewBuilder
    private func content(_ group: LeftoverGroup) -> some View {
        let chosen = group.items.filter { store.leftoverSelection.contains($0.path) }
        TileGrid {
            StatTile(label: "Size", value: Format.bytes(group.bytes), tint: Theme.danger, icon: "internaldrive")
            StatTile(label: "Items", value: Format.count(group.items.count), detail: "\(Format.count(group.files)) files")
            StatTile(label: "Locations", value: Format.count(group.locations.count))
            StatTile(label: "Confidence", value: group.confidence.title, tint: LeftoverText.tint(group.confidence), icon: "checkmark.seal")
            StatTile(label: "Last modified", value: Format.relative(group.newest), detail: Format.date(group.newest), icon: "clock")
        }
        Card("Why MacLean thinks the app is gone") {
            ForEach(group.reasons, id: \.self) { reason in
                Label(reason, systemImage: "info.circle").font(Type.text(12)).foregroundStyle(Theme.ink)
            }
            Label("No installed app, running app, system app or Launch Services entry owns \(group.appID) or its helper IDs.", systemImage: "checkmark.circle")
                .font(Type.text(12)).foregroundStyle(Theme.muted)
            if let trashed = group.trashedApp {
                HStack {
                    Text("App bundle: \(Format.abbreviated(trashed))").font(Type.mono(10)).foregroundStyle(Theme.muted)
                    Spacer()
                    Button("Reveal") { EngineActions.reveal(trashed) }.buttonStyle(EditorialButtonStyle(kind: .inline))
                }
            }
            if group.vendorInstalled {
                let vendor = AppsScan.vendor(of: group.appID)
                NavRow(icon: "building.2", title: "Installed apps from \(vendor)", subtitle: "These may share some of this data", tint: Theme.warning, route: .apps(.vendorDetail(vendor)))
            }
        }
        let byLocation = Dictionary(grouping: group.items, by: \.group).sorted { $0.value.reduce(0) { $0 + $1.bytes } > $1.value.reduce(0) { $0 + $1.bytes } }
        Card("By location") {
            let peak = Double(byLocation.first?.value.reduce(0) { $0 + $1.bytes } ?? 1)
            ForEach(byLocation, id: \.key) { entry in
                BarRow(label: "\(entry.key) · \(entry.value.count)", value: Double(entry.value.reduce(0) { $0 + $1.bytes }), total: peak, valueText: Format.bytes(entry.value.reduce(0) { $0 + $1.bytes }), tint: Theme.warning)
            }
        }
        SelectionBar(
            selectedCount: chosen.count,
            totalCount: group.items.count,
            selectedBytes: chosen.reduce(0) { $0 + $1.bytes },
            actionTitle: "Remove Leftovers",
            confirmMessage: "\(Format.count(chosen.count)) items of \(group.displayName) move to the Trash. Each path is re-validated by the engine first.",
            busy: busy,
            onSelectAll: { store.leftoverSelection.formUnion(group.items.map(\.path)) },
            onSelectNone: { store.leftoverSelection.subtract(group.items.map(\.path)) },
            action: {
                busy = true
                let items = chosen
                Task {
                    _ = await store.cleanLeftovers(items, title: "Remove \(group.displayName) leftovers")
                    busy = false
                }
            }
        )
        ForEach(byLocation, id: \.key) { entry in
            SectionHeader(title: entry.key, detail: "\(entry.value.count) · \(Format.bytes(entry.value.reduce(0) { $0 + $1.bytes }))")
            ForEach(entry.value, id: \.path) { item in
                CheckRow(
                    isOn: Binding(
                        get: { AppsStore.shared.leftoverSelection.contains(item.path) },
                        set: { on in if on { AppsStore.shared.leftoverSelection.insert(item.path) } else { AppsStore.shared.leftoverSelection.remove(item.path) } }
                    ),
                    title: (item.path as NSString).lastPathComponent,
                    subtitle: "\(Format.abbreviated((item.path as NSString).deletingLastPathComponent)) · \(Format.count(item.files)) files · modified \(Format.relative(item.modified))" + (FileManager.default.isWritableFile(atPath: (item.path as NSString).deletingLastPathComponent) ? "" : " · needs administrator"),
                    value: Format.bytes(item.bytes),
                    onOpen: { nav.push(.apps(.orphanDetail(item.path))) },
                    onReveal: { EngineActions.reveal(item.path) }
                )
            }
        }
    }
}

// MARK: - One leftover item

struct AppsOrphanDetailScreen: View {
    let path: String
    @ObservedObject private var store = AppsStore.shared
    @EnvironmentObject private var nav: Navigator
    @State private var children: [AppsPart] = []
    @State private var state: LoadState = .idle

    var body: some View {
        let found = store.orphanItem(path)
        ScreenScaffold((path as NSString).lastPathComponent, subtitle: Format.abbreviated(path)) {
            RefreshLine(state: state) { load() }
        } content: {
            if let found {
                let item = found.item
                TileGrid {
                    StatTile(label: "Size", value: Format.bytes(item.bytes), tint: Theme.danger, icon: "internaldrive")
                    StatTile(label: "Files", value: Format.count(item.files), icon: "doc.on.doc")
                    StatTile(label: "Modified", value: Format.relative(item.modified), detail: Format.date(item.modified), icon: "clock")
                    StatTile(label: "Location", value: item.group, icon: LeftoverText.icon(item.group))
                }
                Card("Owner") {
                    KeyValueRow(key: "App", value: found.group.displayName)
                    KeyValueRow(key: "Bundle ID", value: found.group.appID, mono: true)
                    KeyValueRow(key: "Confidence", value: found.group.confidence.title)
                    KeyValueRow(key: "Allowed root", value: Format.abbreviated(item.allowedRoot), mono: true)
                    NavRow(icon: "square.stack", title: "All leftovers of \(found.group.displayName)", value: "\(found.group.items.count) · \(Format.bytes(found.group.bytes))", route: .apps(.orphanGroup(found.group.appID)))
                }
                HStack {
                    Button("Reveal in Finder") { EngineActions.reveal(path) }.buttonStyle(EditorialButtonStyle(kind: .secondary))
                    ConfirmButton(title: "Move to Trash", message: "\(Format.abbreviated(path)) (\(Format.bytes(item.bytes))) moves to the Trash after the engine re-checks it.", kind: .destructive) {
                        Task {
                            let summary = await store.cleanLeftovers([item], title: "Remove leftover \((path as NSString).lastPathComponent)")
                            if summary.failures.isEmpty { nav.pop() }
                        }
                    }
                }
                if item.isDirectory {
                    Card("Contents", trailing: "\(children.count) entries") {
                        if state.isLoading { ProgressView().controlSize(.small) }
                        let peak = Double(children.first?.bytes ?? 1)
                        ForEach(children) { child in
                            BarRow(label: "\(child.name) · \(Format.count(child.files)) files", value: Double(child.bytes), total: peak, valueText: Format.bytes(child.bytes)) {
                                EngineActions.reveal(child.path)
                            }
                        }
                    }
                }
            } else {
                EmptyPanel(icon: "checkmark.circle", title: "Already removed", message: Format.abbreviated(path))
            }
        }
        .onAppear { if state.loadedAt == nil { load() } }
    }

    private func load() {
        state = .loading("Measuring contents…")
        let target = path
        Task {
            children = await engine { AppsScan.listChildren(path: target) }
            state = .loaded(Date())
        }
    }
}
