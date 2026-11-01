import MacLeanCore
import SwiftUI

// MARK: - Disk images

struct SpaceDiskImagesScreen: View {
    @ObservedObject private var store = SpaceStore.shared

    var body: some View {
        let items = store.diskImages
        let files = items.map(SpaceFile.from)
        ScreenScaffold("Disk Images", subtitle: ".dmg .iso .sparseimage .toast in Downloads, Desktop, Documents and Movies") {
            Card {
                HStack(spacing: 18) {
                    SpaceChips(label: "Older than", options: [(0, "Any"), (30, "30 d"), (90, "90 d"), (365, "1 yr")], value: $store.diskImageAgeDays)
                    SpaceChips(label: "Min size", options: [(0, "Any"), (100, "100 MB"), (500, "500 MB"), (1000, "1 GB")], value: $store.diskImageMinMB)
                    Spacer()
                    Button("Scan") { Task { await store.scanDiskImages() } }
                        .buttonStyle(EditorialButtonStyle(kind: .primary))
                        .disabled(store.diskImagesState.isLoading)
                }
            }
            RefreshLine(state: store.diskImagesState) { Task { await store.scanDiskImages() } }
            if store.diskImagesState.isLoading { LoadingPanel(text: "Looking for disk images") }
            if store.diskImagesState.loadedAt != nil {
                let byExt = Dictionary(grouping: files, by: \.ext)
                TileGrid {
                    StatTile(label: "Images", value: Format.count(items.count), icon: "opticaldiscdrive")
                    StatTile(label: "Total size", value: Format.bytes(items.reduce(0) { $0 + $1.bytes }), tint: Theme.accent, icon: "internaldrive")
                    StatTile(label: "Oldest", value: Format.relative(items.compactMap(\.modified).min()), icon: "clock")
                    StatTile(label: "Formats", value: byExt.keys.sorted().map { "." + $0 }.joined(separator: " "), icon: "square.grid.2x2")
                }
                SpaceFileList(
                    files: files,
                    title: "Disk images",
                    activityTitle: "Disk images removed",
                    detail: { f in "\(Format.abbreviated((f.path as NSString).deletingLastPathComponent)) · \(f.note) · modified \(Format.relative(f.modified))" },
                    remove: { chosen in
                        let set = Set(chosen.map(\.path))
                        return await store.clean(store.diskImages.filter { set.contains($0.path) }, title: "Disk images moved to Trash")
                    }
                )
            }
        }
        .task { if store.diskImagesState == .idle { await store.scanDiskImages() } }
    }
}

// MARK: - Cloud

struct SpaceCloudScreen: View {
    @ObservedObject private var store = SpaceStore.shared
    @EnvironmentObject private var nav: Navigator

    var body: some View {
        ScreenScaffold("Cloud Storage", subtitle: "Local footprint of synced cloud folders") {
            RefreshLine(state: store.cloudState) { Task { await store.scanCloud() } }
            if store.cloudState.isLoading { LoadingPanel(text: "Measuring cloud folders", detail: "Only locally downloaded data counts toward disk usage") }
            if let scan = store.cloud {
                let total = scan.locations.reduce(Int64(0)) { $0 + $1.bytes }
                TileGrid {
                    StatTile(label: "Providers", value: Format.count(scan.locations.count), icon: "icloud")
                    StatTile(label: "Local size", value: Format.bytes(total), tint: Theme.accent, icon: "internaldrive")
                    StatTile(label: "Files", value: Format.count(scan.locations.reduce(0) { $0 + $1.files }), icon: "doc.on.doc")
                    StatTile(label: "Large files", value: Format.count(scan.largeFiles.count), detail: "over 50 MB", icon: "doc.badge.arrow.up")
                }
                if scan.locations.isEmpty {
                    EmptyPanel(icon: "icloud.slash", title: "No cloud folders found", message: "iCloud Drive, Dropbox, OneDrive, Google Drive and File Provider locations were checked.")
                } else {
                    Card("Usage by provider") {
                        StackedBar(segments: scan.locations.enumerated().map { i, l in
                            .init(label: l.name, value: Double(l.bytes), color: SpacePalette.color(i), text: Format.bytes(l.bytes))
                        })
                    }
                    ForEach(Array(scan.locations.enumerated()), id: \.element.path) { i, l in
                        NavRow(icon: "icloud", title: l.name, subtitle: "\(Format.count(l.files)) files · \(Format.abbreviated(l.path))", value: Format.bytes(l.bytes), tint: SpacePalette.color(i), route: .space(.cloudProvider(l.path)))
                    }
                    NavRow(icon: "doc.badge.arrow.up", title: "All large cloud files", subtitle: "Files over 50 MB across providers", value: Format.bytes(scan.largeFiles.reduce(0) { $0 + $1.bytes }), route: .space(.cloudLargeFiles))
                }
            }
        }
        .task { if store.cloudState == .idle { await store.scanCloud() } }
    }
}

