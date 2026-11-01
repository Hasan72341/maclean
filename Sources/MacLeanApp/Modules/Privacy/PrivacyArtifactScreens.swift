import MacLeanCore
import SwiftUI

enum PrivacyListMode: Hashable {
    case all
    case group(String)
    case browserCategory(String, String)
}

// MARK: - Artifact list (group / all / browser category)

struct PrivacyArtifactListScreen: View {
    let mode: PrivacyListMode
    @ObservedObject private var store = PrivacyStore.shared
    @EnvironmentObject private var nav: Navigator
    @State private var query = ""
    @State private var sort: PrivacySort = .size

    private var title: String {
        switch mode {
        case .all: return "All Privacy Items"
        case .group(let name): return name == "Recent items" ? "Recent Items" : name
        case .browserCategory(let browser, let category): return "\(browser) · \(category)"
        }
    }

    private var base: [Artifact] {
        switch mode {
        case .all: return store.artifacts
        case .group(let name): return store.artifacts(group: name)
        case .browserCategory(let browser, let category):
            let groups = PrivacyCategory(rawValue: category)?.groups ?? []
            return store.artifacts(browser: browser).filter { groups.contains($0.group) }
        }
    }

    private var items: [Artifact] {
        var list = base
        if !query.isEmpty {
            list = list.filter { $0.path.localizedCaseInsensitiveContains(query) || $0.detail.localizedCaseInsensitiveContains(query) || $0.group.localizedCaseInsensitiveContains(query) }
        }
        switch sort {
        case .size: list.sort { $0.bytes > $1.bytes }
        case .name: list.sort { ($0.path as NSString).lastPathComponent.localizedCaseInsensitiveCompare(($1.path as NSString).lastPathComponent) == .orderedAscending }
        case .date: list.sort { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
        }
        return list
    }

    var body: some View {
        let all = base
        let visible = items
        let chosen = store.selectedArtifacts(in: all)
        let bytes = all.reduce(0) { $0 + $1.bytes }
        let owners = Array(Set(all.compactMap(PrivacyBrowsers.owner)))
        ScreenScaffold(title, subtitle: subtitle) {
            SearchField(text: $query, prompt: "Filter paths")
        } content: {
            RefreshLine(state: store.artifactState) { Task { await store.loadArtifacts() } }
            TileGrid(minWidth: 150) {
                StatTile(label: "Items", value: Format.count(all.count), detail: "\(visible.count) shown", icon: "number")
                StatTile(label: "Size", value: Format.bytes(bytes), detail: "\(Format.count(all.reduce(0) { $0 + $1.files })) files", tint: Theme.accent, icon: "externaldrive")
                StatTile(label: "Selected", value: Format.count(chosen.count), detail: Format.bytes(chosen.reduce(0) { $0 + $1.bytes }), icon: "checkmark.square")
                StatTile(label: "Newest change", value: Format.relative(all.compactMap(\.modified).max()), detail: Format.date(all.compactMap(\.modified).max()), icon: "clock")
            }
            if case .all = mode { breakdown(all) }
            if case .group = mode, Set(all.compactMap(PrivacyBrowsers.owner)).count > 1 { byBrowser(all) }
            PrivacyCleanOptions(browsers: owners)
            if store.artifactState.isLoading && all.isEmpty {
                LoadingPanel(text: "Scanning…")
            } else if all.isEmpty {
                EmptyPanel(icon: "checkmark.shield", title: "Nothing here", message: "No traces were found for this category. They appear again as you browse.", actionTitle: "Rescan") { Task { await store.loadArtifacts() } }
            } else {
                Card(nil) {
                    HStack {
                        PrivacySortPicker(sort: $sort)
                        Spacer()
                        Text("\(visible.count) of \(all.count)").font(Type.mono(10)).foregroundStyle(Theme.faint)
                    }
                    ForEach(visible, id: \.path) { artifact in
                        let badge = PrivacyGroupStyle.badge(artifact)
                        CheckRow(
                            isOn: privacySelection(artifact.path),
                            title: label(artifact),
                            subtitle: Format.abbreviated(artifact.path),
                            value: Format.bytes(artifact.bytes),
                            badge: badge.0,
                            badgeTint: badge.1 ? Theme.warning : Theme.success,
                            onOpen: { nav.push(.privacy(.artifact(artifact.path))) },
                            onReveal: { EngineActions.reveal(artifact.path) }
                        )
                    }
                }
                SelectionBar(
                    selectedCount: chosen.count,
                    totalCount: all.count,
                    selectedBytes: chosen.reduce(0) { $0 + $1.bytes },
                    actionTitle: "Clean Selected",
                    confirmMessage: "Selected traces are \(store.permanent ? "deleted permanently" : "moved to the Trash") via the engine's ArtifactCleaner. Browsers that own them must be closed unless you allowed cleaning while running.",
                    busy: store.busy,
                    onSelectAll: { store.selected.formUnion(visible.map(\.path)) },
                    onSelectNone: { store.selected.subtract(all.map(\.path)) },
                    action: { Task { await store.clean(chosen, title: "Clean \(title)") } }
                )
            }
        }
    }

    private var subtitle: String {
        switch mode {
        case .all: return "Every trace PrivacyScanner found, across all browsers and macOS lists."
        case .group(let name) where name == "Recent items": return "macOS recent documents, applications, servers and hosts lists."
        case .group: return "Files holding this kind of data, per browser profile."
        case .browserCategory: return "This browser's files for one kind of data."
        }
    }

    private func label(_ artifact: Artifact) -> String {
        let name = (artifact.path as NSString).lastPathComponent
        switch mode {
        case .group: return "\(name) — \(artifact.detail)"
        case .all: return "\(name) — \(artifact.group)"
        case .browserCategory: return "\(name) — \(PrivacyBrowsers.profile(of: artifact) ?? artifact.group)"
        }
    }

    private func breakdown(_ all: [Artifact]) -> some View {
        let groups = Dictionary(grouping: all, by: \.group).map { ($0.key, $0.value.reduce(Int64(0)) { $0 + $1.bytes }) }.sorted { $0.1 > $1.1 }
        let palette: [Color] = [Theme.accent, Theme.info, Theme.warning, Theme.success, Theme.danger, Theme.muted, Theme.lineStrong, Theme.ink]
        return Card("Composition") {
            StackedBar(segments: groups.enumerated().map { index, entry in
                StackedBar.Segment(label: entry.0, value: Double(entry.1), color: palette[index % palette.count], text: Format.bytes(entry.1))
            })
        }
    }

    private func byBrowser(_ all: [Artifact]) -> some View {
        let rows = Dictionary(grouping: all) { PrivacyBrowsers.owner(of: $0) ?? "macOS" }
            .map { ($0.key, $0.value.count, $0.value.reduce(Int64(0)) { $0 + $1.bytes }) }
            .sorted { $0.2 > $1.2 }
        let peak = Double(rows.first?.2 ?? 1)
        return Card("By browser", trailing: "\(rows.count)") {
            ForEach(rows, id: \.0) { row in
                BarRow(label: "\(row.0) · \(row.1) items", value: Double(row.2), total: peak, valueText: Format.bytes(row.2)) {
                    if PrivacyBrowsers.info(row.0) != nil { nav.push(.privacy(.browser(row.0))) }
                }
            }
        }
    }
}

// MARK: - Artifact detail

struct PrivacyArtifactDetailScreen: View {
    let path: String
    @ObservedObject private var store = PrivacyStore.shared
    @EnvironmentObject private var nav: Navigator
    @State private var children: [PrivacyChild] = []

