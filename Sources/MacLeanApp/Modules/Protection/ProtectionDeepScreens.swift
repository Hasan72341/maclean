import AppKit
import MacLeanCore
import SwiftUI

// MARK: - Deep scan overview

struct ProtectionDeepScanScreen: View {
    @ObservedObject private var store = ProtectionStore.shared

    var body: some View {
        let mailBytes = store.mail?.totalBytes ?? 0
        let photoBytes = store.photos?.wastedBytes ?? 0
        let docBytes = store.documents?.selectedBytes ?? 0
        let deletedBytes = store.stores?.deletedUsers.reduce(0) { $0 + $1.bytes } ?? 0
        let cacheBytes = store.stores?.systemCaches.reduce(0) { $0 + $1.bytes } ?? 0
        let thinBytes = store.stores?.universalSavings ?? 0
        ScreenScaffold("Deep Scan", subtitle: "Protected stores other cleaners skip") {
            RefreshLine(state: store.deepState) { Task { await store.runDeepScan() } }
        } content: {
            TileGrid {
                StatTile(label: "Reclaimable", value: Format.bytes(ProtectionDeepTotals.reclaimable(store)), tint: Theme.accent, icon: "scope")
                StatTile(label: "Mail Trash", value: Format.bytes(mailBytes), detail: "\(store.mail?.mailboxes.count ?? 0) mailboxes", icon: "envelope")
                StatTile(label: "Photos duplicates", value: Format.bytes(photoBytes), detail: "\(store.photos?.exactGroups.count ?? 0) groups", icon: "photo.on.rectangle")
                StatTile(label: "Document versions", value: Format.bytes(docBytes), detail: "\(store.documents?.files.count ?? 0) documents", icon: "doc.on.doc")
                StatTile(label: "System stores", value: Format.bytes(deletedBytes + cacheBytes), detail: store.stores?.isRoot == true ? "running as root" : "admin needed", icon: "lock.shield")
                StatTile(label: "Universal savings", value: Format.bytes(thinBytes), detail: "\(store.stores?.universalBinaries.count ?? 0) binaries", icon: "cpu")
                StatTile(label: "Scan time", value: store.deepDuration.map { Format.duration($0) } ?? "—", icon: "timer")
            }
            Toggle("Include visually similar photos (slower)", isOn: $store.photosSimilar).font(Type.text(12))
            if store.deepState.isLoading {
                LoadingPanel(text: "Deep scan in progress…", detail: "Hashing Photos originals, reading Mail mailboxes, document revisions and app binaries.")
            } else if store.deepState == .idle && store.mail == nil {
                EmptyPanel(icon: "scope", title: "Run a deep scan", message: "Measures Mail Trash, Photos duplicates, document versions, deleted-user installers, system caches and universal binaries.",
                           actionTitle: "Start Deep Scan") { Task { await store.runDeepScan() } }
            }
            if store.mail != nil || store.stores != nil {
                Card("Composition") {
                    StackedBar(segments: [
                        .init(label: "Mail", value: Double(mailBytes), color: Theme.info, text: Format.bytes(mailBytes)),
                        .init(label: "Photos", value: Double(photoBytes), color: Theme.accent, text: Format.bytes(photoBytes)),
                        .init(label: "Versions", value: Double(docBytes), color: Theme.warning, text: Format.bytes(docBytes)),
                        .init(label: "Deleted users", value: Double(deletedBytes), color: Theme.danger, text: Format.bytes(deletedBytes)),
                        .init(label: "System caches", value: Double(cacheBytes), color: Theme.muted, text: Format.bytes(cacheBytes)),
                        .init(label: "Universal", value: Double(thinBytes), color: Theme.success, text: Format.bytes(thinBytes)),
                    ])
                }
            }
            VStack(spacing: 8) {
                NavRow(icon: "envelope", title: "Mail Trash", subtitle: "Deleted messages still on disk", value: Format.bytes(mailBytes), route: .protection(.mailTrash))
                NavRow(icon: "photo.on.rectangle", title: "Photos duplicates", subtitle: "Identical originals inside Photos libraries", value: Format.bytes(photoBytes), route: .protection(.photosDuplicates))
                NavRow(icon: "doc.on.doc", title: "Document versions", subtitle: "Redundant autosave revisions", value: Format.bytes(docBytes), route: .protection(.documentVersions))
                NavRow(icon: "person.crop.circle.badge.xmark", title: "Deleted users", subtitle: "/Users/DeletedUsers disk images", value: Format.bytes(deletedBytes), route: .protection(.deletedUsers))
                NavRow(icon: "internaldrive", title: "System caches & logs", subtitle: "/Library/Caches, /var/log, diagnostics", value: Format.bytes(cacheBytes), route: .protection(.systemCaches))
                NavRow(icon: "cpu", title: "Universal binaries", subtitle: "Unused architecture slices in apps", value: Format.bytes(thinBytes), route: .protection(.universalBinaries))
            }
            if let errors = store.stores?.errors, !errors.isEmpty {
                Card("Scanner notes", trailing: "\(errors.count)") {
                    ForEach(errors.prefix(12), id: \.self) { Text($0).font(Type.text(11)).foregroundStyle(Theme.muted) }
                }
            }
        }
        .task { if store.deepState == .idle && store.mail == nil { await store.runDeepScan() } }
    }
}

// MARK: - Mail Trash

