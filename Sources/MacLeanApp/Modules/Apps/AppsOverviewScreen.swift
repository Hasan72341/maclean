import MacLeanCore
import SwiftUI

struct AppsOverviewScreen: View {
    @ObservedObject private var store = AppsStore.shared
    @EnvironmentObject private var nav: Navigator

    var body: some View {
        ScreenScaffold("Applications", subtitle: "Installed apps, leftovers, extensions and what is running right now") {
            RefreshLine(state: store.appsState) {
                store.loadApps(force: true)
                store.loadOrphans(force: true)
                store.loadExtensions(force: true)
                store.loadLaunchItems(force: true)
            }
        } content: {
            let apps = store.apps
            let unused = store.unused(days: 90)
            let regular = store.running.filter(\.isRegular)
            TileGrid {
                StatTile(label: "Installed", value: store.appsState.loadedAt == nil && apps.isEmpty ? "…" : Format.count(apps.count), unit: "apps", detail: "\(Format.count(apps.filter(\.inUserFolder).count)) in ~/Applications", icon: "square.stack.3d.up")
                StatTile(label: "Total size", value: Format.bytes(store.totalBytes), detail: apps.isEmpty ? nil : "avg \(Format.bytes(store.totalBytes / Int64(max(1, apps.count))))", tint: Theme.accent, icon: "internaldrive")
                StatTile(label: "Unused 90 days", value: Format.count(unused.count), unit: "apps", detail: Format.bytes(unused.reduce(0) { $0 + $1.bytes }) + " reclaimable", tint: Theme.warning, icon: "moon.zzz")
                StatTile(label: "Leftovers", value: store.orphansState.loadedAt == nil ? "…" : Format.bytes(store.orphanBytes), detail: "\(Format.count(store.visibleOrphans.count)) removed apps · \(Format.count(store.orphanItemCount)) items", tint: Theme.danger, icon: "trash")
                StatTile(label: "Running apps", value: Format.count(regular.count), detail: Format.bytes(regular.reduce(0) { $0 + $1.memory }) + " memory", tint: Theme.info, history: store.runningMemoryHistory, icon: "bolt.horizontal")
                StatTile(label: "App Store", value: Format.count(apps.filter(\.isAppStore).count), unit: "apps", detail: "\(Format.count(apps.filter { !$0.isAppStore }.count)) from other sources", tint: Theme.success, icon: "bag")
            }

            if apps.isEmpty {
                AppsStateGate(state: store.appsState, isEmpty: true, retry: { store.loadApps(force: true) }) { EmptyView() }
            } else {
                HStack(alignment: .top, spacing: 16) {
                    Card("Largest applications", trailing: "top 10 of \(apps.count)") {
                        let top = Array(apps.prefix(10))
                        let maxBytes = Double(top.first?.bytes ?? 1)
                        ForEach(top) { app in
                            BarRow(label: app.name, value: Double(app.bytes), total: maxBytes, valueText: Format.bytes(app.bytes), iconPath: app.path) {
                                nav.push(.apps(.appDetail(app.path)))
                            }
                        }
                    }
                    VStack(spacing: 16) {
                        Card("Where the space goes") {
                            let store = apps.filter(\.isAppStore).reduce(Int64(0)) { $0 + $1.bytes }
                            let user = apps.filter(\.inUserFolder).reduce(Int64(0)) { $0 + $1.bytes }
                            let other = max(0, self.store.totalBytes - store - user)
                            StackedBar(segments: [
                                .init(label: "App Store", value: Double(store), color: Theme.success, text: Format.bytes(store)),
                                .init(label: "Other in /Applications", value: Double(other), color: Theme.accent, text: Format.bytes(other)),
                                .init(label: "~/Applications", value: Double(user), color: Theme.info, text: Format.bytes(user)),
                            ])
                        }
                        Card("Running apps · memory", trailing: "live") {
                            LiveChart(
                                series: [.init(values: store.runningMemoryHistory, color: Theme.info, label: "Apps memory")],
                                format: { Format.bytes(Int64($0)) },
                                height: 90
                            )
                        }
                    }
                    .frame(maxWidth: 380)
                }
            }

            SectionHeader(title: "Browse")
            TileGrid(minWidth: 300) {
                NavRow(icon: "list.bullet", title: "All Applications", subtitle: "Search and sort by size, name or last use", value: Format.count(apps.count), route: .apps(.allApps))
                NavRow(icon: "moon.zzz", title: "Unused Apps", subtitle: "Not opened in 30 to 365 days", value: Format.count(unused.count), tint: Theme.warning, route: .apps(.unusedApps))
                NavRow(icon: "externaldrive", title: "Large Apps", subtitle: "Bundles over 500 MB", value: Format.count(apps.filter { $0.bytes > 500_000_000 }.count), route: .apps(.largeApps))
                NavRow(icon: "clock.arrow.circlepath", title: "Recently Installed", subtitle: "Newest additions first", value: Format.count(apps.filter { ($0.added ?? .distantPast) > Date().addingTimeInterval(-30 * 86_400) }.count), tint: Theme.info, route: .apps(.recentApps))
                NavRow(icon: "building.2", title: "Vendors", subtitle: "Grouped by bundle ID prefix", value: Format.count(Set(apps.map(\.vendor)).count), route: .apps(.vendors))
                NavRow(icon: "bag", title: "App Store Apps", subtitle: "Bundles with a Mac App Store receipt", value: Format.count(apps.filter(\.isAppStore).count), tint: Theme.success, route: .apps(.appStoreApps))
                NavRow(icon: "shippingbox", title: "Other Sources", subtitle: "Downloaded or installed by packages", value: Format.count(apps.filter { !$0.isAppStore }.count), route: .apps(.otherApps))
                NavRow(icon: "cpu", title: "Architectures", subtitle: "Universal, Apple Silicon, Intel-only", value: store.archState.loadedAt == nil ? "Scan" : Format.count(store.archMap.values.filter { AppsScan.architectureClass($0) == "Intel" }.count) + " Intel", route: .apps(.architectures))
            }

            SectionHeader(title: "Clean & manage")
            TileGrid(minWidth: 300) {
                NavRow(icon: "trash", title: "Leftovers", subtitle: "Data of apps that are no longer installed", value: store.orphansState.loadedAt == nil ? "Scan" : Format.bytes(store.orphanBytes), tint: Theme.danger, route: .apps(.orphans))
                NavRow(icon: "puzzlepiece.extension", title: "Extensions", subtitle: "Preference panes, plug-ins, importers, savers", value: store.extensionsState.loadedAt == nil ? "Scan" : Format.count(store.extensions.count), route: .apps(.extensions))
                NavRow(icon: "power", title: "Launch Items", subtitle: "Agents and daemons, matched to their apps", value: store.launchState.loadedAt == nil ? "Scan" : Format.count(store.launchItems.count), tint: Theme.warning, route: .apps(.loginItems))
                NavRow(icon: "bolt.horizontal", title: "Running Apps", subtitle: "Live memory and CPU, quit or force quit", value: Format.count(regular.count), tint: Theme.info, route: .apps(.runningApps))
                NavRow(icon: "arrow.down.circle", title: "System Updates", subtitle: "Pending macOS updates and history", value: store.updatesState.loadedAt == nil ? "Check" : Format.count(store.updates.filter { $0.contains("—") }.count), tint: Theme.success, route: .apps(.systemUpdates))
            }

            if !unused.isEmpty {
                Card("Unused for 90+ days", trailing: Format.bytes(unused.reduce(0) { $0 + $1.bytes })) {
                    ForEach(unused.prefix(5)) { app in
                        AppsAppRow(app: app, trailing: "\(app.daysSinceUse ?? 0) days idle")
                    }
                    if unused.count > 5 {
                        Button("Show all \(unused.count)") { nav.push(.apps(.unusedApps)) }
                            .buttonStyle(EditorialButtonStyle(kind: .inline))
                    }
                }
            }
        }
        .onAppear {
            store.loadApps()
            store.loadOrphans()
            store.loadExtensions()
            store.loadLaunchItems()
        }
    }
}
