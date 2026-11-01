import MacLeanCore
import SwiftUI

struct PrivacyOverviewScreen: View {
    @ObservedObject private var store = PrivacyStore.shared
    @EnvironmentObject private var nav: Navigator

    var body: some View {
        ScreenScaffold("Privacy", subtitle: "Browser traces, recent items, app permissions, download history and other personal footprints.") {
            Button("Rescan All") { store.rescanAll() }
                .buttonStyle(EditorialButtonStyle(kind: .secondary))
                .disabled(store.artifactState.isLoading)
        } content: {
            RefreshLine(state: store.artifactState) { Task { await store.loadArtifacts() } }
            tiles
            liveCard
            if case .loading(let text) = store.artifactState, store.artifacts.isEmpty {
                LoadingPanel(text: text, detail: "Safari, Chrome, Firefox, Edge, Brave, Chromium, Arc and macOS recent items")
            } else if case .failed(let message) = store.artifactState {
                ErrorPanel(message: message) { Task { await store.loadArtifacts() } }
            }
            HStack(alignment: .top, spacing: 16) {
                groupsCard
                browsersCard
            }
            cleanAllCard
            toolsCard
            if store.lastResult != nil {
                NavRow(icon: "checkmark.seal", title: "Last clean result", subtitle: store.lastResult.map { "\($0.title) · \(Format.relative($0.date))" }, value: store.lastResult.map { Format.bytes($0.bytes) }, tint: Theme.success, route: .privacy(.result))
            }
        }
        .onAppear { store.loadAllIfNeeded() }
    }

    private var tiles: some View {
        TileGrid(minWidth: 150) {
            StatTile(label: "Privacy items", value: Format.count(store.artifacts.count), detail: "\(store.groups.count) categories", history: store.scanHistory.count > 1 ? store.scanHistory : nil, icon: "hand.raised")
            StatTile(label: "Trace size", value: Format.bytes(store.totalBytes), detail: "\(Format.count(store.artifacts.reduce(0) { $0 + $1.files })) files", tint: Theme.accent, icon: "externaldrive")
            StatTile(label: "Browsers", value: "\(store.browserNames.count)", detail: "\(store.running.count) running now", tint: store.running.isEmpty ? Theme.ink : Theme.warning, history: store.runningHistory.count > 1 ? store.runningHistory : nil, icon: "globe")
            StatTile(label: "Permissions", value: store.permissions.fullDiskAccess ? Format.count(store.allowedGrants) : "—", detail: store.permissions.fullDiskAccess ? "allowed of \(Format.count(store.permissions.grants.count)) grants" : "needs Full Disk Access", tint: store.permissions.fullDiskAccess ? Theme.ink : Theme.warning, icon: "lock.shield")
            StatTile(label: "Downloads logged", value: store.quarantine.map { Format.count($0.count) } ?? "—", detail: "quarantine events", icon: "arrow.down.circle")
            StatTile(label: "Shell history", value: Format.count(store.shellFiles.reduce(0) { $0 + $1.lines }), unit: "lines", detail: Format.bytes(store.shellFiles.reduce(0) { $0 + $1.bytes }), icon: "terminal")
            StatTile(label: "Wi-Fi networks", value: store.wifi.map { "\($0.networks.count)" } ?? "—", detail: store.wifi?.current.map { "on \($0)" } ?? "remembered", icon: "wifi")
            StatTile(label: "Saved app state", value: Format.bytes(store.savedStates.reduce(0) { $0 + $1.bytes }), detail: "\(store.savedStates.count) apps", icon: "macwindow.on.rectangle")
        }
    }

    private var liveCard: some View {
        Card("Live trace footprint", trailing: store.footprintHistory.last.map { Format.bytes(Int64($0)) } ?? "sampling…") {
            if store.footprintHistory.count > 1 {
                LiveChart(
                    series: [LiveChart.Series(values: store.footprintHistory, color: Theme.accent, label: "Browser files")],
                    format: { Format.bytes(Int64($0)) },
                    height: 110
                )
            } else {
                Text("Sampling history, cookie and session file sizes every 3 seconds…")
                    .font(Type.text(11)).foregroundStyle(Theme.muted)
            }
            HStack(spacing: 18) {
                KeyValueRow(key: "Clipboard", value: Format.bytes(Int64(store.pasteboardHistory.last ?? 0)))
                KeyValueRow(key: "Clipboard changes seen", value: Format.count(store.pasteboardChanges))
                KeyValueRow(key: "Browsers open", value: store.running.isEmpty ? "none" : store.running.sorted().joined(separator: ", "))
            }
        }
    }