struct SpaceCloudProviderScreen: View {
    let path: String
    @ObservedObject private var store = SpaceStore.shared
    @EnvironmentObject private var nav: Navigator

    var body: some View {
        let location = store.cloudLocation(path)
        let files = store.cloudFiles(under: path)
        let isICloud = path.contains("Mobile Documents") || path.hasSuffix("iCloud Drive")
        ScreenScaffold(location?.name ?? (path as NSString).lastPathComponent, subtitle: Format.abbreviated(path)) {
            Button("Reveal") { EngineActions.reveal(path) }.buttonStyle(EditorialButtonStyle(kind: .ghost))
        } content: {
            if let location {
                let disk = SystemMonitor.shared.latest.disk
                TileGrid {
                    StatTile(label: "Local size", value: Format.bytes(location.bytes), detail: disk.total > 0 ? Format.percent(Double(location.bytes) / Double(disk.total), digits: 2) + " of disk" : nil, tint: Theme.accent, icon: "internaldrive")
                    StatTile(label: "Files", value: Format.count(location.files), icon: "doc.on.doc")
                    StatTile(label: "Large files", value: Format.count(files.count), detail: Format.bytes(files.reduce(0) { $0 + $1.bytes }), icon: "doc.badge.arrow.up")
                    StatTile(label: "Average file", value: Format.bytes(location.files > 0 ? location.bytes / Int64(location.files) : 0), icon: "divide")
                }
                NavRow(icon: "circle.hexagongrid", title: "Browse in Space Lens", subtitle: "See what takes space in this provider", value: Format.bytes(location.bytes), route: .space(.lens(path)))
                SpaceFileList(
                    files: files,
                    title: "Large files",
                    activityTitle: "Cloud files moved to Trash",
                    confirmMessage: "These files live in a synced cloud folder. Moving them to the Trash also deletes them from the cloud provider on every device.",
                    secondaryTitle: isICloud ? "Remove Local Copies" : nil,
                    secondaryMessage: "Downloaded copies are removed from this Mac; the files stay in iCloud Drive and download again on demand.",
                    secondary: isICloud ? { await store.evict($0) } : nil
                )
            } else {
                EmptyPanel(icon: "icloud.slash", title: "Location not scanned", message: "Open Cloud Storage to scan providers.")
            }
        }
    }
}

struct SpaceCloudLargeFilesScreen: View {
    @ObservedObject private var store = SpaceStore.shared

    var body: some View {
        let files = store.cloudFiles(under: nil)
        ScreenScaffold("Large Cloud Files", subtitle: "Over 50 MB in synced folders") {
            TileGrid {
                StatTile(label: "Files", value: Format.count(files.count), icon: "doc.on.doc")
                StatTile(label: "Total", value: Format.bytes(files.reduce(0) { $0 + $1.bytes }), tint: Theme.accent, icon: "internaldrive")
            }
            SpaceFileList(
                files: files,
                title: "Files",
                activityTitle: "Cloud files moved to Trash",
                confirmMessage: "These files live in a synced cloud folder. Moving them to the Trash also deletes them from the cloud provider on every device.",
                secondaryTitle: "Remove Local Copies (iCloud)",
                secondaryMessage: "Downloaded copies of iCloud Drive files are removed from this Mac and stay in iCloud. Other providers report an error.",
                secondary: { await store.evict($0) }
            )
        }
        .task { if store.cloudState == .idle { await store.scanCloud() } }
    }
}

// MARK: - Mail

struct SpaceMailScreen: View {
    @ObservedObject private var store = SpaceStore.shared