    var body: some View {
        if let artifact = store.artifact(path) {
            content(artifact)
        } else {
            ScreenScaffold((path as NSString).lastPathComponent) {
                EmptyPanel(icon: "checkmark.circle", title: "This item is gone", message: "\(Format.abbreviated(path)) was cleaned or no longer exists.", actionTitle: "Back") { nav.pop() }
            }
        }
    }

    private func content(_ artifact: Artifact) -> some View {
        let owner = PrivacyBrowsers.owner(of: artifact)
        let badge = PrivacyGroupStyle.badge(artifact)
        return ScreenScaffold((artifact.path as NSString).lastPathComponent, subtitle: artifact.detail) {
            Button("Reveal") { EngineActions.reveal(artifact.path) }.buttonStyle(EditorialButtonStyle(kind: .secondary))
        } content: {
            TileGrid(minWidth: 150) {
                StatTile(label: "Size", value: Format.bytes(artifact.bytes), tint: Theme.accent, icon: "externaldrive")
                StatTile(label: "Files", value: Format.count(artifact.files), detail: artifact.isDirectory ? "folder" : "single file", icon: "doc")
                StatTile(label: "Modified", value: Format.relative(artifact.modified), detail: Format.date(artifact.modified), icon: "clock")
                StatTile(label: "Share of category", value: Format.percent(Double(artifact.bytes) / Double(max(1, store.artifacts(group: artifact.group).reduce(0) { $0 + $1.bytes })), digits: 1), detail: artifact.group, icon: "chart.pie")
            }
            Card("Details") {
                KeyValueRow(key: "Category", value: artifact.group)
                KeyValueRow(key: "Owner", value: owner ?? "macOS")
                if let profile = PrivacyBrowsers.profile(of: artifact) { KeyValueRow(key: "Profile", value: profile) }
                KeyValueRow(key: "Path", value: Format.abbreviated(artifact.path), mono: true)
                KeyValueRow(key: "Allowed root", value: Format.abbreviated(artifact.allowedRoot), mono: true)
                KeyValueRow(key: "Risk", value: artifact.risk.rawValue)
                if let inode = artifact.inode { KeyValueRow(key: "Inode", value: "\(inode)", mono: true) }
                HStack(spacing: 6) {
                    RiskBadge(text: badge.0, tint: badge.1 ? Theme.warning : Theme.success)
                    if let owner, store.running.contains(owner) { RiskBadge(text: "\(owner) running", tint: Theme.danger) }
                }
            }
            Card("What removing it does") {
                Text(explanation(artifact.group)).font(Type.text(12)).foregroundStyle(Theme.muted)
            }
            if artifact.isDirectory {
                Card("Contents", trailing: "\(children.count) entries") {
                    if children.isEmpty { Text("Empty or unreadable.").font(Type.text(11)).foregroundStyle(Theme.muted) }
                    let peak = Double(children.first?.bytes ?? 1)
                    ForEach(Array(children.prefix(40).enumerated()), id: \.offset) { item in
                        BarRow(label: item.element.name, value: Double(item.element.bytes), total: peak, valueText: Format.bytes(item.element.bytes), tint: Theme.info)
                    }
                }
            }
            PrivacyCleanOptions(browsers: owner.map { [$0] } ?? [])
            HStack(spacing: 10) {
                ConfirmButton(title: "Clean This Item", message: "\(Format.abbreviated(artifact.path)) (\(Format.bytes(artifact.bytes))) will be \(store.permanent ? "deleted permanently" : "moved to the Trash").", disabled: store.busy) {
                    Task { await store.clean([artifact], title: "Clean \(artifact.group)") }
                }
                Button("Open \(artifact.group)") { nav.push(.privacy(.group(artifact.group))) }.buttonStyle(EditorialButtonStyle(kind: .ghost))
                if let owner { Button("Open \(owner)") { nav.push(.privacy(.browser(owner))) }.buttonStyle(EditorialButtonStyle(kind: .ghost)) }
            }
        }
        .task(id: artifact.path) {
            guard artifact.isDirectory else { return }
            let target = artifact.path
            let list = await engine { PrivacyProbe.directoryListing(target).map { PrivacyChild(name: $0.name, bytes: $0.bytes, modified: $0.modified) } }
            children = list
        }
    }

