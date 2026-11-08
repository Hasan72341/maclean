import MacLeanCore
import SwiftUI

struct SpaceOverviewScreen: View {
    @ObservedObject private var store = SpaceStore.shared
    @ObservedObject private var monitor = SystemMonitor.shared
    @EnvironmentObject private var nav: Navigator

    var body: some View {
        let disk = monitor.latest.disk
        ScreenScaffold("Space & Files", subtitle: "Where your storage goes, and what you can reclaim") {
            Button("Open Space Lens") { nav.push(.space(.lensHome)) }
                .buttonStyle(EditorialButtonStyle(kind: .primary))
        } content: {
            TileGrid {
                StatTile(label: "Capacity", value: Format.bytes(disk.total), detail: "Startup disk", icon: "internaldrive")
                StatTile(label: "Used", value: Format.bytes(disk.used), detail: Format.percent(disk.usedFraction, digits: 1) + " of disk",
                         tint: disk.usedFraction > 0.9 ? Theme.danger : Theme.ink, history: store.usedHistory, icon: "chart.pie")
                StatTile(label: "Free", value: Format.bytes(disk.available), detail: "Purgeable ≈ " + Format.bytes(max(0, disk.availableImportant - disk.available)),
                         tint: Theme.success, history: store.freeHistory, icon: "externaldrive.badge.checkmark")
                StatTile(label: "Disk read", value: Format.rate(disk.readPerSec), detail: "Total " + Format.bytes(disk.totalRead),
                         tint: Theme.info, history: monitor.diskReadHistory, icon: "arrow.down.doc")
                StatTile(label: "Disk write", value: Format.rate(disk.writePerSec), detail: "Total " + Format.bytes(disk.totalWritten),
                         tint: Theme.accent, history: monitor.diskWriteHistory, icon: "arrow.up.doc")
            }

            HStack(alignment: .top, spacing: 16) {
                Card("Startup disk") {
                    HStack(spacing: 22) {
                        RingGauge(value: disk.usedFraction, label: Format.percent(disk.usedFraction), caption: "used",
                                  tint: disk.usedFraction > 0.9 ? Theme.danger : Theme.accent, size: 140, lineWidth: 12)
                        VStack(alignment: .leading, spacing: 6) {
                            KeyValueRow(key: "Total", value: Format.bytes(disk.total), mono: true)
                            KeyValueRow(key: "Used", value: Format.bytes(disk.used), mono: true)
                            KeyValueRow(key: "Available", value: Format.bytes(disk.available), mono: true)
                            KeyValueRow(key: "Available (important)", value: Format.bytes(disk.availableImportant), mono: true)
                            KeyValueRow(key: "Measured in home", value: Format.bytes(measuredTotal), mono: true)
                        }
                    }
                }
                .frame(maxWidth: 520)
                Card("Disk I/O · live") {
                    LiveChart(series: [
                        .init(values: monitor.diskReadHistory, color: Theme.info, label: "Read"),
                        .init(values: monitor.diskWriteHistory, color: Theme.accent, label: "Write"),
                    ], format: { Format.rate($0) }, height: 130)
                    NavRow(icon: "waveform.path.ecg", title: "Disk activity", subtitle: "Throughput and free-space history", route: .space(.diskActivity))
                }
            }

            Card("Home folder breakdown", trailing: breakdownTrailing) {
                VStack(alignment: .leading, spacing: 10) {
                    RefreshLine(state: store.breakdownState) { Task { await store.loadBreakdown(force: true) } }
                    if !store.breakdown.isEmpty {
                        StackedBar(segments: store.breakdown.prefix(8).enumerated().map { i, f in
                            .init(label: f.name, value: Double(f.bytes), color: SpacePalette.color(i), text: Format.bytes(f.bytes))
                        }, total: Double(max(disk.used, measuredTotal)))
                        let top = Double(store.breakdown.first?.bytes ?? 1)
                        ForEach(Array(store.breakdown.enumerated()), id: \.element.id) { i, folder in
                            BarRow(label: folder.name, value: Double(folder.bytes), total: max(top, 1),
                                   valueText: "\(Format.bytes(folder.bytes)) · \(Format.count(folder.files)) files",
                                   tint: SpacePalette.color(i)) {
                                nav.push(.space(folder.name == "Trash" ? .trash : .lens(folder.path)))
                            }
                        }
                    } else if store.breakdownState.isLoading {
                        LoadingPanel(text: "Measuring home folders", detail: "Each folder is sized in parallel")
                    }
                }
            }

            SectionHeader(title: "Explore", detail: "Space Lens and file finders")
            TileGrid(minWidth: 280) {
                NavRow(icon: "circle.hexagongrid", title: "Space Lens", subtitle: "Browse folders by size", value: Format.bytes(measuredTotal), route: .space(.lensHome))
                NavRow(icon: "doc.badge.clock", title: "Large & Old Files", subtitle: "Files over \(Format.megabytes(store.largeMinMB))",
                       value: store.largeState.loadedAt == nil ? nil : bytesOf(store.filteredLarge), route: .space(.largeOldFiles))
                NavRow(icon: "square.on.square", title: "Duplicates", subtitle: "Identical files by content hash",
                       value: store.dupState.loadedAt == nil ? nil : Format.bytes(store.duplicates.reduce(0) { $0 + $1.wastedBytes }), route: .space(.duplicates))
                NavRow(icon: "photo.stack", title: "Similar Images", subtitle: "Near-identical photos",
                       value: store.similarState.loadedAt == nil ? nil : "\(store.similar.count) groups", route: .space(.similarImages))
                NavRow(icon: "chart.bar.doc.horizontal", title: "File Types", subtitle: "Video, audio, images, documents…",
                       value: store.typeReport.map { Format.bytes($0.totalBytes) }, route: .space(.fileTypes))
                NavRow(icon: "arrow.down.circle", title: "Downloads", subtitle: "By type and age",
                       value: store.downloadsState.loadedAt == nil ? nil : bytesOf(store.downloads), route: .space(.downloads))
                NavRow(icon: "archivebox", title: "Archives & Installers", subtitle: "zip, dmg, pkg, tar, rar, 7z",
                       value: store.archivesState.loadedAt == nil ? nil : bytesOf(store.archives), route: .space(.archives))
                NavRow(icon: "opticaldiscdrive", title: "Disk Images", subtitle: "Unused dmg / iso",
                       value: store.diskImagesState.loadedAt == nil ? nil : Format.bytes(store.diskImages.reduce(0) { $0 + $1.bytes }), route: .space(.diskImages))
                NavRow(icon: "hammer", title: "Project Build Files", subtitle: "node_modules, target, .build, Pods…",
                       value: store.projectArtifactsState.loadedAt == nil ? nil : Format.bytes(store.projectArtifacts.reduce(0) { $0 + $1.bytes }), route: .space(.projectArtifacts))
                NavRow(icon: "folder.badge.minus", title: "Empty Folders", subtitle: "Folders with nothing inside",
                       value: store.emptyState.loadedAt == nil ? nil : Format.count(store.emptyFolders.count), route: .space(.emptyFolders))
                NavRow(icon: "icloud", title: "Cloud Storage", subtitle: "iCloud, Dropbox, Drive, OneDrive",
                       value: store.cloud.map { Format.bytes($0.locations.reduce(0) { $0 + $1.bytes }) }, route: .space(.cloud))
                NavRow(icon: "paperclip", title: "Mail Attachments", subtitle: "Downloaded attachments",
                       value: store.mailState.loadedAt == nil ? nil : Format.bytes(store.mail.reduce(0) { $0 + $1.bytes }), route: .space(.mailAttachments))
                NavRow(icon: "trash", title: "Trash", subtitle: "Review and empty",
                       value: trashValue, route: .space(.trash))
                NavRow(icon: "externaldrive.connected.to.line.below", title: "Volumes", subtitle: "Mounted disks and capacity",
                       value: store.volumesState.loadedAt == nil ? nil : "\(store.volumes.count)", route: .space(.volumes))
                NavRow(icon: "waveform.path.ecg", title: "Disk Activity", subtitle: "Live read/write throughput",
                       value: Format.rate(disk.readPerSec + disk.writePerSec), route: .space(.diskActivity))
            }
        }
        .task { await store.loadBreakdown() }
    }

