import MacLeanCore
import SwiftUI

struct AppsExtensionsScreen: View {
    let kind: String?
    @ObservedObject private var store = AppsStore.shared
    @EnvironmentObject private var nav: Navigator
    @State private var selected: Set<String> = []
    @State private var query = ""
    @State private var busy = false
    @State private var summary: RemovalSummary?

    var body: some View {
        let scoped = store.extensions.filter { kind == nil || $0.kind == kind }
        let visible = query.isEmpty ? scoped : scoped.filter { $0.name.localizedCaseInsensitiveContains(query) || ($0.bundleID?.localizedCaseInsensitiveContains(query) ?? false) }
        let chosen = scoped.filter { selected.contains($0.path) }
        let systemChosen = chosen.filter(\.isSystem)
        ScreenScaffold(kind ?? "Extensions", subtitle: "Preference panes, QuickLook and Spotlight plug-ins, Internet plug-ins, screen savers, audio units and services") {
            RefreshLine(state: store.extensionsState) { store.loadExtensions(force: true) }
        } content: {
            TileGrid {
                StatTile(label: "Installed", value: Format.count(scoped.count), icon: "puzzlepiece.extension")
                StatTile(label: "Size", value: Format.bytes(scoped.reduce(0) { $0 + $1.bytes }), tint: Theme.accent, icon: "internaldrive")
                StatTile(label: "This user", value: Format.count(scoped.filter { !$0.isSystem }.count), detail: "removable directly", tint: Theme.success, icon: "person")
                StatTile(label: "All users", value: Format.count(scoped.filter(\.isSystem).count), detail: "need administrator", tint: Theme.warning, icon: "lock")
            }

            if kind == nil {
                Card("By type") {
                    ForEach(AppsScan.extensionKinds, id: \.kind) { spec in
                        let items = store.extensions.filter { $0.kind == spec.kind }
                        NavRow(icon: spec.icon, title: spec.kind, subtitle: "~/\(spec.relative) and /\(spec.relative)", value: "\(items.count) · \(Format.bytes(items.reduce(0) { $0 + $1.bytes }))", route: .apps(.extensionKind(spec.kind)))
                    }
                }
            }

            SearchField(text: $query, prompt: "Filter extensions")

            if let summary {
                Card("Last removal", trailing: summary.message) {
                    if !summary.failures.isEmpty { FailureList(failures: summary.failures) }
                }
                AppsAdminPanel(paths: summary.failures.map(\.path))
            }

            AppsStateGate(state: store.extensionsState, isEmpty: scoped.isEmpty, emptyIcon: "puzzlepiece", emptyTitle: "No extensions of this type", retry: { store.loadExtensions(force: true) }) {
                LazyVStack(spacing: 2) {
                    ForEach(visible) { item in
                        CheckRow(
                            isOn: Binding(get: { selected.contains(item.path) }, set: { if $0 { selected.insert(item.path) } else { selected.remove(item.path) } }),
                            title: item.name,
                            subtitle: "\(item.kind) · \(item.scopeTitle) · \(item.version ?? "—") · \(Format.abbreviated(item.path))",
                            value: Format.bytes(item.bytes),
                            badge: item.isSystem ? "admin" : nil,
                            onOpen: { nav.push(.apps(.extensionDetail(item.path))) },
                            onReveal: { EngineActions.reveal(item.path) }
                        )
                    }
                }
            }

            SelectionBar(
                selectedCount: chosen.count,
                totalCount: scoped.count,
                selectedBytes: chosen.reduce(0) { $0 + $1.bytes },
                actionTitle: "Remove Selected",
                confirmMessage: systemChosen.isEmpty
                    ? "Selected extensions move to the Trash. Relaunch the host app (System Settings, Finder, Logic…) to unload them."
                    : "User extensions move to the Trash. \(systemChosen.count) all-users item(s) are listed afterwards for administrator removal.",
                busy: busy,
                onSelectAll: { selected = Set(visible.map(\.path)) },
                onSelectNone: { selected = [] },
                action: {
                    busy = true
                    let items = chosen
                    Task {
                        summary = await store.trashExtensions(items)
                        selected = []
                        busy = false
                    }
                }
            )
        }
        .onAppear { store.loadExtensions() }
    }
}

