import MacLeanCore
import SwiftUI

struct AppsUninstallPlanScreen: View {
    let path: String
    @ObservedObject private var store = AppsStore.shared
    @EnvironmentObject private var nav: Navigator
    @State private var selected: Set<String> = []
    @State private var initialized = false
    @State private var force = false
    @State private var busy = false
    @State private var query = ""

    var body: some View {
        let app = store.app(path)
        let plan = store.plans[path] ?? []
        let chosen = plan.filter { selected.contains($0.path) }
        let isRunning = store.isRunning(path)
        ScreenScaffold("Uninstall \(app?.name ?? AppsNames.appName(path))", subtitle: "Everything the engine found for this app. Review, then move it to the Trash.") {
            RefreshLine(state: store.planStates[path] ?? .idle) {
                initialized = false
                store.loadPlan(path, force: true)
            }
        } content: {
            if let app {
                HStack(spacing: 14) {
                    AppsIcon(path: app.path, size: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(app.name).font(Type.display(20, weight: .semibold)).foregroundStyle(Theme.ink)
                        Text("\(app.bundleID ?? "no bundle ID") · \(app.version ?? "—")").font(Type.mono(11)).foregroundStyle(Theme.muted)
                    }
                }
                TileGrid {
                    StatTile(label: "Items found", value: Format.count(plan.count), detail: "\(Format.count(plan.reduce(0) { $0 + $1.files })) files", icon: "doc.on.doc")
                    StatTile(label: "Total", value: Format.bytes(plan.reduce(0) { $0 + $1.bytes }), tint: Theme.accent, icon: "internaldrive")
                    StatTile(label: "Selected", value: Format.bytes(chosen.reduce(0) { $0 + $1.bytes }), detail: "\(chosen.count) items", tint: Theme.danger, icon: "checkmark.square")
                    StatTile(label: "Need admin", value: Format.count(plan.filter { AppsAdmin.isEligible($0.path) }.count), detail: "root-owned paths", tint: Theme.warning, icon: "lock")
                }

                if isRunning {
                    Card("\(app.name) is running") {
                        Text("Uninstalling a running app can leave it in a broken state and it may recreate files. Quit it first, or enable Force (same as maclean uninstall --force).")
                            .font(Type.text(12)).foregroundStyle(Theme.muted)
                        HStack {
                            Button("Quit \(app.name)") { store.quit(appPath: path, force: false) }.buttonStyle(EditorialButtonStyle(kind: .secondary))
                            Button("Force Quit") { store.quit(appPath: path, force: true) }.buttonStyle(EditorialButtonStyle(kind: .destructive))
                            Toggle("Force uninstall while running", isOn: $force).toggleStyle(.checkbox)
                        }
                    }
                }

                if !plan.isEmpty {
                    let groups = Dictionary(grouping: plan, by: \.group)
                        .map { (group: $0.key, items: $0.value, bytes: $0.value.reduce(Int64(0)) { $0 + $1.bytes }) }
                        .sorted { $0.bytes > $1.bytes }
                    Card("By location") {
                        StackedBar(segments: groups.prefix(6).enumerated().map { index, group in
                            .init(label: group.group, value: Double(group.bytes), color: AppsPalette.color(index), text: Format.bytes(group.bytes))
                        })
                    }
                    SearchField(text: $query, prompt: "Filter paths")
                    ForEach(groups, id: \.group) { group in
                        let items = query.isEmpty ? group.items : group.items.filter { $0.path.localizedCaseInsensitiveContains(query) }
                        if !items.isEmpty {
                            SectionHeader(title: group.group, detail: "\(items.count) · \(Format.bytes(group.bytes))")
                            VStack(spacing: 2) {
                                ForEach(items, id: \.path) { artifact in
                                    AppsArtifactRow(artifact: artifact, isOn: binding(artifact.path))
                                }
                            }
                        }
                    }
                }

                AppsStateGate(state: store.planStates[path] ?? .idle, isEmpty: plan.isEmpty, emptyIcon: "questionmark.folder", emptyTitle: "Nothing to remove", emptyMessage: "The app bundle could not be measured.", retry: { store.loadPlan(path, force: true) }) {
                    EmptyView()
                }

                SelectionBar(
                    selectedCount: chosen.count,
                    totalCount: plan.count,
                    selectedBytes: chosen.reduce(0) { $0 + $1.bytes },
                    actionTitle: "Uninstall",
                    confirmMessage: "\(chosen.count) item(s) move to the Trash. Each path is re-validated by ArtifactCleaner (allowed root, no symlinks, same file identity). Root-owned items will be offered for administrator removal afterwards.",
                    busy: busy || store.busyPaths.contains(path),
                    onSelectAll: { selected = Set(plan.map(\.path)) },
                    onSelectNone: { selected = [] },
                    action: {
                        busy = true
                        let artifacts = chosen
                        Task {
                            let done = await store.uninstall(path, artifacts: artifacts, force: force)
                            busy = false
                            if done {
                                nav.pop()
                                nav.push(.apps(.uninstallResult(path)))
                            }
                        }
                    }
                )
                .disabled(isRunning && !force)
            } else if store.outcomes[path] != nil {
                EmptyPanel(icon: "checkmark.circle", title: "Already uninstalled", actionTitle: "View result") {
                    nav.push(.apps(.uninstallResult(path)))
                }
            } else {
                LoadingPanel(text: "Looking up the app…")
            }
        }
        .onAppear {
            store.ensureApp(path)
            store.loadPlan(path)
            seed()
        }
        .onChange(of: store.plans[path]?.count) { _ in seed() }
        .onChange(of: store.app(path)?.path) { _ in store.loadPlan(path) }
    }