    private var groupsCard: some View {
        let groups = store.groups
        let maxBytes = Double(groups.first?.bytes ?? 1)
        return Card("By category", trailing: "\(groups.count)") {
            if groups.isEmpty {
                Text(store.artifactState.isLoading ? "Scanning…" : "No privacy traces found.")
                    .font(Type.text(12)).foregroundStyle(Theme.muted)
            }
            ForEach(groups, id: \.name) { group in
                BarRow(
                    label: "\(group.name) · \(group.items.count)",
                    value: Double(group.bytes),
                    total: maxBytes,
                    valueText: Format.bytes(group.bytes),
                    tint: PrivacyGroupStyle.unsafeGroups.contains(group.name) ? Theme.warning : Theme.accent
                ) { nav.push(.privacy(.group(group.name))) }
            }
            if !groups.isEmpty {
                Button("Show all \(store.artifacts.count) items") { nav.push(.privacy(.allItems)) }
                    .buttonStyle(EditorialButtonStyle(kind: .inline))
            }
        }
    }

    private var browsersCard: some View {
        Card("Browsers", trailing: "\(store.browserNames.count) detected") {
            if store.browserNames.isEmpty {
                Text(store.artifactState.isLoading ? "Scanning…" : "No browser data found.")
                    .font(Type.text(12)).foregroundStyle(Theme.muted)
            }
            ForEach(store.browserNames, id: \.self) { name in
                let items = store.artifacts(browser: name)
                NavRow(
                    icon: PrivacyBrowsers.info(name)?.icon ?? "globe",
                    title: name,
                    subtitle: "\(items.count) items" + (store.running.contains(name) ? " · running" : ""),
                    value: Format.bytes(items.reduce(0) { $0 + $1.bytes }),
                    tint: store.running.contains(name) ? Theme.warning : Theme.accent,
                    route: .privacy(.browser(name))
                )
            }
            if !store.browserNames.isEmpty {
                Button("Compare browsers") { nav.push(.privacy(.browsers)) }
                    .buttonStyle(EditorialButtonStyle(kind: .inline))
            }
        }
    }

    private var cleanAllCard: some View {
        let safe = store.safeArtifacts
        let bytes = safe.reduce(0) { $0 + $1.bytes }
        return Card("Clean all safe traces", trailing: "\(safe.count) items · \(Format.bytes(bytes))") {
            Text("Removes browsing history, cookies, sessions, downloads lists, website data and recent-items lists. Saved passwords and autofill are kept; review them in their own categories.")
                .font(Type.text(12)).foregroundStyle(Theme.muted)
            PrivacyCleanOptions()
            HStack {
                ConfirmButton(
                    title: "Clean All Safe",
                    message: "\(safe.count) items (\(Format.bytes(bytes))) will be \(store.permanent ? "deleted permanently" : "moved to the Trash"). You will be signed out of websites. Each path is re-validated by the engine.",
                    disabled: safe.isEmpty || store.busy
                ) {
                    Task { await store.clean(safe, title: "Clean all safe privacy traces") }
                }
                if store.busy { ProgressView().controlSize(.small) }
            }
        }
    }

    private var toolsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "More privacy tools")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 10)], spacing: 10) {
                NavRow(icon: "lock.shield", title: "App Permissions", subtitle: store.permissions.fullDiskAccess ? "\(Set(store.permissions.grants.map(\.service)).count) services" : "Full Disk Access required", value: store.permissions.fullDiskAccess ? Format.count(store.permissions.grants.count) : nil, route: .privacy(.permissions))
                NavRow(icon: "doc.badge.clock", title: "Recent Items", subtitle: "Recent documents, apps, servers", value: Format.count(store.artifacts(group: "Recent items").count), route: .privacy(.recentItems))
                NavRow(icon: "arrow.down.circle", title: "Download History", subtitle: "LaunchServices quarantine events", value: store.quarantine.map { Format.count($0.count) }, route: .privacy(.quarantineEvents))
                NavRow(icon: "terminal", title: "Shell History", subtitle: "\(store.shellFiles.filter(\.exists).count) history files", value: Format.count(store.shellFiles.reduce(0) { $0 + $1.lines }), route: .privacy(.shellHistory))
                NavRow(icon: "macwindow.on.rectangle", title: "Saved App State", subtitle: "Window restore snapshots", value: Format.bytes(store.savedStates.reduce(0) { $0 + $1.bytes }), route: .privacy(.savedState))
                NavRow(icon: "doc.on.clipboard", title: "Clipboard", subtitle: "\(store.pasteboardTypes.count) types on the pasteboard", value: Format.bytes(Int64(store.pasteboardTypes.reduce(0) { $0 + $1.bytes })), route: .privacy(.clipboard))
                NavRow(icon: "wifi", title: "Wi-Fi Networks", subtitle: store.wifi?.device.map { "Remembered on \($0)" } ?? "Preferred networks", value: store.wifi.map { "\($0.networks.count)" }, route: .privacy(.wifiNetworks))
                NavRow(icon: "eye", title: "Quick Look Cache", subtitle: "Thumbnail previews of viewed files", value: store.quickLook.map { Format.bytes($0.bytes) }, route: .privacy(.quickLookCache))
            }
        }
    }
}
