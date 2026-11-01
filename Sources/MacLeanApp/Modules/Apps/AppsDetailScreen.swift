import MacLeanCore
import SwiftUI

struct AppsDetailScreen: View {
    let path: String
    @ObservedObject private var store = AppsStore.shared
    @EnvironmentObject private var nav: Navigator

    var body: some View {
        let app = store.app(path)
        ScreenScaffold(app?.name ?? AppsNames.appName(path), subtitle: Format.abbreviated(path)) {
            RefreshLine(state: store.bundleStates[path] ?? .idle) {
                store.loadBundleInfo(path, force: true)
                store.loadPlan(path, force: true)
            }
        } content: {
            if let app {
                content(app)
            } else if !FileManager.default.fileExists(atPath: path) {
                EmptyPanel(icon: "checkmark.circle", title: "This app is no longer installed", message: Format.abbreviated(path), actionTitle: "Back to Applications") {
                    nav.popToRoot()
                }
            } else {
                LoadingPanel(text: "Reading \(AppsNames.appName(path))…")
            }
        }
        .onAppear {
            store.ensureApp(path)
            store.loadBundleInfo(path)
            store.loadPlan(path)
            store.loadLaunchItems()
        }
        .onChange(of: store.app(path)?.path) { _ in store.loadPlan(path) }
    }