    private func seed() {
        guard !initialized, let plan = store.plans[path] else { return }
        selected = Set(plan.filter(\.autoselect).map(\.path))
        initialized = true
    }

    private func binding(_ key: String) -> Binding<Bool> {
        Binding(get: { selected.contains(key) }, set: { if $0 { selected.insert(key) } else { selected.remove(key) } })
    }
}

struct AppsUninstallResultScreen: View {
    let path: String
    @ObservedObject private var store = AppsStore.shared
    @EnvironmentObject private var nav: Navigator

    var body: some View {
        ScreenScaffold("Uninstall Result", subtitle: Format.abbreviated(path)) {
            if let outcome = store.outcomes[path] {
                AppsOutcomeView(outcome: outcome, key: path)
                HStack {
                    Button("Back to Applications") { nav.popToRoot() }.buttonStyle(EditorialButtonStyle(kind: .primary))
                    Button("Open Trash") { EngineActions.open(AppsScan.home.appendingPathComponent(".Trash").path) }.buttonStyle(EditorialButtonStyle(kind: .secondary))
                    Button("Scan leftovers") { nav.push(.apps(.orphans)) }.buttonStyle(EditorialButtonStyle(kind: .secondary))
                }
            } else {
                EmptyPanel(icon: "tray", title: "No uninstall recorded for this app in this session")
            }
        }
    }
}

struct AppsOutcomeView: View {
    let outcome: AppsUninstallOutcome
    let key: String

    var body: some View {
        let ok = outcome.summary.failures.isEmpty
        TileGrid {
            StatTile(label: "Removed", value: Format.count(outcome.summary.removed), unit: "items", tint: Theme.success, icon: "checkmark.circle")
            StatTile(label: "Freed", value: Format.bytes(outcome.summary.bytes), detail: "moved to the Trash", tint: Theme.accent, icon: "arrow.3.trianglepath")
            StatTile(label: "Failed", value: Format.count(outcome.summary.failures.count), tint: ok ? Theme.ink : Theme.danger, icon: "exclamationmark.triangle")
            StatTile(label: "When", value: outcome.date.formatted(date: .omitted, time: .shortened), detail: Format.relative(outcome.date), icon: "clock")
        }
        Card(outcome.title, trailing: outcome.summary.message) {
            ForEach(outcome.removedPaths, id: \.self) { path in
                HStack {
                    Image(systemName: "checkmark").foregroundStyle(Theme.success)
                    Text(Format.abbreviated(path)).font(Type.mono(10)).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.middle)
                }
            }
        }
        if !outcome.summary.failures.isEmpty {
            Card("Not removed", trailing: "\(outcome.summary.failures.count)") {
                FailureList(failures: outcome.summary.failures)
            }
        }
        AppsAdminPanel(paths: outcome.adminEligible, outcomeKey: key)
        if let output = outcome.adminOutput {
            AppsCopyBox(title: "Administrator output", text: output)
        }
    }
}

