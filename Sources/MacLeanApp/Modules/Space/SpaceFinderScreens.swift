import MacLeanCore
import SwiftUI

// MARK: - Large & old files

struct SpaceLargeFilesScreen: View {
    @ObservedObject private var store = SpaceStore.shared
    @EnvironmentObject private var nav: Navigator

    var body: some View {
        let files = store.filteredLarge
        let total = files.reduce(Int64(0)) { $0 + $1.bytes }
        ScreenScaffold("Large & Old Files", subtitle: "Files in your home folder (excluding Library and hidden items)") {
            if store.largeState.isLoading {
                Button("Stop") { store.cancel("large") }.buttonStyle(EditorialButtonStyle(kind: .secondary))
            }
        } content: {
            RefreshLine(state: store.largeState) { Task { await store.scanLarge() } }
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    SpaceChips(label: "Min size", options: [(50, "50 MB"), (100, "100 MB"), (500, "500 MB"), (1000, "1 GB")], value: $store.largeMinMB)
                    SpaceChips(label: "Not modified in", options: [(0, "Any age"), (30, "30 days"), (90, "90 days"), (180, "6 months"), (365, "1 year")], value: $store.largeOlderDays)
                }
            }
            if store.largeState.isLoading {
                SpaceProgressPanel(title: "Scanning home folder", info: store.progress["large"]) { store.cancel("large") }
            }
            if case .failed(let m) = store.largeState { ErrorPanel(message: m) }
            if store.largeState == .idle {
                EmptyPanel(icon: "doc.badge.clock", title: "Find large and forgotten files", message: "Scans every file in your home folder over 50 MB. Filters apply instantly afterwards.", actionTitle: "Scan Home Folder") {
                    Task { await store.scanLarge() }
                }
            } else {
                TileGrid {
                    StatTile(label: "Matching files", value: Format.count(files.count), detail: "of \(Format.count(store.largeFiles.count)) over 50 MB", icon: "doc.on.doc")
                    StatTile(label: "Total size", value: Format.bytes(total), tint: Theme.accent, icon: "internaldrive")
                    StatTile(label: "Largest", value: files.first.map { Format.bytes($0.bytes) } ?? "—", detail: files.first?.name, icon: "arrow.up.right.circle")
                    StatTile(label: "Over 1 year old", value: Format.count(files.filter { SpaceAgeBucket.of($0.modified) == .older }.count), icon: "clock.arrow.circlepath")
                }
                Card("By category") {
                    let groups = Dictionary(grouping: files, by: \.kind)
                    StackedBar(segments: SpaceKind.allCases.compactMap { k in
                        guard let list = groups[k] else { return nil }
                        let b = list.reduce(Int64(0)) { $0 + $1.bytes }
                        return .init(label: k.title, value: Double(b), color: k.color, text: "\(Format.bytes(b)) · \(list.count)")
                    })
                }
                SpaceFileList(
                    files: files,
                    title: "Files",
                    activityTitle: "Large & old files moved to Trash",
                    badge: { f in SpaceAgeBucket.of(f.modified) == .older ? ("Old", Theme.warning) : nil },
                    detail: { f in "\(Format.abbreviated((f.path as NSString).deletingLastPathComponent)) · modified \(Format.relative(f.modified)) · opened \(Format.relative(f.accessed))" }
                )
            }
        }
        .task { if store.largeState == .idle { await store.scanLarge() } }
    }
}

// MARK: - Empty folders

struct SpaceEmptyFoldersScreen: View {
    @ObservedObject private var store = SpaceStore.shared