struct ProtectionMailTrashScreen: View {
    @ObservedObject private var store = ProtectionStore.shared
    @EnvironmentObject private var nav: Navigator
    @State private var selected: Set<String> = []
    @State private var failures: [(path: String, reason: String)] = []
    @State private var query = ""

    var body: some View {
        let all = (store.mail?.mailboxes ?? []).sorted { $0.bytes > $1.bytes }
        let list = query.isEmpty ? all : all.filter { $0.account.localizedCaseInsensitiveContains(query) || $0.mailbox.localizedCaseInsensitiveContains(query) }
        let accounts = Dictionary(grouping: all, by: \.account).map { ($0.key, $0.value.reduce(Int64(0)) { $0 + $1.bytes }) }.sorted { $0.1 > $1.1 }
        let mailOpen = ProtectionUI.isRunning("com.apple.mail")
        ScreenScaffold("Mail Trash", subtitle: "Messages in Trash mailboxes that still occupy disk space") {
            RefreshLine(state: store.mailState) { Task { await store.scanMail() } }
        } content: {
            TileGrid {
                StatTile(label: "Size", value: Format.bytes(store.mail?.totalBytes ?? 0), tint: Theme.accent, icon: "envelope")
                StatTile(label: "Mailboxes", value: Format.count(all.count), icon: "tray.full")
                StatTile(label: "Messages", value: Format.count(all.reduce(0) { $0 + $1.messageCount }), icon: "envelope.open")
                StatTile(label: "Accounts", value: Format.count(accounts.count), icon: "person.2")
                StatTile(label: "Mail app", value: mailOpen ? "Running" : "Closed", detail: mailOpen ? "quit before cleaning" : "ready",
                         tint: mailOpen ? Theme.warning : Theme.success, icon: "app")
            }
            if let error = store.mail?.error { ErrorPanel(message: error) }
            if store.mailState.isLoading && store.mail == nil {
                LoadingPanel(text: "Scanning Mail…")
            } else if all.isEmpty {
                EmptyPanel(icon: "envelope", title: store.mail == nil ? "Not scanned" : "Mail Trash is empty",
                           actionTitle: store.mail == nil ? "Scan" : nil) { Task { await store.scanMail() } }
            } else {
                Card("By account") {
                    ForEach(accounts, id: \.0) { account, bytes in
                        BarRow(label: account, value: Double(bytes), total: Double(accounts.first?.1 ?? 1), valueText: Format.bytes(bytes))
                    }
                }
                SearchField(text: $query, prompt: "Filter mailboxes")
                Card("Mailboxes", trailing: "\(list.count)") {
                    ForEach(list) { box in
                        CheckRow(
                            isOn: Binding(get: { selected.contains(box.path) }, set: { on in if on { selected.insert(box.path) } else { selected.remove(box.path) } }),
                            title: "\(box.account) · \(box.mailbox)",
                            subtitle: "\(Format.count(box.messageCount)) messages · \(Format.abbreviated(box.path))",
                            value: Format.bytes(box.bytes),
                            onOpen: { nav.push(.protection(.mailbox(box.path))) },
                            onReveal: { EngineActions.reveal(box.path) }
                        )
                    }
                }
                FailureList(failures: failures)
                SelectionBar(
                    selectedCount: selected.count, totalCount: all.count,
                    selectedBytes: all.filter { selected.contains($0.path) }.reduce(0) { $0 + $1.bytes },
                    actionTitle: "Move Messages to Trash",
                    confirmMessage: "Message files in the selected Trash mailboxes move to the Finder Trash. Mail may rebuild its index on next launch.",
                    busy: store.busy,
                    onSelectAll: { selected = Set(all.map(\.path)) },
                    onSelectNone: { selected = [] }
                ) {
                    let chosen = all.filter { selected.contains($0.path) }
                    Task {
                        failures = await store.cleanMail(chosen).failures
                        selected = []
                    }
                }
            }
        }
        .task { if store.mail == nil && !store.mailState.isLoading { await store.scanMail() } }
    }
}

struct ProtectionMailboxScreen: View {
    let path: String
    @ObservedObject private var store = ProtectionStore.shared
    @State private var failures: [(path: String, reason: String)] = []

    var body: some View {
        if let box = store.mail?.mailboxes.first(where: { $0.path == path }) {
            ScreenScaffold(box.mailbox, subtitle: box.account) {
                Button("Reveal") { EngineActions.reveal(box.path) }.buttonStyle(EditorialButtonStyle(kind: .secondary))
            } content: {
                TileGrid {
                    StatTile(label: "Size", value: Format.bytes(box.bytes), icon: "externaldrive")
                    StatTile(label: "Messages", value: Format.count(box.messageCount), icon: "envelope")
                    StatTile(label: "Avg message", value: box.messageCount > 0 ? Format.bytes(box.bytes / Int64(box.messageCount)) : "—", icon: "divide")
                    StatTile(label: "Share of trash", value: Format.percent(Double(box.bytes) / Double(max(1, store.mail?.totalBytes ?? 1))), icon: "chart.pie")
                }
                Card("Mailbox") {
                    KeyValueRow(key: "Account", value: box.account)
                    KeyValueRow(key: "Mailbox", value: box.mailbox)
                    KeyValueRow(key: "Path", value: box.path, mono: true)
                }
                FailureList(failures: failures)
                ConfirmButton(title: "Move \(Format.count(box.messageCount)) Messages to Trash",
                              message: "Move this mailbox's message files (\(Format.bytes(box.bytes))) to the Finder Trash? Quit Mail first.",
                              kind: .destructive, disabled: store.busy) {
                    Task { failures = await store.cleanMail([box]).failures }
                }
            }
        } else {
            ScreenScaffold("Mailbox") { EmptyPanel(icon: "envelope", title: "Mailbox is empty or gone") }
        }
    }
}