    private func explanation(_ group: String) -> String {
        switch group {
        case "Browsing history": return "Erases the list of visited sites and typed URLs. Address-bar suggestions reset."
        case "Cookies": return "Signs you out of websites and removes tracking identifiers."
        case "Autofill": return "Removes saved form entries, addresses and (for Chromium) card metadata."
        case "Saved passwords": return "Deletes the browser's local password store. Make sure passwords are synced or exported first."
        case "Session data": return "Forgets open and recently closed tabs; the browser will not restore the previous session."
        case "Downloads history": return "Clears the downloads list. Downloaded files themselves are not touched."
        case "Website data": return "Removes local storage and databases kept by websites (offline data, settings)."
        case "Recent items": return "Clears macOS recent documents, applications and servers lists. Rebuilt as you use the Mac."
        default: return "Removes this trace file."
        }
    }
}

struct PrivacyChild: Sendable {
    let name: String
    let bytes: Int64
    let modified: Date?
}

// MARK: - Browsers comparison

struct PrivacyBrowsersScreen: View {
    @ObservedObject private var store = PrivacyStore.shared
    @EnvironmentObject private var nav: Navigator

    var body: some View {
        let names = store.browserNames
        let rows = names.map { name -> (String, [Artifact], Int64) in
            let items = store.artifacts(browser: name)
            return (name, items, items.reduce(0) { $0 + $1.bytes })
        }
        let peak = Double(rows.map(\.2).max() ?? 1)
        ScreenScaffold("Browsers", subtitle: "Every installed browser profile PrivacyScanner found data for.") {
            content(names: names, rows: rows, peak: peak)
        }
    }