    var body: some View {
        let accounts = Dictionary(grouping: store.mail, by: \.detail).map { (name: $0.key, items: $0.value) }.sorted { a, b in a.items.reduce(0) { $0 + $1.bytes } > b.items.reduce(0) { $0 + $1.bytes } }
        ScreenScaffold("Mail Attachments", subtitle: "Attachments Mail has downloaded to this Mac") {
            RefreshLine(state: store.mailState) { Task { await store.scanMail() } }
            if case .failed(let m) = store.mailState { ErrorPanel(message: m) }
            if store.mailState.isLoading { LoadingPanel(text: "Reading Mail folders") }
            if store.mailState.loadedAt != nil {
                let total = store.mail.reduce(Int64(0)) { $0 + $1.bytes }
                TileGrid {
                    StatTile(label: "Attachments", value: Format.count(store.mail.count), icon: "paperclip")
                    StatTile(label: "Total size", value: Format.bytes(total), tint: Theme.accent, icon: "internaldrive")
                    StatTile(label: "Accounts", value: Format.count(accounts.count), icon: "person.2")
                    StatTile(label: "Files inside", value: Format.count(store.mail.reduce(0) { $0 + $1.files }), icon: "doc.on.doc")
                }
                if !accounts.isEmpty {
                    Card("By account") {
                        let top = Double(accounts.first?.items.reduce(0) { $0 + $1.bytes } ?? 1)
                        ForEach(Array(accounts.enumerated()), id: \.element.name) { i, a in
                            let b = a.items.reduce(Int64(0)) { $0 + $1.bytes }
                            NavRow(icon: "envelope", title: a.name.isEmpty ? "Mail" : a.name, subtitle: "\(a.items.count) attachment folders · \(Format.percent(Double(b) / max(top, 1)))", value: Format.bytes(b), tint: SpacePalette.color(i), route: .space(.mailAccount(a.name)))
                        }
                    }
                }
                SpaceMailList(items: store.mail, title: "All attachments")
                Text("Removing attachments only deletes the downloaded copies; messages on the mail server keep their attachments and Mail re-downloads them when opened.")
                    .font(Type.text(11)).foregroundStyle(Theme.muted)
            }
        }
        .task { if store.mailState == .idle { await store.scanMail() } }
    }
}

struct SpaceMailList: View {
    let items: [Artifact]
    let title: String
    @ObservedObject private var store = SpaceStore.shared

    var body: some View {
        SpaceFileList(
            files: items.map(SpaceFile.from),
            title: title,
            activityTitle: "Mail attachments removed",
            confirmMessage: "Selected attachment folders are moved to the Trash via the engine's artifact cleaner.",
            detail: { f in "\(f.note) · \(Format.count(f.files)) files · \(Format.relative(f.modified))" },
            remove: { chosen in
                let set = Set(chosen.map(\.path))
                return await store.clean(store.mail.filter { set.contains($0.path) }, title: "Mail attachments moved to Trash")
            }
        )
    }
}

struct SpaceMailAccountScreen: View {
    let account: String
    @ObservedObject private var store = SpaceStore.shared

    var body: some View {
        let items = store.mail.filter { $0.detail == account }
        ScreenScaffold(account.isEmpty ? "Mail" : account) {
            TileGrid {
                StatTile(label: "Attachment folders", value: Format.count(items.count), icon: "paperclip")
                StatTile(label: "Size", value: Format.bytes(items.reduce(0) { $0 + $1.bytes }), tint: Theme.accent, icon: "internaldrive")
                StatTile(label: "Files", value: Format.count(items.reduce(0) { $0 + $1.files }), icon: "doc.on.doc")
                StatTile(label: "Oldest", value: Format.relative(items.compactMap(\.modified).min()), icon: "clock")
            }
            SpaceMailList(items: items, title: "Attachments")
        }
    }
}

// MARK: - Trash

struct SpaceTrashScreen: View {
    @ObservedObject private var store = SpaceStore.shared
    @State private var failures: [(path: String, reason: String)] = []
    @State private var busy = false