// MARK: - Photos

struct ProtectionPhotosScreen: View {
    @ObservedObject private var store = ProtectionStore.shared
    @EnvironmentObject private var nav: Navigator
    @State private var selected: Set<String> = []
    @State private var failures: [(path: String, reason: String)] = []

    var body: some View {
        let report = store.photos
        let groups = (report?.exactGroups ?? []).sorted { $0.size * Int64($0.paths.count - 1) > $1.size * Int64($1.paths.count - 1) }
        let photosOpen = ProtectionUI.isRunning("com.apple.Photos")
        ScreenScaffold("Photos Duplicates", subtitle: "Byte-identical originals inside your Photos libraries") {
            RefreshLine(state: store.photosState) { Task { await store.scanPhotos() } }
        } content: {
            TileGrid {
                StatTile(label: "Reclaimable", value: Format.bytes(report?.wastedBytes ?? 0), tint: Theme.accent, icon: "photo.on.rectangle")
                StatTile(label: "Exact groups", value: Format.count(groups.count), icon: "square.on.square")
                StatTile(label: "Duplicate files", value: Format.count(groups.reduce(0) { $0 + $1.paths.count - 1 }), icon: "doc.on.doc")
                StatTile(label: "Libraries", value: Format.count(report?.libraries.count ?? 0),
                         detail: "\(Format.count(report?.libraries.reduce(0) { $0 + $1.originalFiles } ?? 0)) originals", icon: "photo.stack")
                StatTile(label: "Similar groups", value: Format.count(report?.similarGroups.count ?? 0), detail: Format.bytes(report?.similarBytes ?? 0), icon: "eye")
                StatTile(label: "Photos app", value: photosOpen ? "Running" : "Closed", tint: photosOpen ? Theme.warning : Theme.success, icon: "app")
            }
            Toggle("Also find visually similar photos (report only)", isOn: $store.photosSimilar).font(Type.text(12))
            Card("Before removing") {
                Text("Removing originals outside Photos leaves database entries pointing at missing files. Keep a backup; Photos may need a library repair (hold Option + Command while opening Photos). The first file of each group, sorted by path, is kept.")
                    .font(Type.text(12)).foregroundStyle(Theme.warning).fixedSize(horizontal: false, vertical: true)
            }
            if let error = report?.error { ErrorPanel(message: error) }
            NavRow(icon: "photo.stack", title: "Libraries", value: Format.count(report?.libraries.count ?? 0), route: .protection(.photoLibraries))
            if store.photosState.isLoading && report == nil {
                LoadingPanel(text: "Hashing Photos originals…")
            } else if groups.isEmpty {
                EmptyPanel(icon: "checkmark.circle", title: report == nil ? "Not scanned" : "No exact duplicates")
            } else {
                Card("Duplicate groups", trailing: "\(groups.count)") {
                    ForEach(groups, id: \.hash) { group in
                        CheckRow(
                            isOn: Binding(get: { selected.contains(group.hash) }, set: { on in if on { selected.insert(group.hash) } else { selected.remove(group.hash) } }),
                            title: URL(fileURLWithPath: group.paths.sorted().first ?? "").lastPathComponent,
                            subtitle: "\(group.paths.count) copies · \(Format.bytes(group.size)) each",
                            value: Format.bytes(group.size * Int64(group.paths.count - 1)),
                            onOpen: { nav.push(.protection(.photoGroup(group.hash))) },
                            onReveal: { EngineActions.reveal(group.paths.sorted().first ?? "") }
                        )
                    }
                }
                FailureList(failures: failures)
                SelectionBar(
                    selectedCount: selected.count, totalCount: groups.count,
                    selectedBytes: groups.filter { selected.contains($0.hash) }.reduce(0) { $0 + $1.size * Int64($1.paths.count - 1) },
                    actionTitle: "Move Duplicates to Trash",
                    confirmMessage: "Extra copies in the selected groups move to the Finder Trash. Quit Photos first and keep a backup of the library.",
                    busy: store.busy,
                    onSelectAll: { selected = Set(groups.map(\.hash)) },
                    onSelectNone: { selected = [] }
                ) {
                    let chosen = groups.filter { selected.contains($0.hash) }
                    Task {
                        failures = await store.cleanPhotos(chosen).failures
                        selected = []
                    }
                }
            }
            if let similar = report?.similarGroups, !similar.isEmpty {
                Card("Similar photos (review in Photos)", trailing: "\(similar.count)") {
                    ForEach(Array(similar.prefix(40).enumerated()), id: \.offset) { _, group in
                        HStack {
                            Text("\(group.paths.count) photos · \(URL(fileURLWithPath: group.paths.first ?? "").lastPathComponent)").font(Type.text(12))
                            Spacer()
                            Text(Format.bytes(group.bytes)).font(Type.mono(11))
                            Button("Reveal") { EngineActions.reveal(group.paths.first ?? "") }.buttonStyle(EditorialButtonStyle(kind: .inline))
                        }
                    }
                }
            }
        }
        .task { if report == nil && !store.photosState.isLoading { await store.scanPhotos() } }
    }
}

