import AppKit
import MacLeanCore
import SwiftUI

private let privacyFullDiskURL = SystemPane.privacy(.fullDiskAccess).urlString

struct PrivacyFullDiskAccessCard: View {
    let report: PermissionReport

    var body: some View {
        Card("Full Disk Access required") {
            Text("macOS keeps app permissions in the TCC database, which only apps with Full Disk Access can read. Add MacLean (and the bundled maclean CLI) under System Settings › Privacy & Security › Full Disk Access, then rescan.")
                .font(Type.text(12)).foregroundStyle(Theme.muted)
            if let error = report.error {
                Text(error).font(Type.mono(10)).foregroundStyle(Theme.danger).textSelection(.enabled)
            }
            KeyValueRow(key: "Database", value: Format.abbreviated(report.database.isEmpty ? PermissionsScanner.databaseURL(home: EngineActions.home).path : report.database), mono: true)
            Button("Open Full Disk Access Settings") {
                if let url = URL(string: privacyFullDiskURL) { NSWorkspace.shared.open(url) }
            }
            .buttonStyle(EditorialButtonStyle(kind: .primary))
        }
    }
}

// MARK: - Overview by service

struct PrivacyPermissionsScreen: View {
    @ObservedObject private var store = PrivacyStore.shared
    @EnvironmentObject private var nav: Navigator
    @State private var query = ""
    @State private var showApps = false

    var body: some View {
        let grants = store.permissions.grants
        let services = Dictionary(grouping: grants, by: \.service)
            .map { (service: $0.key, grants: $0.value) }
            .filter { query.isEmpty || PrivacyTCC.name($0.service).localizedCaseInsensitiveContains(query) || $0.grants.contains { $0.client.localizedCaseInsensitiveContains(query) } }
            .sorted { $0.grants.count > $1.grants.count }
        let clients = Dictionary(grouping: grants, by: \.client)
            .map { (client: $0.key, grants: $0.value) }
            .filter { query.isEmpty || $0.client.localizedCaseInsensitiveContains(query) || PrivacyTCC.appName($0.client).localizedCaseInsensitiveContains(query) }
            .sorted { $0.grants.filter(\.allowed).count > $1.grants.filter(\.allowed).count }
        let allowed = grants.filter(\.allowed).count
        let peak = Double(services.first?.grants.count ?? 1)
        ScreenScaffold("App Permissions", subtitle: "Camera, microphone, screen recording, files and other privacy grants (TCC).") {
            SearchField(text: $query, prompt: "Service or app")
        } content: {
            RefreshLine(state: store.permissionState) { Task { await store.loadPermissions() } }
            TileGrid(minWidth: 150) {
                StatTile(label: "Grants", value: Format.count(grants.count), icon: "list.bullet")
                StatTile(label: "Allowed", value: Format.count(allowed), detail: grants.isEmpty ? nil : Format.percent(Double(allowed) / Double(grants.count)), tint: Theme.warning, icon: "checkmark.shield")
                StatTile(label: "Denied", value: Format.count(grants.filter { $0.authValue == 0 }.count), tint: Theme.success, icon: "xmark.shield")
                StatTile(label: "Apps", value: Format.count(Set(grants.map(\.client)).count), detail: "\(Set(grants.map(\.service)).count) services", icon: "square.stack.3d.up")
            }
            if !store.permissions.fullDiskAccess && !store.permissionState.isLoading {
                PrivacyFullDiskAccessCard(report: store.permissions)
            }
            if let output = store.lastCommand, output.command.hasPrefix("tccutil") {
                PrivacyCommandCard(output: output)
            }
            if store.permissionState.isLoading && grants.isEmpty {
                LoadingPanel(text: "Reading TCC database…")
            } else if !grants.isEmpty {
                Picker("", selection: $showApps) {
                    Text("By service").tag(false)
                    Text("By app").tag(true)
                }
                .pickerStyle(.segmented).flexibleWidth(240).labelsHidden()
                if showApps {
                    Card("Apps", trailing: "\(clients.count)") {
                        ForEach(clients, id: \.client) { entry in
                            let on = entry.grants.filter(\.allowed).count
                            NavRow(icon: "app", title: PrivacyTCC.appName(entry.client), subtitle: entry.client, value: "\(on) allowed / \(entry.grants.count)", tint: on > 0 ? Theme.warning : Theme.success, route: .privacy(.permissionClient(entry.client)))
                        }
                    }
                } else {
                    Card("Services", trailing: "\(services.count)") {
                        ForEach(services, id: \.service) { entry in
                            let on = entry.grants.filter(\.allowed).count
                            BarRow(label: "\(PrivacyTCC.name(entry.service)) · \(on) allowed, \(entry.grants.count - on) denied", value: Double(entry.grants.count), total: peak, valueText: "\(entry.grants.count)", tint: on > 0 ? Theme.warning : Theme.success) {
                                nav.push(.privacy(.permissionService(entry.service)))
                            }
                        }
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 10)], spacing: 10) {
                        ForEach(services, id: \.service) { entry in
                            NavRow(icon: PrivacyTCC.icon(entry.service), title: PrivacyTCC.name(entry.service), subtitle: PermissionsScanner.tccutilServiceName(entry.service), value: "\(entry.grants.filter(\.allowed).count)/\(entry.grants.count)", route: .privacy(.permissionService(entry.service)))
                        }
                    }
                }
            } else if store.permissions.fullDiskAccess {
                EmptyPanel(icon: "lock.shield", title: "No permission grants recorded")
            }
        }
        .onAppear { if store.permissionState == .idle { Task { await store.loadPermissions() } } }
    }
}