    var body: some View {
        ScreenScaffold("Empty Folders", subtitle: "Folders in your home with no content (Finder metadata ignored)") {
            if store.emptyState.isLoading {
                Button("Stop") { store.cancel("empty") }.buttonStyle(EditorialButtonStyle(kind: .secondary))
            }
        } content: {
            RefreshLine(state: store.emptyState) { Task { await store.scanEmptyFolders() } }
            if store.emptyState.isLoading {
                SpaceProgressPanel(title: "Walking folders", info: store.progress["empty"]) { store.cancel("empty") }
            }
            if store.emptyState.loadedAt != nil {
                let onlyMeta = store.emptyFolders.filter { $0.note != "Empty" }.count
                TileGrid {
                    StatTile(label: "Empty folders", value: Format.count(store.emptyFolders.count), icon: "folder.badge.minus")
                    StatTile(label: "Truly empty", value: Format.count(store.emptyFolders.count - onlyMeta), icon: "folder")
                    StatTile(label: "Finder metadata only", value: Format.count(onlyMeta), icon: "doc.badge.gearshape")
                    StatTile(label: "Items scanned", value: Format.count(store.progress["empty"]?.scanned ?? 0), icon: "magnifyingglass")
                }
                SpaceFileList(
                    files: store.emptyFolders,
                    title: "Folders",
                    activityTitle: "Empty folders moved to Trash",
                    detail: { f in "\(Format.abbreviated(f.path)) · \(f.note) · created \(Format.relative(f.created))" },
                    showSizes: false
                )
            }
        }
        .task { if store.emptyState == .idle { await store.scanEmptyFolders() } }
    }
}

// MARK: - Archives

struct SpaceArchivesScreen: View {
    @ObservedObject private var store = SpaceStore.shared
    @State private var ext: String = "all"

    var body: some View {
        let all = store.archives
        let files = ext == "all" ? all : all.filter { $0.ext == ext }
        ScreenScaffold("Archives & Installers", subtitle: ".zip .tar .gz .rar .7z .pkg .dmg and more in your home folder") {
            if store.archivesState.isLoading {
                Button("Stop") { store.cancel("archives") }.buttonStyle(EditorialButtonStyle(kind: .secondary))
            }
        } content: {
            RefreshLine(state: store.archivesState) { Task { await store.scanArchives() } }
            if store.archivesState.isLoading {
                SpaceProgressPanel(title: "Searching for archives", info: store.progress["archives"]) { store.cancel("archives") }
            }
            if store.archivesState.loadedAt != nil {
                let byExt = Dictionary(grouping: all, by: \.ext).sorted { a, b in a.value.reduce(0) { $0 + $1.bytes } > b.value.reduce(0) { $0 + $1.bytes } }
                TileGrid {
                    StatTile(label: "Archives", value: Format.count(all.count), icon: "archivebox")
                    StatTile(label: "Total size", value: Format.bytes(all.reduce(0) { $0 + $1.bytes }), tint: Theme.accent, icon: "internaldrive")
                    StatTile(label: "Older than 90 days", value: Format.count(all.filter { ($0.modified ?? .distantFuture) < Date().addingTimeInterval(-90 * 86_400) }.count), icon: "clock")
                    StatTile(label: "Formats", value: Format.count(byExt.count), icon: "square.grid.3x2")
                }
                Card("By format") {
                    let top = Double(byExt.first?.value.reduce(0) { $0 + $1.bytes } ?? 1)
                    ForEach(Array(byExt.enumerated()), id: \.element.key) { i, entry in
                        let b = entry.value.reduce(Int64(0)) { $0 + $1.bytes }
                        BarRow(label: "." + entry.key, value: Double(b), total: max(top, 1), valueText: "\(Format.bytes(b)) · \(entry.value.count)", tint: SpacePalette.color(i)) {
                            ext = ext == entry.key ? "all" : entry.key
                        }
                    }
                    if ext != "all" {
                        Button("Showing .\(ext) only — show all") { ext = "all" }.buttonStyle(EditorialButtonStyle(kind: .inline))
                    }
                }
                SpaceFileList(
                    files: files,
                    title: ext == "all" ? "All archives" : ".\(ext) files",
                    activityTitle: "Archives moved to Trash",
                    badge: { f in SpaceKind.installerExtensions.contains(f.ext) ? ("Installer", Theme.info) : nil }
                )
                .id(ext)
            }
        }
        .task { if store.archivesState == .idle { await store.scanArchives() } }
    }
}

// MARK: - File types

struct SpaceFileTypesScreen: View {
    @ObservedObject private var store = SpaceStore.shared
    @EnvironmentObject private var nav: Navigator