struct ProtectionPhotoGroupScreen: View {
    let hash: String
    @ObservedObject private var store = ProtectionStore.shared
    @State private var failures: [(path: String, reason: String)] = []

    var body: some View {
        if let group = store.photos?.exactGroups.first(where: { $0.hash == hash }) {
            let ordered = group.paths.sorted()
            ScreenScaffold("Duplicate Group", subtitle: "\(ordered.count) identical files") {
                Button("Open First") { EngineActions.open(ordered.first ?? "") }.buttonStyle(EditorialButtonStyle(kind: .secondary))
            } content: {
                TileGrid {
                    StatTile(label: "Copies", value: "\(ordered.count)", icon: "square.on.square")
                    StatTile(label: "File size", value: Format.bytes(group.size), icon: "doc")
                    StatTile(label: "Reclaimable", value: Format.bytes(group.size * Int64(ordered.count - 1)), tint: Theme.accent, icon: "arrow.down.circle")
                }
                Card("Files") {
                    ForEach(Array(ordered.enumerated()), id: \.offset) { index, path in
                        HStack {
                            RiskBadge(text: index == 0 ? "KEEP" : "REMOVE", tint: index == 0 ? Theme.success : Theme.danger)
                            Text(Format.abbreviated(path)).font(Type.mono(11)).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button("Reveal") { EngineActions.reveal(path) }.buttonStyle(EditorialButtonStyle(kind: .inline))
                        }
                    }
                    KeyValueRow(key: "SHA hash", value: group.hash, mono: true)
                }
                FailureList(failures: failures)
                ConfirmButton(title: "Move \(ordered.count - 1) Copies to Trash", message: "Keep the first file and move the other copies to the Finder Trash? Quit Photos first.",
                              kind: .destructive, disabled: store.busy) {
                    Task { failures = await store.cleanPhotos([group]).failures }
                }
            }
        } else {
            ScreenScaffold("Duplicate Group") { EmptyPanel(icon: "checkmark.circle", title: "Group resolved") }
        }
    }
}

struct ProtectionPhotoLibrariesScreen: View {
    @ObservedObject private var store = ProtectionStore.shared