// MARK: - Reset

struct AppsResetScreen: View {
    let path: String
    @ObservedObject private var store = AppsStore.shared
    @State private var selected: Set<String> = []
    @State private var initialized = false
    @State private var busy = false
    @State private var showResult = false

    static let excluded: Set<String> = ["Application", "Launch item", "Package receipt", "Privileged helper"]
    static let defaultOn: Set<String> = ["Caches", "Preferences", "Saved state", "Sandbox container", "HTTP storage", "WebKit data", "Logs", "System caches"]

    var body: some View {
        let app = store.app(path)
        let plan = (store.plans[path] ?? []).filter { !Self.excluded.contains($0.group) }
        let chosen = plan.filter { selected.contains($0.path) }
        ScreenScaffold("Reset \(app?.name ?? AppsNames.appName(path))", subtitle: "Return the app to a first-launch state. The app itself stays installed.") {
            RefreshLine(state: store.planStates[path] ?? .idle) {
                initialized = false
                store.loadPlan(path, force: true)
            }
        } content: {
            TileGrid {
                StatTile(label: "Data items", value: Format.count(plan.count), icon: "tray.full")
                StatTile(label: "Data size", value: Format.bytes(plan.reduce(0) { $0 + $1.bytes }), tint: Theme.accent, icon: "internaldrive")
                StatTile(label: "Selected", value: Format.bytes(chosen.reduce(0) { $0 + $1.bytes }), detail: "\(chosen.count) items", tint: Theme.danger, icon: "checkmark.square")
                StatTile(label: "App bundle", value: Format.bytes(app?.bytes ?? 0), detail: "kept", tint: Theme.success, icon: "lock.shield")
            }
            if store.isRunning(path) {
                Card("\(app?.name ?? "The app") is running") {
                    Text("Quit it before resetting, otherwise it will rewrite its preferences and caches on exit.")
                        .font(Type.text(12)).foregroundStyle(Theme.muted)
                    Button("Quit") { store.quit(appPath: path, force: false) }.buttonStyle(EditorialButtonStyle(kind: .secondary))
                }
            }
            Card("What reset removes") {
                Text("Caches, preferences, saved window state, sandbox containers, web storage and logs are selected by default. Application Support and group containers can hold documents or accounts, so they start unselected.")
                    .font(Type.text(12)).foregroundStyle(Theme.muted)
            }
            if showResult, let outcome = store.outcomes[path] {
                AppsOutcomeView(outcome: outcome, key: path)
            }
            AppsStateGate(state: store.planStates[path] ?? .idle, isEmpty: plan.isEmpty, emptyIcon: "archivebox", emptyTitle: "No app data to reset", emptyMessage: "This app has no caches, preferences or containers on disk.", retry: { store.loadPlan(path, force: true) }) {
                VStack(spacing: 2) {
                    ForEach(plan, id: \.path) { artifact in
                        AppsArtifactRow(artifact: artifact, isOn: binding(artifact.path))
                    }
                }
            }
            SelectionBar(
                selectedCount: chosen.count,
                totalCount: plan.count,
                selectedBytes: chosen.reduce(0) { $0 + $1.bytes },
                actionTitle: "Reset App",
                confirmMessage: "Selected app data moves to the Trash. The application bundle is not touched.",
                busy: busy,
                onSelectAll: { selected = Set(plan.map(\.path)) },
                onSelectNone: { selected = [] },
                action: {
                    busy = true
                    let artifacts = chosen
                    Task {
                        await store.reset(path, artifacts: artifacts)
                        busy = false
                        showResult = true
                        initialized = false
                    }
                }
            )
        }
        .onAppear {
            store.ensureApp(path)
            store.loadPlan(path)
            seed()
        }
        .onChange(of: store.plans[path]?.count) { _ in seed() }
        .onChange(of: store.app(path)?.path) { _ in store.loadPlan(path) }
    }

    private func seed() {
        guard !initialized, let plan = store.plans[path] else { return }
        selected = Set(plan.filter { Self.defaultOn.contains($0.group) && $0.autoselect }.map(\.path))
        initialized = true
    }

    private func binding(_ key: String) -> Binding<Bool> {
        Binding(get: { selected.contains(key) }, set: { if $0 { selected.insert(key) } else { selected.remove(key) } })
    }
}