    var body: some View {
        ScreenScaffold("File Types", subtitle: "Breakdown of \(Format.abbreviated(store.typeRoot)) by kind") {
            if store.typeState.isLoading {
                Button("Stop") { store.cancel("types") }.buttonStyle(EditorialButtonStyle(kind: .secondary))
            }
        } content: {
            Card("Root folder") {
                HStack(spacing: 8) {
                    SpaceChips(label: "Root", options: [(SpacePaths.home, "Home")] + ["Documents", "Downloads", "Desktop", "Pictures", "Movies", "Music"].map { (SpacePaths.url($0).path, $0) }, value: $store.typeRoot)
                    Spacer()
                    Button("Choose…") {
                        if let p = store.chooseFolders(multiple: false).first { store.typeRoot = p }
                    }
                    .buttonStyle(EditorialButtonStyle(kind: .secondary))
                    Button("Analyse") { Task { await store.scanTypes() } }
                        .buttonStyle(EditorialButtonStyle(kind: .primary))
                        .disabled(store.typeState.isLoading)
                }
            }
            RefreshLine(state: store.typeState) { Task { await store.scanTypes() } }
            if store.typeState.isLoading {
                SpaceProgressPanel(title: "Classifying files", info: store.progress["types"]) { store.cancel("types") }
            }
            if let report = store.typeReport {
                if report.root != store.typeRoot {
                    Text("Showing results for \(Format.abbreviated(report.root)). Press Analyse to scan the new root.").font(Type.text(11)).foregroundStyle(Theme.warning)
                }
                let kinds = SpaceKind.allCases.map { ($0, report.stats[$0.rawValue] ?? SpaceKindStat()) }.sorted { $0.1.bytes > $1.1.bytes }
                TileGrid {
                    StatTile(label: "Total", value: Format.bytes(report.totalBytes), detail: "\(Format.count(report.totalCount)) files", icon: "sum")
                    ForEach(kinds.prefix(5), id: \.0) { kind, stat in
                        StatTile(label: kind.title, value: Format.bytes(stat.bytes), detail: "\(Format.count(stat.count)) files · \(Format.percent(Double(stat.bytes) / Double(max(report.totalBytes, 1))))", tint: kind.color, icon: kind.icon)
                    }
                }
                Card("Composition") {
                    StackedBar(segments: kinds.map { .init(label: $0.0.title, value: Double($0.1.bytes), color: $0.0.color, text: Format.bytes($0.1.bytes)) })
                }
                SectionHeader(title: "Categories", detail: "Open a category to review and remove files")
                ForEach(kinds, id: \.0) { kind, stat in
                    NavRow(icon: kind.icon, title: kind.title, subtitle: "\(Format.count(stat.count)) files · \(Format.count(report.files[kind.rawValue]?.count ?? 0)) over 256 KB listed", value: Format.bytes(stat.bytes), tint: kind.color, route: .space(.typeFiles(kind.rawValue)))
                }
                NavRow(icon: "textformat", title: "By extension", subtitle: "\(report.extensions.count) extensions", route: .space(.extensions))
            } else if store.typeState == .idle {
                EmptyPanel(icon: "chart.bar.doc.horizontal", title: "Analyse a folder", message: "Every file below the chosen root is classified by extension. ~/Library and hidden items are skipped.", actionTitle: "Analyse") {
                    Task { await store.scanTypes() }
                }
            }
        }
    }
}

struct SpaceTypeFilesScreen: View {
    let kind: String
    @ObservedObject private var store = SpaceStore.shared

    var body: some View {
        let k = SpaceKind(rawValue: kind) ?? .other
        let files = store.typeReport?.files[kind] ?? []
        let stat = store.typeReport?.stats[kind] ?? SpaceKindStat()
        ScreenScaffold(k.title, subtitle: store.typeReport.map { "In \(Format.abbreviated($0.root))" }) {
            if store.typeReport == nil {
                EmptyPanel(icon: k.icon, title: "No analysis yet", message: "Run File Types first.")
            } else {
                let exts = Dictionary(grouping: files, by: \.ext).map { ($0.key, $0.value.reduce(Int64(0)) { $0 + $1.bytes }, $0.value.count) }.sorted { $0.1 > $1.1 }
                TileGrid {
                    StatTile(label: "Total", value: Format.bytes(stat.bytes), detail: "\(Format.count(stat.count)) files", tint: k.color, icon: k.icon)
                    StatTile(label: "Listed", value: Format.count(files.count), detail: "files over 256 KB", icon: "list.bullet")
                    StatTile(label: "Average", value: Format.bytes(stat.count > 0 ? stat.bytes / Int64(stat.count) : 0), icon: "divide")
                    StatTile(label: "Largest", value: files.first.map { Format.bytes($0.bytes) } ?? "—", detail: files.first?.name, icon: "arrow.up.right.circle")
                }
                if !exts.isEmpty {
                    Card("Extensions") {
                        StackedBar(segments: exts.prefix(10).enumerated().map { i, e in
                            .init(label: e.0.isEmpty ? "(none)" : "." + e.0, value: Double(e.1), color: SpacePalette.color(i), text: "\(Format.bytes(e.1)) · \(e.2)")
                        })
                    }
                }
                SpaceFileList(files: files, title: "\(k.title) files", activityTitle: "\(k.title) files moved to Trash")
            }
        }
    }
}