    var body: some View {
        let libraries = store.photos?.libraries ?? []
        let total = libraries.reduce(Int64(0)) { $0 + $1.bytes }
        ScreenScaffold("Photos Libraries") {
            TileGrid {
                StatTile(label: "Libraries", value: Format.count(libraries.count), icon: "photo.stack")
                StatTile(label: "Originals", value: Format.count(libraries.reduce(0) { $0 + $1.originalFiles }), icon: "photo")
                StatTile(label: "Size", value: Format.bytes(total), icon: "externaldrive")
            }
            if libraries.isEmpty {
                EmptyPanel(icon: "photo.stack", title: "No libraries found", message: "Grant Full Disk Access if your library lives in ~/Pictures.")
            } else {
                Card("Libraries") {
                    ForEach(libraries) { library in
                        BarRow(label: URL(fileURLWithPath: library.path).lastPathComponent, value: Double(library.bytes), total: Double(max(total, 1)),
                               valueText: "\(Format.count(library.originalFiles)) originals · \(Format.bytes(library.bytes))") {
                            EngineActions.reveal(library.path)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Document versions

struct ProtectionDocumentsScreen: View {
    @ObservedObject private var store = ProtectionStore.shared
    @EnvironmentObject private var nav: Navigator
    @State private var selected: Set<String> = []
    @State private var failures: [(path: String, reason: String)] = []
    @State private var query = ""

    private func redundant(_ file: DocumentVersionFile) -> Int64 {
        file.versions.filter(\.selected).reduce(0) { $0 + $1.bytes }
    }

    var body: some View {
        let report = store.documents
        let all = (report?.files ?? []).sorted { redundant($0) > redundant($1) }
        let list = query.isEmpty ? all : all.filter { $0.path.localizedCaseInsensitiveContains(query) }
        let cleanable = all.filter { redundant($0) > 0 }
        let apps = Dictionary(grouping: all, by: \.app).map { ($0.key, $0.value.reduce(Int64(0)) { $0 + $1.bytes }) }.sorted { $0.1 > $1.1 }
        let systemRevisions = store.stores?.documentVersions ?? []
        ScreenScaffold("Document Versions", subtitle: "Autosave revisions kept by macOS for your documents") {
            RefreshLine(state: store.documentsState) { Task { await store.scanDocuments() } }
        } content: {
            TileGrid {
                StatTile(label: "Redundant", value: Format.bytes(report?.selectedBytes ?? 0), detail: "safe to remove", tint: Theme.accent, icon: "doc.on.doc")
                StatTile(label: "All versions", value: Format.bytes(report?.totalBytes ?? 0), icon: "externaldrive")
                StatTile(label: "Documents", value: Format.count(all.count), icon: "doc")
                StatTile(label: "Versions", value: Format.count(all.reduce(0) { $0 + $1.versions.count }), icon: "clock.arrow.circlepath")
                StatTile(label: "Cleanable docs", value: Format.count(cleanable.count), icon: "checkmark.circle")
            }
            Text("Versions saved within 4 hours of a neighbouring version are marked redundant; the oldest and newest are always kept. Removal is permanent.")
                .font(Type.text(11)).foregroundStyle(Theme.muted)
            if let error = report?.error { ErrorPanel(message: error) }
            if store.documentsState.isLoading && report == nil {
                LoadingPanel(text: "Reading document versions…")
            } else if all.isEmpty {
                EmptyPanel(icon: "doc", title: report == nil ? "Not scanned" : "No document versions found")
            } else {
                Card("By app") {
                    ForEach(apps, id: \.0) { app, bytes in
                        BarRow(label: app, value: Double(bytes), total: Double(apps.first?.1 ?? 1), valueText: Format.bytes(bytes))
                    }
                }
                SearchField(text: $query, prompt: "Filter documents")
                Card("Documents", trailing: "\(list.count)") {
                    ForEach(list) { file in
                        let extra = file.versions.filter(\.selected)
                        CheckRow(
                            isOn: Binding(get: { selected.contains(file.path) },
                                          set: { on in guard !extra.isEmpty else { return }; if on { selected.insert(file.path) } else { selected.remove(file.path) } }),
                            title: URL(fileURLWithPath: file.path).lastPathComponent,
                            subtitle: "\(file.app) · \(file.versions.count) versions · \(extra.count) redundant",
                            value: Format.bytes(redundant(file)),
                            badge: extra.isEmpty ? "KEEP ALL" : nil,
                            badgeTint: Theme.muted,
                            onOpen: { nav.push(.protection(.documentVersionFile(file.path))) },
                            onReveal: { EngineActions.reveal(file.path) }
                        )
                    }
                }
                FailureList(failures: failures)
                SelectionBar(
                    selectedCount: selected.count, totalCount: cleanable.count,
                    selectedBytes: all.filter { selected.contains($0.path) }.reduce(0) { $0 + redundant($1) },
                    actionTitle: "Remove Redundant Versions",
                    confirmMessage: "Redundant versions are removed permanently through NSFileVersion. Current documents are not touched.",
                    busy: store.busy,
                    onSelectAll: { selected = Set(cleanable.map(\.path)) },
                    onSelectNone: { selected = [] }
                ) {
                    let chosen = all.filter { selected.contains($0.path) }
                    Task {
                        failures = await store.cleanDocuments(chosen).failures
                        selected = []
                    }
                }
            }
            if !systemRevisions.isEmpty {
                Card("System revision store (/.DocumentRevisions-V100)", trailing: Format.bytes(systemRevisions.reduce(0) { $0 + $1.bytes })) {
                    Text("Managed by macOS; listed for size only.").font(Type.text(11)).foregroundStyle(Theme.muted)
                    ForEach(systemRevisions.prefix(20)) { item in
                        NavRow(icon: "lock.doc", title: item.name, subtitle: item.detail, value: Format.bytes(item.bytes), route: .protection(.storeItem(item.path)))
                    }
                }
            }
        }
        .task { if report == nil && !store.documentsState.isLoading { await store.scanDocuments() } }
    }
}

struct ProtectionDocumentFileScreen: View {
    let path: String
    @ObservedObject private var store = ProtectionStore.shared
    @State private var failures: [(path: String, reason: String)] = []

    var body: some View {
        if let file = store.documents?.files.first(where: { $0.path == path }) {
            let versions = file.versions.sorted { $0.modified > $1.modified }
            let extra = versions.filter(\.selected)
            ScreenScaffold(URL(fileURLWithPath: file.path).lastPathComponent, subtitle: file.app) {
                HStack(spacing: 8) {
                    Button("Open") { EngineActions.open(file.path) }.buttonStyle(EditorialButtonStyle(kind: .secondary))
                    Button("Reveal") { EngineActions.reveal(file.path) }.buttonStyle(EditorialButtonStyle(kind: .ghost))
                }
            } content: {
                TileGrid {
                    StatTile(label: "Versions", value: Format.count(versions.count), icon: "clock.arrow.circlepath")
                    StatTile(label: "Redundant", value: Format.count(extra.count), detail: Format.bytes(extra.reduce(0) { $0 + $1.bytes }), tint: Theme.accent, icon: "doc.on.doc")
                    StatTile(label: "All versions", value: Format.bytes(file.bytes), icon: "externaldrive")
                    StatTile(label: "Span", value: versions.count > 1 ? Format.duration(versions[0].modified.timeIntervalSince(versions[versions.count - 1].modified)) : "—", icon: "calendar")
                }
                Card("Versions") {
                    ForEach(versions) { version in
                        HStack {
                            RiskBadge(text: version.selected ? "REDUNDANT" : "KEEP", tint: version.selected ? Theme.warning : Theme.success)
                            Text(Format.date(version.modified)).font(Type.text(12))
                            Spacer()
                            Text(Format.bytes(version.bytes)).font(Type.mono(11)).monospacedDigit()
                        }
                    }
                }
                FailureList(failures: failures)
                ConfirmButton(title: "Remove \(extra.count) Redundant Versions", message: "Permanently remove \(extra.count) redundant versions of this document?",
                              kind: .destructive, disabled: extra.isEmpty || store.busy) {
                    Task { failures = await store.cleanDocuments([file]).failures }
                }
            }
        } else {
            ScreenScaffold("Document") { EmptyPanel(icon: "doc", title: "Document no longer has versions") }
        }
    }
}

// MARK: - Protected stores (root)

struct ProtectionStoreListScreen: View {
    let kind: String
    @ObservedObject private var store = ProtectionStore.shared
    @EnvironmentObject private var nav: Navigator
    @State private var failures: [(path: String, reason: String)] = []
    @State private var output: ProtectionAdminResult?

    private var isDeletedUsers: Bool { kind == "deleted-user" }

    var body: some View {
        let items = ((isDeletedUsers ? store.stores?.deletedUsers : store.stores?.systemCaches) ?? []).sorted { $0.bytes > $1.bytes }
        let total = items.reduce(Int64(0)) { $0 + $1.bytes }
        let command = "sudo " + store.adminCommand(kind: kind).replacingOccurrences(of: " --json", with: "")
        let roots = Dictionary(grouping: items, by: \.detail).map { ($0.key, $0.value.reduce(Int64(0)) { $0 + $1.bytes }) }.sorted { $0.1 > $1.1 }
        ScreenScaffold(isDeletedUsers ? "Deleted Users" : "System Caches & Logs",
                       subtitle: isDeletedUsers ? "Disk images left in /Users/DeletedUsers" : "System-wide caches, logs and diagnostics") {
            RefreshLine(state: store.storesState) { Task { await store.scanStores() } }
        } content: {
            TileGrid {
                StatTile(label: "Size", value: Format.bytes(total), tint: Theme.accent, icon: isDeletedUsers ? "person.crop.circle.badge.xmark" : "internaldrive")
                StatTile(label: "Items", value: Format.count(items.count), icon: "doc.on.doc")
                StatTile(label: "Largest", value: Format.bytes(items.first?.bytes ?? 0), detail: items.first?.name, icon: "arrow.up.circle")
                StatTile(label: "Access", value: store.stores?.isRoot == true ? "Root" : "Admin needed", tint: Theme.warning, icon: "lock")
            }
            if store.storesState.isLoading && store.stores == nil {
                LoadingPanel(text: "Measuring protected stores…")
            } else if items.isEmpty {
                EmptyPanel(icon: "checkmark.circle", title: store.stores == nil ? "Not scanned" : "Nothing found",
                           message: isDeletedUsers ? "No deleted-user archives exist." : "System caches may be unreadable without Full Disk Access.")
            } else {
                if !isDeletedUsers && roots.count > 1 {
                    Card("By location") {
                        ForEach(roots, id: \.0) { root, bytes in
                            BarRow(label: root, value: Double(bytes), total: Double(roots.first?.1 ?? 1), valueText: Format.bytes(bytes))
                        }
                    }
                }
                Card("Items", trailing: "\(items.count)") {
                    ForEach(items.prefix(300)) { item in
                        NavRow(icon: isDeletedUsers ? "externaldrive.badge.person.crop" : "folder", title: item.name,
                               subtitle: Format.abbreviated(item.path), value: Format.bytes(item.bytes), route: .protection(.storeItem(item.path)))
                    }
                }
                Card("Clean with administrator rights") {
                    Text("These locations are owned by the system. MacLean runs its engine as root through the macOS password prompt; items are deleted permanently after path and file-identity checks.")
                        .font(Type.text(12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Text(command).font(Type.mono(11)).textSelection(.enabled).lineLimit(2)
                        Spacer()
                        Button("Copy") { ProtectionUI.copy(command) }
                    }
                    HStack(spacing: 10) {
                        ConfirmButton(title: "Delete \(Format.count(items.count)) Items as Admin",
                                      message: "Permanently delete \(Format.bytes(total)) in \(isDeletedUsers ? "/Users/DeletedUsers" : "system caches and logs")? macOS will ask for your administrator password.",
                                      kind: .destructive, disabled: store.busy || CLI.locate() == nil) {
                            Task {
                                let result = await store.cleanProtectedStore(kind: kind, items: items)
                                failures = result.0.failures
                                output = result.1
                            }
                        }
                        if store.busy { ProgressView().controlSize(.small) }
                        if CLI.locate() == nil {
                            Text("maclean CLI not found; use the command above.").font(Type.text(11)).foregroundStyle(Theme.warning)
                        }
                    }
                }
            }
            FailureList(failures: failures)
            if let output {
                Card("Command output", trailing: "exit \(output.status)") {
                    Text((output.stdout + output.stderr).trimmingCharacters(in: .whitespacesAndNewlines).prefix(6000))
                        .font(Type.mono(10)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .task { if store.stores == nil && !store.storesState.isLoading { await store.scanStores() } }
    }
}

struct ProtectionStoreItemScreen: View {
    let path: String
    @ObservedObject private var store = ProtectionStore.shared

    var body: some View {
        let all = (store.stores?.deletedUsers ?? []) + (store.stores?.systemCaches ?? []) + (store.stores?.documentVersions ?? [])
        if let item = all.first(where: { $0.path == path }) {
            ScreenScaffold(item.name, subtitle: item.kind) {
                Button("Reveal") { EngineActions.reveal(item.path) }.buttonStyle(EditorialButtonStyle(kind: .secondary))
            } content: {
                TileGrid {
                    StatTile(label: "Size", value: Format.bytes(item.bytes), icon: "externaldrive")
                    StatTile(label: "Kind", value: item.kind, icon: "tag")
                    StatTile(label: "Root required", value: item.requiresRoot ? "Yes" : "No", tint: item.requiresRoot ? Theme.warning : Theme.success, icon: "lock")
                }
                Card("Item") {
                    KeyValueRow(key: "Name", value: item.name)
                    KeyValueRow(key: "Path", value: item.path, mono: true)
                    KeyValueRow(key: "Detail", value: item.detail)
                    KeyValueRow(key: "Device", value: item.device.map { String($0) } ?? "—", mono: true)
                    KeyValueRow(key: "Inode", value: item.inode.map { String($0) } ?? "—", mono: true)
                }
                Text("Cleanup runs per store from the Deleted Users and System Caches screens, where the engine re-checks each item's device and inode before deleting.")
                    .font(Type.text(11)).foregroundStyle(Theme.muted)
            }
        } else {
            ScreenScaffold("Item") { EmptyPanel(icon: "checkmark.circle", title: "Item no longer present") }
        }
    }
}

// MARK: - Universal binaries

enum ProtectionUniversalSort: String, CaseIterable, Hashable {
    case savings = "Savings"
    case size = "Size"
    case name = "Name"
}

struct ProtectionUniversalScreen: View {
    @ObservedObject private var store = ProtectionStore.shared
    @EnvironmentObject private var nav: Navigator
    @State private var sort: ProtectionUniversalSort = .savings
    @State private var query = ""
    @State private var selected: Set<String> = []
    @State private var failures: [(path: String, reason: String)] = []

    var body: some View {
        let arch = ProtectionUI.nativeArch
        let all = store.stores?.universalBinaries ?? []
        let thinnable = all.filter { $0.archs.count > 1 && $0.archs.contains(arch) }
        var list = query.isEmpty ? all : all.filter { $0.name.localizedCaseInsensitiveContains(query) || $0.path.localizedCaseInsensitiveContains(query) }
        switch sort {
        case .savings: list.sort { $0.estimatedSavings > $1.estimatedSavings }
        case .size: list.sort { $0.bytes > $1.bytes }
        case .name: list.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        let peak = Double(all.map(\.estimatedSavings).max() ?? 1)
        return ScreenScaffold("Universal Binaries", subtitle: "Apps that ship code for architectures this Mac never runs") {
            RefreshLine(state: store.storesState) { Task { await store.scanStores() } }
        } content: {
            TileGrid {
                StatTile(label: "Binaries", value: Format.count(all.count), icon: "cpu")
                StatTile(label: "Total size", value: Format.bytes(store.stores?.universalBytes ?? 0), icon: "externaldrive")
                StatTile(label: "Est. savings", value: Format.bytes(store.stores?.universalSavings ?? 0), tint: Theme.accent, icon: "arrow.down.circle")
                StatTile(label: "This Mac", value: arch, icon: "desktopcomputer")
                StatTile(label: "Thinnable", value: Format.count(thinnable.count), detail: "contain \(arch)", icon: "scissors")
            }
            Card("Read before thinning") {
                Text("Thinning removes other architecture slices with lipo and ad-hoc re-signs the app. This breaks the developer signature: auto-updaters, notarization checks, iCloud, keychain access and App Store updates can stop working, and the app cannot run under Rosetta or on another Mac. Originals are backed up to ~/Library/Application Support/MacLean/UniversalBackups.")
                    .font(Type.text(12)).foregroundStyle(Theme.danger).fixedSize(horizontal: false, vertical: true)
            }
            if store.storesState.isLoading && store.stores == nil {
                LoadingPanel(text: "Inspecting app binaries…")
            } else if all.isEmpty {
                EmptyPanel(icon: "cpu", title: store.stores == nil ? "Not scanned" : "No universal binaries found")
            } else {
                HStack {
                    SearchField(text: $query, prompt: "Filter apps")
                    Picker("", selection: $sort) {
                        ForEach(ProtectionUniversalSort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).frame(width: 240)
                }
                Card("Top savings") {
                    ForEach(all.sorted { $0.estimatedSavings > $1.estimatedSavings }.prefix(6)) { item in
                        BarRow(label: item.name, value: Double(item.estimatedSavings), total: max(peak, 1), valueText: Format.bytes(item.estimatedSavings)) {
                            nav.push(.protection(.universalBinaryDetail(item.path)))
                        }
                    }
                }
                Card("Binaries", trailing: "\(list.count)") {
                    ForEach(list) { item in
                        let canThin = item.archs.count > 1 && item.archs.contains(arch)
                        CheckRow(
                            isOn: Binding(get: { selected.contains(item.path) },
                                          set: { on in guard canThin else { return }; if on { selected.insert(item.path) } else { selected.remove(item.path) } }),
                            title: item.name,
                            subtitle: "\(item.archs.joined(separator: " · ")) · \(Format.bytes(item.bytes))",
                            value: Format.bytes(item.estimatedSavings),
                            badge: canThin ? nil : "NO \(arch.uppercased())",
                            onOpen: { nav.push(.protection(.universalBinaryDetail(item.path))) },
                            onReveal: { EngineActions.reveal(item.path) }
                        )
                    }
                }
                FailureList(failures: failures)
                SelectionBar(
                    selectedCount: selected.count, totalCount: thinnable.count,
                    selectedBytes: all.filter { selected.contains($0.path) }.reduce(0) { $0 + $1.estimatedSavings },
                    actionTitle: "Thin to \(arch)",
                    confirmMessage: "This rewrites app binaries and replaces their code signatures with an ad-hoc signature. Signed updates and some app features may break. Backups are kept.",
                    busy: store.busy,
                    onSelectAll: { selected = Set(thinnable.map(\.path)) },
                    onSelectNone: { selected = [] }
                ) {
                    let chosen = all.filter { selected.contains($0.path) }
                    Task {
                        failures = await store.thin(chosen).0.failures
                        selected = []
                    }
                }
            }
        }
        .task { if store.stores == nil && !store.storesState.isLoading { await store.scanStores() } }
    }
}

struct ProtectionUniversalDetailScreen: View {
    let path: String
    @ObservedObject private var store = ProtectionStore.shared
    @State private var failures: [(path: String, reason: String)] = []
    @State private var result: UniversalThinResult?

    var body: some View {
        let arch = ProtectionUI.nativeArch
        if let item = store.stores?.universalBinaries.first(where: { $0.path == path }) {
            let appPath = item.path.range(of: "/Contents/").map { String(item.path[..<$0.lowerBound]) }
            let canThin = item.archs.count > 1 && item.archs.contains(arch)
            ScreenScaffold(item.name, subtitle: Format.abbreviated(item.path)) {
                HStack(spacing: 8) {
                    Button("Reveal") { EngineActions.reveal(item.path) }.buttonStyle(EditorialButtonStyle(kind: .secondary))
                    Button("Copy Path") { ProtectionUI.copy(item.path) }.buttonStyle(EditorialButtonStyle(kind: .ghost))
                }
            } content: {
                TileGrid {
                    StatTile(label: "Binary size", value: Format.bytes(item.bytes), icon: "externaldrive")
                    StatTile(label: "Est. savings", value: Format.bytes(item.estimatedSavings), tint: Theme.accent, icon: "arrow.down.circle")
                    StatTile(label: "Reduction", value: Format.percent(Double(item.estimatedSavings) / Double(max(item.bytes, 1))), icon: "percent")
                    StatTile(label: "Architectures", value: "\(item.archs.count)", detail: item.archs.joined(separator: ", "), icon: "cpu")
                }
                Card("Architectures") {
                    HStack {
                        ForEach(item.archs, id: \.self) { a in
                            RiskBadge(text: a.uppercased(), tint: a == arch ? Theme.success : Theme.warning)
                        }
                        Spacer()
                        Text("Keeps \(arch), removes \(item.archs.filter { $0 != arch }.joined(separator: ", "))").font(Type.text(11)).foregroundStyle(Theme.muted)
                    }
                    StackedBar(segments: [
                        .init(label: "Kept (\(arch))", value: Double(item.bytes - item.estimatedSavings), color: Theme.success, text: Format.bytes(item.bytes - item.estimatedSavings)),
                        .init(label: "Removable", value: Double(item.estimatedSavings), color: Theme.accent, text: Format.bytes(item.estimatedSavings)),
                    ])
                }
                Card("Binary") {
                    KeyValueRow(key: "Executable", value: item.path, mono: true)
                    KeyValueRow(key: "App bundle", value: appPath ?? "—", mono: true)
                    KeyValueRow(key: "Device / inode", value: "\(item.device.map { String($0) } ?? "—") / \(item.inode.map { String($0) } ?? "—")", mono: true)
                    KeyValueRow(key: "Backups", value: "~/Library/Application Support/MacLean/UniversalBackups", mono: true)
                }
                Card("Thin this app") {
                    Text("Warning: the app's developer signature is replaced with an ad-hoc signature. Auto-updates, App Store updates, iCloud and keychain features may stop working, and Rosetta/other Macs can no longer run it. Reinstall the app to undo, or restore the backup.")
                        .font(Type.text(12)).foregroundStyle(Theme.danger).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        ConfirmButton(title: "Thin to \(arch)",
                                      message: "Rewrite \(item.name) to \(arch) only and ad-hoc re-sign \(appPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "the app")? Quit the app first. Signed updates may break.",
                                      kind: .destructive, disabled: !canThin || store.busy) {
                            Task {
                                let outcome = await store.thin([item])
                                failures = outcome.0.failures
                                result = outcome.1
                            }
                        }
                        if store.busy { ProgressView().controlSize(.small) }
                        if !canThin { Text("This binary has no \(arch) slice to keep.").font(Type.text(11)).foregroundStyle(Theme.warning) }
                    }
                    Text("Apps owned by root (App Store, system installers) need: sudo \(ProtectionUI.shellQuote(ProtectionUI.cliPath)) system --thin \(arch) --apply --yes  (thins every universal app)")
                        .font(Type.mono(10)).foregroundStyle(Theme.muted).textSelection(.enabled)
                }
                FailureList(failures: failures)
                if let result, !result.backups.isEmpty {
                    Card("Backups written") {
                        ForEach(result.backups, id: \.self) { backup in
                            HStack {
                                Text(Format.abbreviated(backup)).font(Type.mono(10)).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Button("Reveal") { EngineActions.reveal(backup) }.buttonStyle(EditorialButtonStyle(kind: .inline))
                            }
                        }
                    }
                }
            }
        } else if let result {
            ScreenScaffold("Universal Binary") {
                EmptyPanel(icon: "checkmark.circle", title: result.thinned.isEmpty ? "Binary no longer listed" : "Thinned to \(arch)",
                           message: result.backups.first.map { "Backup: \(Format.abbreviated($0))" })
                FailureList(failures: failures)
            }
        } else {
            ScreenScaffold("Universal Binary") { EmptyPanel(icon: "cpu", title: "Binary no longer listed") }
        }
    }
}