    @ViewBuilder
    private func content(names: [String], rows: [(String, [Artifact], Int64)], peak: Double) -> some View {
        RefreshLine(state: store.artifactState) { Task { await store.loadArtifacts() } }
        TileGrid(minWidth: 150) {
            StatTile(label: "Detected", value: "\(names.count)", detail: "of \(PrivacyBrowsers.all.count) supported", icon: "globe")
            StatTile(label: "Running", value: "\(store.running.count)", detail: store.running.sorted().joined(separator: ", "), tint: store.running.isEmpty ? Theme.success : Theme.warning, history: store.runningHistory.count > 1 ? store.runningHistory : nil, icon: "play.circle")
            StatTile(label: "Browser data", value: Format.bytes(rows.reduce(0) { $0 + $1.2 }), tint: Theme.accent, icon: "externaldrive")
            StatTile(label: "Profiles", value: "\(Set(store.artifacts.compactMap { a in PrivacyBrowsers.owner(of: a).map { "\($0)|\(PrivacyBrowsers.profile(of: a) ?? "")" } }).count)", icon: "person.2")
        }
        if names.isEmpty {
            EmptyPanel(icon: "globe", title: store.artifactState.isLoading ? "Scanning…" : "No browser data found")
        } else {
            Card("Data per browser") {
                ForEach(rows, id: \.0) { row in
                    BarRow(label: row.0, value: Double(row.2), total: peak, valueText: Format.bytes(row.2), tint: store.running.contains(row.0) ? Theme.warning : Theme.accent) {
                        nav.push(.privacy(.browser(row.0)))
                    }
                }
            }
            ForEach(rows, id: \.0) { row in
                let profiles = Set(row.1.compactMap(PrivacyBrowsers.profile)).count
                NavRow(
                    icon: PrivacyBrowsers.info(row.0)?.icon ?? "globe",
                    title: row.0,
                    subtitle: "\(row.1.count) items · \(max(profiles, 1)) profile\(profiles == 1 ? "" : "s") · " + (store.running.contains(row.0) ? "running" : "not running"),
                    value: Format.bytes(row.2),
                    tint: store.running.contains(row.0) ? Theme.warning : Theme.accent,
                    route: .privacy(.browser(row.0))
                )
            }
        }
    }
}

// MARK: - Single browser

struct PrivacyBrowserScreen: View {
    let name: String
    @ObservedObject private var store = PrivacyStore.shared
    @EnvironmentObject private var nav: Navigator

    var body: some View {
        let items = store.artifacts(browser: name)
        let bytes = items.reduce(0) { $0 + $1.bytes }
        let isRunning = store.running.contains(name)
        let profiles = Array(Set(items.compactMap(PrivacyBrowsers.profile))).sorted()
        let safe = items.filter { !PrivacyGroupStyle.unsafeGroups.contains($0.group) }
        ScreenScaffold(name, subtitle: isRunning ? "Running — quit it before cleaning for reliable results." : "Not running") {
            if isRunning {
                Button("Quit \(name)") { store.quit(browser: name) }.buttonStyle(EditorialButtonStyle(kind: .secondary))
            }
        } content: {
            RefreshLine(state: store.artifactState) { Task { await store.loadArtifacts() } }
            TileGrid(minWidth: 150) {
                StatTile(label: "Items", value: Format.count(items.count), icon: "number")
                StatTile(label: "Size", value: Format.bytes(bytes), tint: Theme.accent, icon: "externaldrive")
                StatTile(label: "Profiles", value: "\(max(1, profiles.count))", detail: profiles.prefix(3).joined(separator: ", "), icon: "person.2")
                StatTile(label: "State", value: isRunning ? "Running" : "Closed", tint: isRunning ? Theme.warning : Theme.success, icon: isRunning ? "play.circle" : "stop.circle")
            }
            Card("Categories") {
                ForEach(PrivacyCategory.allCases, id: \.self) { category in
                    let sub = items.filter { category.groups.contains($0.group) }
                    NavRow(
                        icon: category.icon,
                        title: category.rawValue,
                        subtitle: sub.isEmpty ? "nothing found" : "\(sub.count) items · " + Set(sub.map(\.group)).sorted().joined(separator: ", "),
                        value: Format.bytes(sub.reduce(0) { $0 + $1.bytes }),
                        tint: category == .autofill ? Theme.warning : Theme.accent,
                        route: .privacy(.browserCategory(name, category.rawValue))
                    )
                }
            }
            if profiles.count > 1 {
                Card("Profiles", trailing: "\(profiles.count)") {
                    let peak = Double(profiles.map { p in items.filter { PrivacyBrowsers.profile(of: $0) == p }.reduce(0) { $0 + $1.bytes } }.max() ?? 1)
                    ForEach(profiles, id: \.self) { profile in
                        let sub = items.filter { PrivacyBrowsers.profile(of: $0) == profile }
                        let b = sub.reduce(0) { $0 + $1.bytes }
                        BarRow(label: "\(profile) · \(sub.count) items", value: Double(b), total: peak, valueText: Format.bytes(b))
                    }
                }
            }
            PrivacyCleanOptions(browsers: [name])
            HStack(spacing: 10) {
                ConfirmButton(title: "Clean \(name) Traces", message: "\(safe.count) items (\(Format.bytes(safe.reduce(0) { $0 + $1.bytes }))) — history, cookies, sessions, downloads and website data. Saved passwords and autofill are kept.", disabled: safe.isEmpty || store.busy) {
                    Task { await store.clean(safe, title: "Clean \(name)") }
                }
                if store.busy { ProgressView().controlSize(.small) }
            }
        }
    }
}