struct SpaceExtensionsScreen: View {
    @ObservedObject private var store = SpaceStore.shared
    @State private var search = ""

    var body: some View {
        let all = (store.typeReport?.extensions ?? [:]).sorted { $0.value.bytes > $1.value.bytes }
        let list = search.isEmpty ? all : all.filter { $0.key.contains(search.lowercased()) }
        let top = Double(all.first?.value.bytes ?? 1)
        ScreenScaffold("Extensions", subtitle: store.typeReport.map { "In \(Format.abbreviated($0.root))" }) {
            TileGrid {
                StatTile(label: "Extensions", value: Format.count(all.count), icon: "textformat")
                StatTile(label: "Top", value: all.first.map { "." + $0.key } ?? "—", detail: all.first.map { Format.bytes($0.value.bytes) }, icon: "crown")
                StatTile(label: "Files", value: Format.count(all.reduce(0) { $0 + $1.value.count }), icon: "doc.on.doc")
            }
            SearchField(text: $search, prompt: "Filter extensions").frame(maxWidth: 260)
            Card {
                ForEach(Array(list.prefix(300).enumerated()), id: \.element.key) { i, e in
                    BarRow(label: e.key == "(none)" ? e.key : "." + e.key, value: Double(e.value.bytes), total: max(top, 1),
                           valueText: "\(Format.bytes(e.value.bytes)) · \(Format.count(e.value.count)) files",
                           tint: SpaceKind.classify(e.key).color)
                }
            }
        }
    }
}

// MARK: - Downloads

struct SpaceDownloadsScreen: View {
    @ObservedObject private var store = SpaceStore.shared
    @EnvironmentObject private var nav: Navigator