    private var measuredTotal: Int64 { store.breakdown.reduce(0) { $0 + $1.bytes } }

    private var breakdownTrailing: String {
        store.breakdown.isEmpty ? "" : "\(Format.bytes(measuredTotal)) · \(store.breakdown.count) folders"
    }

    private var trashValue: String? {
        if store.trashState.loadedAt != nil { return bytesOf(store.trash) }
        return store.breakdown.first { $0.name == "Trash" }.map { Format.bytes($0.bytes) }
    }

    private func bytesOf(_ files: [SpaceFile]) -> String {
        Format.bytes(files.reduce(0) { $0 + $1.bytes })
    }
}

struct SpaceDiskActivityScreen: View {
    @ObservedObject private var store = SpaceStore.shared
    @ObservedObject private var monitor = SystemMonitor.shared

    var body: some View {
        let disk = monitor.latest.disk
        let reads = monitor.diskReadHistory, writes = monitor.diskWriteHistory
        ScreenScaffold("Disk Activity", subtitle: "Sampled every \(String(format: "%.1f", monitor.intervalSeconds)) s · last \(SystemMonitor.historyLength) samples") {
            TileGrid {
                StatTile(label: "Read now", value: Format.rate(disk.readPerSec), tint: Theme.info, history: reads, icon: "arrow.down.doc")
                StatTile(label: "Write now", value: Format.rate(disk.writePerSec), tint: Theme.accent, history: writes, icon: "arrow.up.doc")
                StatTile(label: "Peak read", value: Format.rate(reads.max() ?? 0), detail: "avg " + Format.rate(avg(reads)), icon: "arrow.up.to.line")
                StatTile(label: "Peak write", value: Format.rate(writes.max() ?? 0), detail: "avg " + Format.rate(avg(writes)), icon: "arrow.up.to.line")
                StatTile(label: "Read since boot", value: Format.bytes(disk.totalRead), icon: "sum")
                StatTile(label: "Written since boot", value: Format.bytes(disk.totalWritten), icon: "sum")
            }
            Card("Throughput · live") {
                LiveChart(series: [
                    .init(values: reads, color: Theme.info, label: "Read"),
                    .init(values: writes, color: Theme.accent, label: "Write"),
                ], format: { Format.rate($0) }, height: 200)
            }
            Card("Free space · live", trailing: Format.bytes(disk.available)) {
                LiveChart(series: [
                    .init(values: store.freeHistory, color: Theme.success, label: "Free"),
                ], format: { Format.bytes(Int64($0)) }, height: 140)
                let change = (store.freeHistory.last ?? 0) - (store.freeHistory.first ?? 0)
                KeyValueRow(key: "Change over window", value: (change >= 0 ? "+" : "−") + Format.bytes(Int64(abs(change))), mono: true)
            }
            Card("Used % · live", trailing: Format.percent(disk.usedFraction, digits: 2)) {
                LiveChart(series: [.init(values: store.usedHistory, color: Theme.warning, label: "Used")],
                          maxValue: 100, format: { String(format: "%.2f%%", $0) }, height: 110)
            }
        }
    }

    private func avg(_ v: [Double]) -> Double { v.isEmpty ? 0 : v.reduce(0, +) / Double(v.count) }
}