    @ViewBuilder
    private func content(_ app: AppsApp) -> some View {
        let info = store.bundleInfos[path]
        let plan = store.plans[path] ?? []
        let leftovers = plan.filter { $0.path != PathCanon.resolve(app.path) && $0.group != "Application" }
        let leftoverBytes = leftovers.reduce(Int64(0)) { $0 + $1.bytes }
        let runningApp = store.runningApp(for: path)
        let launch = store.launchItems(for: app)

        HStack(alignment: .center, spacing: 16) {
            AppsIcon(path: app.path, size: 72)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(app.name).font(Type.display(26, weight: .semibold)).foregroundStyle(Theme.ink)
                    if app.isAppStore { RiskBadge(text: "App Store", tint: Theme.success) }
                    if runningApp != nil { RiskBadge(text: "Running", tint: Theme.info) }
                }
                Text("Version \(app.version ?? "—")\(info?.build.map { " (\($0))" } ?? "") · \(app.bundleID ?? "no bundle ID")")
                    .font(Type.mono(11)).foregroundStyle(Theme.muted)
                HStack(spacing: 8) {
                    Button("Open") { store.launch(app.path) }.buttonStyle(EditorialButtonStyle(kind: .secondary))
                    Button("Reveal in Finder") { EngineActions.reveal(app.path) }.buttonStyle(EditorialButtonStyle(kind: .secondary))
                    if let runningApp {
                        Button("Quit") { store.quit(pid: runningApp.pid, force: false) }.buttonStyle(EditorialButtonStyle(kind: .secondary))
                        ConfirmButton(title: "Force Quit", message: "Unsaved changes in \(app.name) will be lost.", kind: .destructive) {
                            store.quit(pid: runningApp.pid, force: true)
                        }
                    }
                    Button("Reset…") { nav.push(.apps(.appReset(app.path))) }.buttonStyle(EditorialButtonStyle(kind: .secondary))
                    Button("Uninstall…") { nav.push(.apps(.uninstallPlan(app.path))) }.buttonStyle(EditorialButtonStyle(kind: .destructive))
                }
                .padding(.top, 4)
            }
        }

        TileGrid {
            StatTile(label: "App size", value: Format.bytes(app.bytes), detail: info.map { "\(Format.count($0.files)) files" }, tint: Theme.accent, icon: "internaldrive")
            StatTile(label: "Leftovers", value: store.plans[path] == nil ? "…" : Format.bytes(leftoverBytes), detail: "\(leftovers.count) locations", tint: Theme.warning, icon: "tray.full")
            StatTile(label: "Last used", value: app.daysSinceUse.map { $0 == 0 ? "Today" : "\($0)d ago" } ?? "Never", detail: Format.date(app.lastUsed), icon: "clock")
            StatTile(label: "Added", value: Format.relative(app.added), detail: Format.date(app.added), icon: "calendar.badge.plus")
            if let runningApp {
                StatTile(label: "Memory", value: Format.bytes(runningApp.memory), detail: "pid \(runningApp.pid)", tint: Theme.info, history: store.pidMemory[runningApp.pid], icon: "memorychip")
                StatTile(label: "CPU", value: String(format: "%.1f%%", runningApp.cpu), detail: "since \(Format.relative(runningApp.launched))", tint: Theme.accent, history: store.pidCPU[runningApp.pid], icon: "cpu")
            }
        }

        if let runningApp {
            Card("Live usage", trailing: "pid \(runningApp.pid) · \(runningApp.arch)") {
                LiveChart(series: [.init(values: store.pidCPU[runningApp.pid] ?? [], color: Theme.accent, label: "CPU %")], format: { String(format: "%.1f%%", $0) }, height: 90)
                LiveChart(series: [.init(values: store.pidMemory[runningApp.pid] ?? [], color: Theme.info, label: "Memory")], format: { Format.bytes(Int64($0)) }, height: 90)
            }
        }

        HStack(alignment: .top, spacing: 16) {
            Card("Information") {
                KeyValueRow(key: "Bundle ID", value: app.bundleID ?? "—", mono: true)
                KeyValueRow(key: "Version", value: app.version ?? "—")
                KeyValueRow(key: "Build", value: info?.build ?? "—")
                KeyValueRow(key: "Source", value: (info?.hasReceipt ?? app.isAppStore) ? "Mac App Store (receipt present)" : "Other (no App Store receipt)")
                KeyValueRow(key: "Minimum macOS", value: info?.minimumOS ?? "—")
                KeyValueRow(key: "Category", value: info?.category ?? "—")
                KeyValueRow(key: "Architectures", value: info.map { $0.architectures.isEmpty ? "—" : $0.architectures.joined(separator: ", ") + " · " + AppsScan.architectureClass($0.architectures) } ?? "…")
                KeyValueRow(key: "Executable", value: info.map { Format.bytes($0.executableBytes) } ?? "…")
                KeyValueRow(key: "Location", value: app.inUserFolder ? "~/Applications" : "/Applications")
                KeyValueRow(key: "Created", value: Format.date(info?.created))
                KeyValueRow(key: "Modified", value: Format.date(app.modified))
                KeyValueRow(key: "Languages", value: info.map { "\($0.localizations.count)" } ?? "…")
                if let copyright = info?.copyright {
                    Text(copyright).font(Type.text(10)).foregroundStyle(Theme.faint).lineLimit(2)
                }
            }
            Card("Signature & security") {
                if let info {
                    HStack(spacing: 6) {
                        RiskBadge(text: info.signed ? "Signed" : "Unsigned", tint: info.signed ? Theme.success : Theme.danger)
                        RiskBadge(text: info.gatekeeperAccepted ? "Gatekeeper OK" : "Gatekeeper rejected", tint: info.gatekeeperAccepted ? Theme.success : Theme.warning)
                        if info.hardenedRuntime { RiskBadge(text: "Hardened", tint: Theme.info) }
                        if info.sandboxed { RiskBadge(text: "Sandboxed", tint: Theme.info) }
                    }
                    KeyValueRow(key: "Team ID", value: info.teamID ?? "—", mono: true)
                    KeyValueRow(key: "Identifier", value: info.signingIdentifier ?? "—", mono: true)
                    KeyValueRow(key: "Gatekeeper", value: info.gatekeeper)
                    ForEach(Array(info.signatureLines.enumerated()), id: \.offset) { line in
                        KeyValueRow(key: line.element.0, value: line.element.1, mono: true)
                    }
                    KeyValueRow(key: "Entitlements", value: "\(info.entitlementKeys.count)")
                    if !info.authorities.isEmpty {
                        SectionHeader(title: "Certificate chain")
                        ForEach(info.authorities, id: \.self) { authority in
                            Text(authority).font(Type.mono(10)).foregroundStyle(Theme.muted)
                        }
                    }
                    if let error = info.signatureError {
                        Text(error).font(Type.mono(10)).foregroundStyle(Theme.danger).lineLimit(4)
                    }
                } else {
                    LoadingPanel(text: "Running codesign and spctl…")
                }
            }
        }

        Card("Leftovers on disk", trailing: store.plans[path] == nil ? "scanning…" : "\(leftovers.count) · \(Format.bytes(leftoverBytes))") {
            if store.plans[path] == nil {
                ProgressView().controlSize(.small)
            } else if leftovers.isEmpty {
                Text("No caches, preferences, containers or launch items found outside the bundle.")
                    .font(Type.text(12)).foregroundStyle(Theme.muted)
            } else {
                let groups = Dictionary(grouping: leftovers, by: \.group)
                    .map { (group: $0.key, bytes: $0.value.reduce(Int64(0)) { $0 + $1.bytes }, count: $0.value.count) }
                    .sorted { $0.bytes > $1.bytes }
                let peak = Double(groups.first?.bytes ?? 1)
                ForEach(groups, id: \.group) { group in
                    BarRow(label: "\(group.group) · \(group.count)", value: Double(group.bytes), total: peak, valueText: Format.bytes(group.bytes), tint: Theme.warning)
                }
            }
            NavRow(icon: "arrow.counterclockwise", title: "Reset app", subtitle: "Remove caches, preferences, saved state and containers — keep the app", route: .apps(.appReset(app.path)))
            NavRow(icon: "trash", title: "Uninstall completely", subtitle: "App plus every leftover you select", value: Format.bytes(app.bytes + leftoverBytes), tint: Theme.danger, route: .apps(.uninstallPlan(app.path)))
        }

        Card("Launch items", trailing: "\(launch.count)") {
            if launch.isEmpty {
                Text(store.launchState.isLoading ? "Reading launch agents…" : "No LaunchAgents or LaunchDaemons reference this app.")
                    .font(Type.text(12)).foregroundStyle(Theme.muted)
            }
            ForEach(launch) { match in
                HStack {
                    Image(systemName: match.item.requiresRoot ? "lock" : "power").foregroundStyle(Theme.warning)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(match.item.label).font(Type.text(12, weight: .medium)).foregroundStyle(Theme.ink)
                        Text("\(match.item.kind) · \(match.item.scope) · \(Format.abbreviated(match.item.path))").font(Type.mono(10)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    if match.item.broken { RiskBadge(text: "broken", tint: Theme.danger) }
                    Button { EngineActions.reveal(match.item.path) } label: { Image(systemName: "magnifyingglass") }.buttonStyle(.plain)
                }
            }
            if let helpers = info?.loginHelpers, !helpers.isEmpty {
                KeyValueRow(key: "Embedded login helpers", value: helpers.joined(separator: ", "))
            }
            NavRow(icon: "power", title: "All launch items", route: .apps(.loginItems))
        }

        if let bundleID = app.bundleID {
            AppSystemSettingsCard(bundleID: bundleID, appName: app.name, hasLoginItems: !launch.isEmpty || !(info?.loginHelpers.isEmpty ?? true), hasPlugins: !(info?.plugins.isEmpty ?? true))
        }

        NavRow(icon: "shippingbox", title: "Bundle contents", subtitle: "Frameworks, resources, plug-ins and languages", value: info.map { "\($0.parts.count) parts" }, route: .apps(.appAnatomy(app.path)))
        if app.bundleID != nil {
            NavRow(icon: "building.2", title: "More from \(app.vendor)", value: Format.count(store.apps.filter { $0.vendor == app.vendor }.count), route: .apps(.vendorDetail(app.vendor)))
        }
    }
}