    var body: some View {
        let files = store.downloads
        let installers = files.filter(SpaceStore.isStaleInstaller)
        let total = files.reduce(Int64(0)) { $0 + $1.bytes }
        ScreenScaffold("Downloads", subtitle: "~/Downloads by type and age (date added)") {
            Button("Open Folder") { EngineActions.open(SpacePaths.url("Downloads").path) }.buttonStyle(EditorialButtonStyle(kind: .ghost))
        } content: {
            RefreshLine(state: store.downloadsState) { Task { await store.scanDownloads() } }
            if case .failed(let m) = store.downloadsState { ErrorPanel(message: m) }
            if store.downloadsState.loadedAt != nil {
                TileGrid {
                    StatTile(label: "Total", value: Format.bytes(total), detail: "\(Format.count(files.count)) items", tint: Theme.accent, icon: "arrow.down.circle")
                    StatTile(label: "Old installers", value: Format.bytes(installers.reduce(0) { $0 + $1.bytes }), detail: "\(installers.count) items > 30 days", tint: Theme.warning, icon: "shippingbox")
                    StatTile(label: "Over a year", value: Format.count(files.filter { SpaceAgeBucket.of($0.ageReference) == .older }.count), icon: "clock.arrow.circlepath")
                    StatTile(label: "Folders", value: Format.count(files.filter(\.isDirectory).count), icon: "folder")
                }
                HStack(alignment: .top, spacing: 16) {
                    Card("By type") {
                        let kinds = kindRows(files)
                        let top = Double(kinds.first?.bytes ?? 1)
                        ForEach(Array(kinds.enumerated()), id: \.element.key) { _, row in
                            BarRow(label: row.title, value: Double(row.bytes), total: max(top, 1), valueText: "\(Format.bytes(row.bytes)) · \(row.count)", tint: row.color) {
                                nav.push(.space(.downloadsBucket(row.key)))
                            }
                        }
                    }
                    Card("By age") {
                        let ages = SpaceAgeBucket.allCases.map { b -> (SpaceAgeBucket, Int64, Int) in
                            let l = files.filter { SpaceAgeBucket.of($0.ageReference) == b }
                            return (b, l.reduce(0) { $0 + $1.bytes }, l.count)
                        }.filter { $0.2 > 0 }
                        let top = Double(ages.map(\.1).max() ?? 1)
                        ForEach(ages, id: \.0) { b, bytes, count in
                            BarRow(label: b.title, value: Double(bytes), total: max(top, 1), valueText: "\(Format.bytes(bytes)) · \(count)", tint: b == .older ? Theme.danger : Theme.info) {
                                nav.push(.space(.downloadsBucket("age:" + b.rawValue)))
                            }
                        }
                    }
                }
                NavRow(icon: "shippingbox", title: "Old installers", subtitle: ".dmg .pkg .zip .xip older than 30 days", value: Format.bytes(installers.reduce(0) { $0 + $1.bytes }), tint: Theme.warning, route: .space(.downloadsBucket("installers")))
                SpaceFileList(
                    files: files,
                    title: "Everything in Downloads",
                    activityTitle: "Downloads moved to Trash",
                    preselect: SpaceStore.isStaleInstaller,
                    badge: { f in SpaceStore.isStaleInstaller(f) ? ("Old installer", Theme.warning) : nil },
                    detail: { f in "added \(Format.relative(f.ageReference)) · \(f.isDirectory ? "\(Format.count(f.files)) files" : f.kind.title)" }
                )
            } else if store.downloadsState.isLoading {
                LoadingPanel(text: "Measuring Downloads")
            }
        }
        .task { if store.downloadsState == .idle { await store.scanDownloads() } }
    }

    private struct KindRow { var key: String; var title: String; var bytes: Int64; var count: Int; var color: Color }

    private func kindRows(_ files: [SpaceFile]) -> [KindRow] {
        var rows: [KindRow] = SpaceKind.allCases.compactMap { k in
            let l = files.filter { !$0.isDirectory && $0.kind == k }
            guard !l.isEmpty else { return nil }
            return KindRow(key: "kind:" + k.rawValue, title: k.title, bytes: l.reduce(0) { $0 + $1.bytes }, count: l.count, color: k.color)
        }
        let folders = files.filter(\.isDirectory)
        if !folders.isEmpty {
            rows.append(KindRow(key: "folders", title: "Folders", bytes: folders.reduce(0) { $0 + $1.bytes }, count: folders.count, color: Theme.info))
        }
        return rows.sorted { $0.bytes > $1.bytes }
    }
}

struct SpaceDownloadsBucketScreen: View {
    let key: String
    @ObservedObject private var store = SpaceStore.shared

    var body: some View {
        let files = store.downloads.filter { SpaceDownloadsKey.matches(key, $0) }
        ScreenScaffold(SpaceDownloadsKey.title(key)) {
            TileGrid {
                StatTile(label: "Items", value: Format.count(files.count), icon: "list.bullet")
                StatTile(label: "Size", value: Format.bytes(files.reduce(0) { $0 + $1.bytes }), tint: Theme.accent, icon: "internaldrive")
                StatTile(label: "Oldest", value: Format.relative(files.compactMap(\.ageReference).min()), icon: "clock")
                StatTile(label: "Newest", value: Format.relative(files.compactMap(\.ageReference).max()), icon: "clock.badge.checkmark")
            }
            SpaceFileList(
                files: files,
                title: "Items",
                activityTitle: "\(SpaceDownloadsKey.title(key)) moved to Trash",
                preselect: key == "installers" ? { _ in true } : SpaceStore.isStaleInstaller,
                badge: { f in SpaceStore.isStaleInstaller(f) ? ("Old installer", Theme.warning) : nil },
                detail: { f in "added \(Format.relative(f.ageReference)) · modified \(Format.relative(f.modified))" }
            )
        }
    }
}