// MARK: - One service

struct PrivacyPermissionServiceScreen: View {
    let service: String
    @ObservedObject private var store = PrivacyStore.shared
    @EnvironmentObject private var nav: Navigator
    @State private var query = ""

    var body: some View {
        let grants = store.permissions.grants.filter { $0.service == service }
            .filter { query.isEmpty || $0.client.localizedCaseInsensitiveContains(query) || PrivacyTCC.appName($0.client).localizedCaseInsensitiveContains(query) }
            .sorted { ($0.allowed ? 0 : 1, $0.client) < ($1.allowed ? 0 : 1, $1.client) }
        let allowed = grants.filter(\.allowed).count
        ScreenScaffold(PrivacyTCC.name(service), subtitle: service) {
            SearchField(text: $query, prompt: "Filter apps")
        } content: {
            RefreshLine(state: store.permissionState) { Task { await store.loadPermissions() } }
            TileGrid(minWidth: 150) {
                StatTile(label: "Apps", value: "\(grants.count)", icon: "square.stack.3d.up")
                StatTile(label: "Allowed", value: "\(allowed)", tint: Theme.warning, icon: "checkmark.shield")
                StatTile(label: "Denied", value: "\(grants.count - allowed)", tint: Theme.success, icon: "xmark.shield")
                StatTile(label: "Last change", value: Format.relative(grants.compactMap(\.lastModified).max()), detail: Format.date(grants.compactMap(\.lastModified).max()), icon: "clock")
            }
            if let output = store.lastCommand, output.command.contains(PermissionsScanner.tccutilServiceName(service)) {
                PrivacyCommandCard(output: output)
            }
            Card("Apps with a decision", trailing: "\(grants.count)") {
                if grants.isEmpty { Text("No apps.").font(Type.text(12)).foregroundStyle(Theme.muted) }
                ForEach(grants) { grant in
                    HStack(spacing: 10) {
                        Image(systemName: grant.allowed ? "checkmark.circle.fill" : "xmark.circle")
                            .foregroundStyle(grant.allowed ? Theme.warning : Theme.success)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(PrivacyTCC.appName(grant.client)).font(Type.text(12, weight: .medium)).foregroundStyle(Theme.ink)
                            Text("\(grant.client) · \(PrivacyTCC.authText(grant.authValue)) · \(Format.date(grant.lastModified))")
                                .font(Type.mono(10)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        if !grant.client.hasPrefix("/"), let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: grant.client) {
                            Button { nav.push(.apps(.appDetail(url.path))) } label: { Label("App", systemImage: "app") }
                                .buttonStyle(EditorialButtonStyle(kind: .inline))
                        }
                        ConfirmButton(title: "Reset", message: "Runs tccutil reset \(PermissionsScanner.tccutilServiceName(service)) \(grant.client). The app will ask for \(PrivacyTCC.name(service)) again next time it needs it.", kind: .ghost) {
                            Task { await store.resetPermission(service: service, client: grant.client) }
                        }
                        Button { nav.push(.privacy(.permissionClient(grant.client))) } label: {
                            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                        }
                        .buttonStyle(.plain).foregroundStyle(Theme.faint)
                    }
                    .padding(.vertical, 4)
                }
            }
            SystemSettingsLink(pane: SystemPane.forService(service), compact: false)
        }
    }
}