// MARK: - Bundle anatomy

struct AppsAnatomyScreen: View {
    let path: String
    @ObservedObject private var store = AppsStore.shared

    var body: some View {
        let info = store.bundleInfos[path]
        ScreenScaffold("\(AppsNames.appName(path)) Bundle", subtitle: Format.abbreviated(path) + "/Contents") {
            RefreshLine(state: store.bundleStates[path] ?? .idle) { store.loadBundleInfo(path, force: true) }
        } content: {
            if let info {
                let total = info.parts.reduce(Int64(0)) { $0 + $1.bytes }
                TileGrid {
                    StatTile(label: "Bundle", value: Format.bytes(total), detail: "\(Format.count(info.files)) files", tint: Theme.accent, icon: "shippingbox")
                    StatTile(label: "Executable", value: Format.bytes(info.executableBytes), detail: info.architectures.joined(separator: " + "), icon: "terminal")
                    StatTile(label: "Languages", value: Format.count(info.localizations.count), unit: ".lproj", icon: "globe")
                    StatTile(label: "Plug-ins & helpers", value: Format.count(info.plugins.count), detail: Format.bytes(info.plugins.reduce(0) { $0 + $1.bytes }), icon: "puzzlepiece")
                }
                Card("Contents", trailing: Format.bytes(total)) {
                    StackedBar(segments: info.parts.prefix(6).enumerated().map { index, part in
                        .init(label: part.name, value: Double(part.bytes), color: AppsPalette.color(index), text: Format.bytes(part.bytes))
                    })
                    let peak = Double(info.parts.first?.bytes ?? 1)
                    ForEach(info.parts) { part in
                        BarRow(label: "\(part.name) · \(Format.count(part.files)) files", value: Double(part.bytes), total: peak, valueText: Format.bytes(part.bytes)) {
                            EngineActions.reveal(part.path)
                        }
                    }
                }
                if !info.plugins.isEmpty {
                    Card("Embedded plug-ins, extensions and helpers", trailing: "\(info.plugins.count)") {
                        let peak = Double(info.plugins.first?.bytes ?? 1)
                        ForEach(info.plugins) { part in
                            BarRow(label: part.name, value: Double(part.bytes), total: peak, valueText: Format.bytes(part.bytes), tint: Theme.info) {
                                EngineActions.reveal(part.path)
                            }
                        }
                    }
                }
                if !info.localizations.isEmpty {
                    Card("Localizations", trailing: "\(info.localizations.count)") {
                        Text(info.localizations.joined(separator: " · "))
                            .font(Type.mono(11)).foregroundStyle(Theme.muted)
                            .textSelection(.enabled)
                        Text("Language files are part of the signed bundle; removing them breaks the code signature, so MacLean only reports them.")
                            .font(Type.text(11)).foregroundStyle(Theme.faint)
                    }
                }
                if !info.entitlementKeys.isEmpty {
                    Card("Entitlements", trailing: "\(info.entitlementKeys.count)") {
                        ForEach(info.entitlementKeys, id: \.self) { key in
                            Text(key).font(Type.mono(10)).foregroundStyle(Theme.ink).textSelection(.enabled)
                        }
                    }
                }
            } else if case .failed(let message) = store.bundleStates[path] ?? .idle {
                ErrorPanel(message: message) { store.loadBundleInfo(path, force: true) }
            } else {
                LoadingPanel(text: "Measuring bundle contents…")
            }
        }
        .onAppear { store.loadBundleInfo(path) }
    }
}