struct AppsExtensionDetailScreen: View {
    let path: String
    @ObservedObject private var store = AppsStore.shared
    @EnvironmentObject private var nav: Navigator
    @State private var summary: RemovalSummary?
    @State private var signature: String = ""
    @State private var children: [AppsPart] = []

    var body: some View {
        let item = store.extensions.first { $0.path == path }
        ScreenScaffold(item?.name ?? (path as NSString).lastPathComponent, subtitle: Format.abbreviated(path)) {
            RefreshLine(state: store.extensionsState) { store.loadExtensions(force: true) }
        } content: {
            if let item {
                HStack(spacing: 12) {
                    AppsIcon(path: path, size: 48)
                    VStack(alignment: .leading) {
                        Text(item.name).font(Type.display(20, weight: .semibold)).foregroundStyle(Theme.ink)
                        Text(item.kind).font(Type.text(12)).foregroundStyle(Theme.muted)
                    }
                }
                TileGrid {
                    StatTile(label: "Size", value: Format.bytes(item.bytes), tint: Theme.accent, icon: "internaldrive")
                    StatTile(label: "Files", value: Format.count(item.files), icon: "doc.on.doc")
                    StatTile(label: "Scope", value: item.isSystem ? "All users" : "This user", tint: item.isSystem ? Theme.warning : Theme.success, icon: item.isSystem ? "lock" : "person")
                    StatTile(label: "Modified", value: Format.relative(item.modified), detail: Format.date(item.modified), icon: "clock")
                }
                Card("Details") {
                    KeyValueRow(key: "Bundle ID", value: item.bundleID ?? "—", mono: true)
                    KeyValueRow(key: "Version", value: item.version ?? "—")
                    KeyValueRow(key: "Path", value: item.path, mono: true)
                    KeyValueRow(key: "Signature", value: signature.isEmpty ? "Checking…" : signature)
                }
                if !children.isEmpty {
                    Card("Contents") {
                        let peak = Double(children.first?.bytes ?? 1)
                        ForEach(children) { child in
                            BarRow(label: child.name, value: Double(child.bytes), total: peak, valueText: Format.bytes(child.bytes)) { EngineActions.reveal(child.path) }
                        }
                    }
                }
                HStack {
                    Button("Reveal in Finder") { EngineActions.reveal(path) }.buttonStyle(EditorialButtonStyle(kind: .secondary))
                    if !item.isSystem {
                        ConfirmButton(title: "Move to Trash", message: "\(item.name) (\(Format.bytes(item.bytes))) moves to the Trash.", kind: .destructive) {
                            Task {
                                summary = await store.trashExtensions([item])
                                if summary?.failures.isEmpty == true { nav.pop() }
                            }
                        }
                    }
                }
                if item.isSystem {
                    AppsAdminPanel(paths: [item.path])
                }
                if let summary, !summary.failures.isEmpty { FailureList(failures: summary.failures) }
            } else if store.extensionsState.isLoading {
                LoadingPanel(text: "Loading extensions…")
            } else {
                EmptyPanel(icon: "checkmark.circle", title: "Extension no longer installed", message: Format.abbreviated(path))
            }
        }
        .onAppear {
            store.loadExtensions()
            let target = path
            Task {
                async let sig = engine { () -> String in
                    let result = ProcessRunner.run("/usr/bin/codesign", ["-dv", "--verbose=2", target], timeout: 20)
                    guard result.status == 0 else { return "Unsigned or invalid" }
                    let lines = result.stderr.split(separator: "\n")
                    let team = lines.first { $0.hasPrefix("TeamIdentifier=") }.map { String($0.dropFirst(15)) } ?? "—"
                    let authority = lines.first { $0.hasPrefix("Authority=") }.map { String($0.dropFirst(10)) } ?? "ad-hoc"
                    return "\(authority) · team \(team)"
                }
                async let parts = engine { AppsScan.listChildren(path: target + "/Contents") }
                signature = await sig
                children = await parts
            }
        }
    }
}