// MARK: - One app

struct PrivacyPermissionClientScreen: View {
    let client: String
    @ObservedObject private var store = PrivacyStore.shared
    @EnvironmentObject private var nav: Navigator

    var body: some View {
        let grants = store.permissions.grants.filter { $0.client == client }.sorted { PrivacyTCC.name($0.service) < PrivacyTCC.name($1.service) }
        let allowed = grants.filter(\.allowed)
        ScreenScaffold(PrivacyTCC.appName(client), subtitle: client, systemPane: client.hasPrefix("/") ? .privacySecurity : .notifications(bundleID: client)) {
            if !client.hasPrefix("/"), let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: client) {
                Button("Reveal App") { EngineActions.reveal(url.path) }.buttonStyle(EditorialButtonStyle(kind: .ghost))
                Button("App Details") { nav.push(.apps(.appDetail(url.path))) }.buttonStyle(EditorialButtonStyle(kind: .secondary))
            }
        } content: {
            RefreshLine(state: store.permissionState) { Task { await store.loadPermissions() } }
            TileGrid(minWidth: 150) {
                StatTile(label: "Services", value: "\(grants.count)", icon: "list.bullet")
                StatTile(label: "Allowed", value: "\(allowed.count)", tint: Theme.warning, icon: "checkmark.shield")
                StatTile(label: "Denied", value: "\(grants.count - allowed.count)", tint: Theme.success, icon: "xmark.shield")
                StatTile(label: "Last change", value: Format.relative(grants.compactMap(\.lastModified).max()), icon: "clock")
            }
            if let output = store.lastCommand, output.command.contains(client) {
                PrivacyCommandCard(output: output)
            }
            Card("Permissions", trailing: "\(grants.count)") {
                if grants.isEmpty { Text("No grants recorded for this app.").font(Type.text(12)).foregroundStyle(Theme.muted) }
                ForEach(grants) { grant in
                    HStack(spacing: 10) {
                        Image(systemName: PrivacyTCC.icon(grant.service)).foregroundStyle(grant.allowed ? Theme.warning : Theme.muted).frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(PrivacyTCC.name(grant.service)).font(Type.text(12, weight: .medium)).foregroundStyle(Theme.ink)
                            Text("\(PrivacyTCC.authText(grant.authValue)) · \(Format.date(grant.lastModified))").font(Type.mono(10)).foregroundStyle(Theme.muted)
                        }
                        Spacer()
                        RiskBadge(text: PrivacyTCC.authText(grant.authValue), tint: grant.allowed ? Theme.warning : Theme.success)
                        Button { SystemPane.forService(grant.service).open() } label: {
                            Label("Settings", systemImage: "gearshape")
                        }
                        .buttonStyle(EditorialButtonStyle(kind: .inline))
                        .help("Open System Settings › \(SystemPane.forService(grant.service).path)")
                        ConfirmButton(title: "Reset", message: "Runs tccutil reset \(PermissionsScanner.tccutilServiceName(grant.service)) \(client).", kind: .ghost) {
                            Task { await store.resetPermission(service: grant.service, client: client) }
                        }
                        Button { nav.push(.privacy(.permissionService(grant.service))) } label: {
                            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                        }
                        .buttonStyle(.plain).foregroundStyle(Theme.faint)
                    }
                    .padding(.vertical, 4)
                }
            }
            if !grants.isEmpty {
                ConfirmButton(title: "Reset All \(grants.count) Permissions", message: "Resets every TCC decision for \(client). The app will ask again for each permission.", disabled: store.busy) {
                    Task { await store.resetAllPermissions(client: client, services: grants.map(\.service)) }
                }
            }
        }
    }
}