// MARK: - System Settings for one app

/// Every System Settings pane that holds a setting for this app, with the
/// app's current privacy decisions and a direct link to each pane.
struct AppSystemSettingsCard: View {
    let bundleID: String
    let appName: String
    let hasLoginItems: Bool
    let hasPlugins: Bool
    @ObservedObject private var privacy = PrivacyStore.shared
    @EnvironmentObject private var nav: Navigator

    var body: some View {
        let grants = privacy.permissions.grants.filter { $0.client == bundleID }
            .sorted { PrivacyTCC.name($0.service) < PrivacyTCC.name($1.service) }
        Card("System Settings for \(appName)", trailing: grants.isEmpty ? nil : "\(grants.count) permission\(grants.count == 1 ? "" : "s")") {
            if privacy.permissionState.isLoading {
                HStack { ProgressView().controlSize(.small); Text("Reading privacy decisions…").font(Type.text(11)).foregroundStyle(Theme.muted) }
            } else if !privacy.permissions.fullDiskAccess && grants.isEmpty {
                HStack {
                    Text("Privacy decisions are readable only with Full Disk Access.").font(Type.text(11)).foregroundStyle(Theme.muted)
                    Spacer()
                    SystemSettingsLink(pane: .privacy(.fullDiskAccess))
                }
            } else if grants.isEmpty {
                Text("\(appName) has not asked for any privacy permission.").font(Type.text(11)).foregroundStyle(Theme.muted)
            }
            ForEach(grants) { grant in
                let pane = SystemPane.forService(grant.service)
                HStack(spacing: 10) {
                    Image(systemName: PrivacyTCC.icon(grant.service)).foregroundStyle(grant.allowed ? Theme.warning : Theme.muted).frame(width: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(PrivacyTCC.name(grant.service)).font(Type.text(12, weight: .medium)).foregroundStyle(Theme.ink)
                        Text(pane.path).font(Type.mono(9)).foregroundStyle(Theme.faint)
                    }
                    Spacer()
                    RiskBadge(text: PrivacyTCC.authText(grant.authValue), tint: grant.allowed ? Theme.warning : Theme.success)
                    Button { pane.open() } label: { Label("Open", systemImage: "gearshape") }
                        .buttonStyle(EditorialButtonStyle(kind: .inline))
                        .help("System Settings › \(pane.path)")
                }
            }
            Hairline()
            row(.notifications(bundleID: bundleID), "Notifications", "Alerts, badges and sounds from \(appName)")
            if hasLoginItems {
                row(.loginItems, "Login items & background", "Allow or stop \(appName) running in the background")
            }
            if hasPlugins {
                row(.extensions, "Extensions", "Share, Finder, Quick Look and other extensions it provides")
            }
            row(.privacy(.fullDiskAccess), "Full Disk Access", "Grant or revoke access to protected files")
            row(.privacy(.appManagement), "App Management", "Whether \(appName) may update or delete other apps")
            NavRow(icon: "hand.raised", title: "All privacy decisions for \(appName)", subtitle: "Reset any permission so the app asks again", value: "\(grants.count)", tint: Theme.info, route: .privacy(.permissionClient(bundleID)))
        }
        .task {
            if privacy.permissionState == .idle { await privacy.loadPermissions() }
        }
    }

    private func row(_ pane: SystemPane, _ title: String, _ subtitle: String) -> some View {
        NavRow(icon: pane.icon, title: title, subtitle: "\(subtitle) · System Settings › \(pane.path)", tint: Theme.muted, action: { pane.open() })
    }
}