    var body: some View {
        let total = store.trash.reduce(Int64(0)) { $0 + $1.bytes }
        ScreenScaffold("Trash", subtitle: "~/.Trash") {
            ConfirmButton(
                title: "Empty Trash",
                message: "Permanently delete \(Format.count(store.trash.count)) items (\(Format.bytes(total))). This cannot be undone.",
                kind: .destructive,
                disabled: store.trash.isEmpty || busy
            ) {
                busy = true
                Task {
                    let s = await store.emptyTrash()
                    failures = s.failures
                    busy = false
                }
            }
        } content: {
            RefreshLine(state: store.trashState) { Task { await store.scanTrash() } }
            if case .failed(let m) = store.trashState { ErrorPanel(message: m) }
            if busy { LoadingPanel(text: "Emptying Trash") }
            FailureList(failures: failures)
            if store.trashState.loadedAt != nil {
                TileGrid {
                    StatTile(label: "Items", value: Format.count(store.trash.count), icon: "trash")
                    StatTile(label: "Size", value: Format.bytes(total), tint: Theme.accent, icon: "internaldrive")
                    StatTile(label: "Files inside", value: Format.count(store.trash.reduce(0) { $0 + $1.files }), icon: "doc.on.doc")
                    StatTile(label: "Oldest", value: Format.relative(store.trash.compactMap(\.modified).min()), icon: "clock")
                }
                if store.trash.isEmpty {
                    EmptyPanel(icon: "trash.slash", title: "Trash is empty")
                } else {
                    Card("Contents", trailing: "\(store.trash.count)") {
                        let top = Double(store.trash.first?.bytes ?? 1)
                        ForEach(store.trash.prefix(300)) { f in
                            BarRow(label: f.name, value: Double(f.bytes), total: max(top, 1),
                                   valueText: "\(Format.bytes(f.bytes))\(f.isDirectory ? " · \(Format.count(f.files)) files" : "")",
                                   tint: f.isDirectory ? Theme.info : f.kind.color) {
                                EngineActions.reveal(f.path)
                            }
                        }
                    }
                }
            }
        }
        .task { if store.trashState == .idle { await store.scanTrash() } }
    }
}

// MARK: - Volumes

struct SpaceVolumesScreen: View {
    @ObservedObject private var store = SpaceStore.shared
    @EnvironmentObject private var nav: Navigator
    @State private var message: String?

    var body: some View {
        ScreenScaffold("Volumes", subtitle: "Mounted disks") {
            RefreshLine(state: store.volumesState) { Task { await store.loadVolumes() } }
            if let message { ErrorPanel(message: message) }
            if store.volumesState.loadedAt != nil {
                let total = store.volumes.reduce(Int64(0)) { $0 + $1.total }
                let free = store.volumes.reduce(Int64(0)) { $0 + $1.available }
                TileGrid {
                    StatTile(label: "Volumes", value: Format.count(store.volumes.count), icon: "externaldrive")
                    StatTile(label: "Total capacity", value: Format.bytes(total), icon: "internaldrive")
                    StatTile(label: "Free", value: Format.bytes(free), tint: Theme.success, icon: "externaldrive.badge.checkmark")
                    StatTile(label: "Removable", value: Format.count(store.volumes.filter(\.isRemovable).count), icon: "eject")
                }
                ForEach(store.volumes) { v in
                    Card(v.name, trailing: v.format) {
                        HStack(spacing: 20) {
                            RingGauge(value: v.usedFraction, label: Format.percent(v.usedFraction), caption: "used",
                                      tint: v.usedFraction > 0.9 ? Theme.danger : Theme.accent, size: 90, lineWidth: 8)
                            VStack(alignment: .leading, spacing: 5) {
                                KeyValueRow(key: "Mount point", value: v.path, mono: true)
                                KeyValueRow(key: "Capacity", value: Format.bytes(v.total), mono: true)
                                KeyValueRow(key: "Used", value: Format.bytes(v.used), mono: true)
                                KeyValueRow(key: "Available", value: Format.bytes(v.available), mono: true)
                                KeyValueRow(key: "Type", value: [v.isRoot ? "Startup" : nil, v.isInternal ? "Internal" : "External", v.isRemovable ? "Removable" : nil].compactMap { $0 }.joined(separator: " · "))
                            }
                            Spacer()
                            VStack(spacing: 8) {
                                Button("Space Lens") { nav.push(.space(.lens(v.path))) }.buttonStyle(EditorialButtonStyle(kind: .secondary))
                                Button("Reveal") { EngineActions.reveal(v.path) }.buttonStyle(EditorialButtonStyle(kind: .ghost))
                                if v.isEjectable && !v.isRoot {
                                    ConfirmButton(title: "Eject", message: "Unmount and eject \(v.name)?", kind: .secondary) {
                                        Task { message = await store.eject(v) }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .task { await store.loadVolumes() }
    }
}
