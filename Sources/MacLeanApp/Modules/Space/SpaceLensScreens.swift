import AppKit
import MacLeanCore
import SwiftUI

// MARK: - Lens home

struct SpaceLensHomeScreen: View {
    @ObservedObject private var store = LensStore.shared
    @EnvironmentObject private var nav: Navigator

    struct Place: Identifiable {
        let title: String
        let path: String
        let icon: String
        var id: String { path }
    }

    private var places: [Place] {
        let home = SpacePaths.home
        var list = [
            Place(title: "Macintosh HD", path: "/", icon: "internaldrive"),
            Place(title: "Home", path: home, icon: "house"),
            Place(title: "Desktop", path: home + "/Desktop", icon: "menubar.dock.rectangle"),
            Place(title: "Documents", path: home + "/Documents", icon: "doc.on.doc"),
            Place(title: "Downloads", path: home + "/Downloads", icon: "arrow.down.circle"),
            Place(title: "Library", path: home + "/Library", icon: "building.columns"),
            Place(title: "Applications", path: "/Applications", icon: "square.grid.2x2"),
            Place(title: "Movies", path: home + "/Movies", icon: "film"),
            Place(title: "Pictures", path: home + "/Pictures", icon: "photo.on.rectangle"),
            Place(title: "Music", path: home + "/Music", icon: "music.note.list"),
            Place(title: "iCloud Drive", path: home + "/Library/Mobile Documents/com~apple~CloudDocs", icon: "icloud"),
            Place(title: "Developer", path: home + "/Developer", icon: "hammer"),
        ]
        for volume in (try? FileManager.default.contentsOfDirectory(atPath: "/Volumes")) ?? [] {
            let path = "/Volumes/\(volume)"
            if LensStore.normalize(path) != "/" { list.append(Place(title: volume, path: path, icon: "externaldrive")) }
        }
        return list.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    var body: some View {
        let _ = store.revision
        let disk = SpaceLensHomeScreen.volume("/")
        ScreenScaffold("Space Lens", subtitle: "Map every folder by size, drill in, and remove what you don't need") {
            Button("Choose Folder…") {
                if let path = SpaceStore.shared.chooseFolders(multiple: false).first { nav.push(.space(.lens(path))) }
            }
            .buttonStyle(EditorialButtonStyle(kind: .primary))
        } content: {
            if let disk {
                Card("Macintosh HD", trailing: "\(Format.bytes(disk.total)) capacity") {
                    HStack(spacing: 24) {
                        RingGauge(value: Double(disk.total - disk.available) / Double(max(disk.total, 1)), label: Format.percent(Double(disk.total - disk.available) / Double(max(disk.total, 1))), caption: "used", tint: Theme.accent, size: 110)
                        VStack(alignment: .leading, spacing: 8) {
                            KeyValueRow(key: "Used", value: Format.bytes(disk.total - disk.available))
                            KeyValueRow(key: "Available", value: Format.bytes(disk.available))
                            if let scanned = store.item("/") {
                                KeyValueRow(key: "Found by last scan", value: Format.bytes(scanned.bytes))
                                KeyValueRow(key: "Purgeable (counted as available)", value: Format.bytes(max(0, disk.physicalUsed - (disk.total - disk.available))))
                                if scanned.bytes > disk.physicalUsed {
                                    Text("Found more than the disk reports in use: APFS clones (copies that share blocks, e.g. VM images) are counted once per file, as du does.")
                                        .font(Type.text(11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                                } else {
                                    KeyValueRow(key: "Outside scanned folders (snapshots, system)", value: Format.bytes(disk.physicalUsed - scanned.bytes))
                                }
                            } else {
                                Text("Scan Macintosh HD to see where every gigabyte goes.").font(Type.text(12)).foregroundStyle(Theme.muted)
                            }
                        }
                        Spacer()
                        Button(store.item("/") == nil ? "Scan Disk" : "Open Map") { nav.push(.space(.lens("/"))) }
                            .buttonStyle(EditorialButtonStyle(kind: .primary))
                    }
                }
            }
            SectionHeader(title: "Places", detail: "click to scan · folders inside a scanned place open instantly")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 12)], spacing: 12) {
                ForEach(places) { place in
                    LensPlaceTile(place: place, item: store.item(place.path), saved: store.saved[LensStore.normalize(place.path)], running: store.sessions[LensStore.normalize(place.path)]?.state.isLoading == true) {
                        nav.push(.space(.lens(place.path)))
                    }
                }
            }
            let savedOnly = store.saved.values.filter { store.sessions[$0.root] == nil }.sorted { $0.scanned > $1.scanned }
            if !savedOnly.isEmpty {
                Card("Saved maps", trailing: "open instantly · \(savedOnly.count)") {
                    ForEach(savedOnly, id: \.root) { header in
                        HStack(spacing: 10) {
                            Image(systemName: "externaldrive.badge.checkmark").foregroundStyle(Theme.info)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(SpacePaths.display(header.root)).font(Type.text(12, weight: .semibold)).foregroundStyle(Theme.ink)
                                Text("\(Format.count(header.files)) files · \(Format.count(header.folders)) folders · scanned \(Format.relative(header.scanned))").font(Type.mono(10)).foregroundStyle(Theme.muted)
                            }
                            Spacer()
                            Text(Format.bytes(header.bytes)).font(Type.mono(12, weight: .semibold)).foregroundStyle(Theme.ink)
                            Button("Open") { nav.push(.space(.lens(header.root))) }.buttonStyle(EditorialButtonStyle(kind: .inline))
                            Button("Delete") { store.forget(header.root) }.buttonStyle(EditorialButtonStyle(kind: .inline))
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
            if !store.recent.isEmpty {
                Card("Open maps", trailing: "\(store.recent.count)") {
                    ForEach(store.recent) { session in
                        HStack(spacing: 10) {
                            Image(systemName: session.state.isLoading ? "hourglass" : "checkmark.circle").foregroundStyle(session.state.isLoading ? Theme.warning : Theme.success)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(SpacePaths.display(session.root)).font(Type.text(12, weight: .semibold)).foregroundStyle(Theme.ink)
                                Text(session.result.map { "\(Format.count($0.root.files)) files · \(Format.count($0.root.folders)) folders · \(String(format: "%.1f", $0.duration)) s" } ?? "scanning · \(Format.count(session.live.files)) files")
                                    .font(Type.mono(10)).foregroundStyle(Theme.muted)
                            }
                            Spacer()
                            Text(Format.bytes(session.result?.root.bytes ?? session.live.bytes)).font(Type.mono(12, weight: .semibold)).foregroundStyle(Theme.ink)
                            Button("Open") { nav.push(.space(.lens(session.root))) }.buttonStyle(EditorialButtonStyle(kind: .inline))
                            Button("Rescan") { store.scan(session.root, force: true) }.buttonStyle(EditorialButtonStyle(kind: .inline))
                                .disabled(session.state.isLoading)
                            Button("Forget") { store.forget(session.root) }.buttonStyle(EditorialButtonStyle(kind: .inline))
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
        }
    }

    /// `available` matches Finder (purgeable space counts as free);
    /// `physicalUsed` is what is actually allocated on disk.
    static func volume(_ path: String) -> (total: Int64, available: Int64, physicalUsed: Int64)? {
        guard let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]),
              let total = values.volumeTotalCapacity else { return nil }
        let physicalFree = Int64(values.volumeAvailableCapacity ?? 0)
        let available = values.volumeAvailableCapacityForImportantUsage ?? physicalFree
        return (Int64(total), available, Int64(total) - physicalFree)
    }
}

private struct LensPlaceTile: View {
    let place: SpaceLensHomeScreen.Place
    let item: LensItem?
    let saved: LensArchive.Header?
    let running: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: place.icon).font(.system(size: 20)).foregroundStyle(Theme.accent).frame(width: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text(place.title).font(Type.text(13, weight: .semibold)).foregroundStyle(Theme.ink)
                    if running {
                        Text("Scanning…").font(Type.text(11)).foregroundStyle(Theme.warning)
                    } else if let item {
                        Text("\(Format.bytes(item.bytes)) · \(Format.count(item.files)) files").font(Type.mono(10)).foregroundStyle(Theme.muted)
                    } else if let saved {
                        Text("\(Format.bytes(saved.bytes)) · saved \(Format.relative(saved.scanned))").font(Type.mono(10)).foregroundStyle(Theme.muted)
                    } else {
                        Text("Not scanned").font(Type.text(11)).foregroundStyle(Theme.faint)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.faint)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 10).fill(hovering ? Theme.line.opacity(0.45) : Theme.canvas))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Lens explorer

struct SpaceLensScreen: View {
    @Environment(\.contentWidth) private var contentWidth
    private var lensChartHeight: CGFloat { min(440, max(280, contentWidth * 0.5)) }
    let path: String
    @ObservedObject private var store = LensStore.shared
    @EnvironmentObject private var nav: Navigator
    @State private var hovered: LensItem?
    @State private var selection = Set<String>()
    @State private var search = ""
    @State private var sortByName = false
    @State private var showAll = false
    @State private var busy = false
    @State private var failures: [(path: String, reason: String)] = []

    var body: some View {
        let _ = store.revision
        let item = store.item(path)
        let running = store.sessions[LensStore.normalize(path)]
        ScreenScaffold(item?.name ?? (path == "/" ? "Macintosh HD" : (path as NSString).lastPathComponent), subtitle: Format.abbreviated(path)) {
            if item != nil {
                Button("Reveal") { EngineActions.reveal(path) }.buttonStyle(EditorialButtonStyle(kind: .ghost))
                Button("Rescan") { store.scan(path, force: true) }.buttonStyle(EditorialButtonStyle(kind: .secondary))
            }
        } content: {
            if let item, running?.state.isLoading != true {
                explorer(item)
            } else if let running, running.state.isLoading {
                LensScanProgress(session: running)
            } else if let running, case .failed(let message) = running.state {
                ErrorPanel(message: message) { store.scan(path, force: true) }
            } else {
                LoadingPanel(text: "Preparing scan…")
            }
        }
        .onAppear { store.scan(path) }
        .onDisappear { hovered = nil }
    }

    @ViewBuilder
    private func explorer(_ item: LensItem) -> some View {
        let session = store.session(covering: path)
        let parentBytes = item.parent?.bytes
        let largest = item.children.first { !$0.isAggregate }
        LensBreadcrumb(item: item) { LensStore.open($0, nav: nav) }
        if let session, let scanned = session.scanned {
            HStack(spacing: 8) {
                Image(systemName: session.fromDisk ? "externaldrive.badge.checkmark" : "checkmark.circle").foregroundStyle(session.fromDisk ? Theme.info : Theme.success)
                Text((session.fromDisk ? "Saved map from \(Format.relative(scanned)) — files may have changed since." : "Scanned \(Format.relative(scanned))\(session.elevated ? " as administrator" : "") · map saved for next launch") + (session.note.map { " " + $0 } ?? ""))
                    .font(Type.text(11)).foregroundStyle(Theme.muted)
                Spacer()
                if session.fromDisk {
                    Button("Rescan now") { store.scan(session.root, force: true) }.buttonStyle(EditorialButtonStyle(kind: .inline))
                }
            }
        }
        TileGrid(minWidth: 150) {
            StatTile(label: "Size", value: Format.bytes(item.bytes), detail: parentBytes.map { Format.percent(Double(item.bytes) / Double(max($0, 1)), digits: 1) + " of parent" }, tint: Theme.accent, icon: "internaldrive")
            StatTile(label: "Files", value: Format.count(item.files), icon: "doc.on.doc")
            StatTile(label: "Folders", value: Format.count(item.folders), icon: "folder")
            StatTile(label: "Largest", value: largest.map { Format.bytes($0.bytes) } ?? "—", detail: largest?.name, icon: "arrow.up.right.circle")
            StatTile(label: "Last change", value: Format.relative(item.modified), detail: Format.date(item.modified), icon: "clock")
            if item.unreadable > 0 {
                StatTile(label: "Unreadable", value: Format.count(item.unreadable), detail: "folders · needs Full Disk Access", tint: Theme.warning, icon: "lock")
            } else if let session {
                StatTile(label: "Scan", value: String(format: "%.1f s", session.result?.duration ?? 0), detail: "\(Format.relative(session.finished)) · \(SpacePaths.display(session.root))", icon: "timer")
            }
        }

        AdaptiveStack(threshold: 860) {
            Card(nil, padding: 12) {
                VStack(spacing: 10) {
                    HStack {
                        Picker("Chart", selection: $store.style) {
                            ForEach(LensChartStyle.allCases) { Label($0.rawValue, systemImage: $0.icon).tag($0) }
                        }
                        .pickerStyle(.segmented).labelsHidden().flexibleWidth(290)
                        Spacer()
                        if item.parent != nil {
                            Button { if let parent = item.parent { LensStore.open(parent, nav: nav) } } label: { Label("Up", systemImage: "arrow.up") }
                                .buttonStyle(EditorialButtonStyle(kind: .inline))
                        }
                    }
                    chart(item)
                        .frame(height: lensChartHeight)
                        .id(item.path + store.style.rawValue)
                        .transition(.opacity.combined(with: .scale(scale: 0.97)))
                    LensHoverLine(item: hovered ?? item, parent: item, isHover: hovered != nil)
                }
            }
            .frame(minWidth: 300)
            contents(item)
                .frame(minWidth: 280, maxWidth: contentWidth >= 860 * Type.scale ? 460 : .infinity)
        }
        .animation(.easeInOut(duration: 0.2), value: item.path)

        if item.bytes > 0 {
            let kinds = LensKind.allCases.map { (kind: $0, bytes: $0.rawValue < item.kindBytes.count ? item.kindBytes[$0.rawValue] : 0) }.filter { $0.bytes > 0 }.sorted { $0.bytes > $1.bytes }
            Card("What's inside", trailing: "by file type") {
                StackedBar(segments: kinds.map { .init(label: $0.kind.title, value: Double($0.bytes), color: LensColors.kind($0.kind), text: Format.bytes($0.bytes)) })
            }
        }
        if !failures.isEmpty { FailureList(failures: failures) }
        let below = store.largest(under: path)
        NavRow(icon: "arrow.up.doc", title: "Largest files here", subtitle: "Every file over 20 MB below this folder", value: "\(below.count) · \(Format.bytes(below.reduce(0) { $0 + $1.bytes }))", route: .space(.lensLargest(path)))
        NavRow(icon: "chart.pie", title: "File types here", subtitle: "Space by kind with the biggest examples", value: Format.bytes(item.bytes), route: .space(.lensTypes(path)))
    }

    @ViewBuilder
    private func chart(_ item: LensItem) -> some View {
        let open: (LensItem) -> Void = { LensStore.open($0, nav: nav) }
        if item.children.isEmpty {
            EmptyPanel(icon: "tray", title: "Empty folder", message: "Nothing to show here.")
        } else {
            switch store.style {
            case .sunburst:
                LensSunburst(item: item, revision: store.revision, hovered: $hovered, onOpen: open,
                             onUp: item.parent.map { parent in { LensStore.open(parent, nav: nav) } })
            case .bubbles:
                LensBubbles(item: item, revision: store.revision, hovered: $hovered, onOpen: open)
            case .treemap:
                LensTreemapChart(item: item, revision: store.revision, hovered: $hovered, onOpen: open)
            }
        }
    }

    @ViewBuilder
    private func contents(_ item: LensItem) -> some View {
        let q = search.lowercased()
        let list = item.children.filter { q.isEmpty || $0.name.lowercased().contains(q) }
        let rows = sortByName ? list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } : list
        let chosen = item.children.filter { selection.contains($0.path) }
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                SearchField(text: $search, prompt: "Filter \(item.children.count) items")
                Toggle("A–Z", isOn: $sortByName).toggleStyle(.button).controlSize(.small)
            }
            SelectionBar(
                selectedCount: chosen.count,
                totalCount: item.children.filter { !$0.isAggregate }.count,
                selectedBytes: chosen.reduce(0) { $0 + $1.bytes },
                actionTitle: "Move to Trash",
                confirmMessage: "\(chosen.count) items (\(Format.bytes(chosen.reduce(0) { $0 + $1.bytes }))) move to the Trash. Protected folders are refused by the engine.",
                busy: busy,
                onSelectAll: { selection = Set(rows.filter { !$0.isAggregate && SpaceSafety.canRemove($0.path) }.map(\.path)) },
                onSelectNone: { selection = [] },
                action: { remove(chosen) }
            )
            VStack(spacing: 0) {
                    ForEach(Array((showAll ? rows : Array(rows.prefix(11))).enumerated()), id: \.element.path) { index, child in
                        LensRow(
                            item: child,
                            parentBytes: max(item.bytes, 1),
                            color: LensColors.child(child, index: item.children.firstIndex { $0 === child } ?? index),
                            selected: Binding(
                                get: { selection.contains(child.path) },
                                set: { on in if on { selection.insert(child.path) } else { selection.remove(child.path) } }
                            ),
                            highlighted: hovered.map { $0 === child || $0.path.hasPrefix(child.path + "/") } ?? false,
                            protected: child.isAggregate || !SpaceSafety.canRemove(child.path),
                            onHover: { inside in hovered = inside ? child : (hovered === child ? nil : hovered) }
                        ) { LensStore.open(child, nav: nav) }
                        Divider().opacity(0.35)
                    }
                    if rows.count > 11 {
                        Button(showAll ? "Show top 11" : "Show all \(rows.count) items") { showAll.toggle() }
                            .buttonStyle(EditorialButtonStyle(kind: .inline))
                            .padding(8)
                    }
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.canvas))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
        }
    }

    private func remove(_ items: [LensItem]) {
        busy = true
        Task {
            let summary = await store.remove(items, title: "Space Lens: moved to Trash")
            failures = summary.failures
            selection.subtract(items.map(\.path))
            busy = false
        }
    }
}

private struct LensBreadcrumb: View {
    let item: LensItem
    let open: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                let lineage = item.lineage
                ForEach(Array(lineage.enumerated()), id: \.element.path) { index, node in
                    if index > 0 { Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.faint) }
                    Button { open(node.path) } label: {
                        HStack(spacing: 4) {
                            Image(systemName: index == 0 ? "scope" : "folder").font(.system(size: 10))
                            Text(index == 0 && node.path == "/" ? "Macintosh HD" : node.name).font(Type.text(11, weight: index == lineage.count - 1 ? .semibold : .regular))
                            Text(Format.bytes(node.bytes)).font(Type.mono(9)).foregroundStyle(Theme.faint)
                        }
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Capsule().fill(index == lineage.count - 1 ? Theme.accent.opacity(0.15) : Theme.line.opacity(0.35)))
                        .foregroundStyle(index == lineage.count - 1 ? Theme.accent : Theme.ink)
                    }
                    .buttonStyle(.plain)
                    .disabled(index == lineage.count - 1)
                }
            }
        }
    }
}

private struct LensHoverLine: View {
    let item: LensItem
    let parent: LensItem
    let isHover: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: LensColors.icon(item)).foregroundStyle(item.isDirectory ? Theme.info : LensColors.kind(item.kind)).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(Type.text(12, weight: .semibold)).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.middle)
                Text(detail).font(Type.mono(10)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if isHover, parent.bytes > 0 {
                Text(Format.percent(Double(item.bytes) / Double(parent.bytes), digits: 1)).font(Type.mono(11)).foregroundStyle(Theme.accent)
            }
            Text(Format.bytes(item.bytes)).font(Type.mono(13, weight: .semibold)).foregroundStyle(Theme.ink)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.line.opacity(0.3)))
    }

    private var detail: String {
        var parts: [String] = []
        if item.isDirectory || item.isAggregate { parts.append("\(Format.count(item.files)) files") }
        if item.folders > 0 { parts.append("\(Format.count(item.folders)) folders") }
        if let modified = item.modified { parts.append("changed \(Format.relative(modified))") }
        if !isHover { parts.append("hover for details") } else if item.isAggregate { parts.append("grouped small items") } else { parts.append(Format.abbreviated(item.path)) }
        return parts.joined(separator: " · ")
    }
}

struct LensRow: View {
    let item: LensItem
    let parentBytes: Int64
    let color: Color
    @Binding var selected: Bool
    var highlighted: Bool
    var protected: Bool
    var onHover: (Bool) -> Void = { _ in }
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        let fraction = Double(item.bytes) / Double(parentBytes)
        HStack(spacing: 9) {
            Button { if !protected { selected.toggle() } } label: {
                Image(systemName: protected ? (item.isAggregate ? "minus" : "lock.fill") : (selected ? "checkmark.square.fill" : "square"))
                    .font(.system(size: protected ? 10 : 14))
                    .foregroundStyle(selected ? Theme.accent : Theme.faint)
                    .frame(width: 16)
            }
            .buttonStyle(.plain)
            .disabled(protected)
            .help(item.isAggregate ? "Small items are grouped; click the row to review them one by one" : (protected ? "Protected location" : "Select"))
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 4, height: 26)
            Image(systemName: LensColors.icon(item)).foregroundStyle(item.isDirectory ? Theme.info : LensColors.kind(item.kind)).frame(width: 16)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).font(Type.text(12, weight: .medium)).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.middle)
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.line.opacity(0.5))
                        Capsule().fill(color).frame(width: max(2, proxy.size.width * CGFloat(min(1, fraction))))
                    }
                }
                .frame(height: 3)
            }
            VStack(alignment: .trailing, spacing: 1) {
                Text(Format.bytes(item.bytes)).font(Type.mono(11, weight: .semibold)).foregroundStyle(Theme.ink).monospacedDigit()
                Text(Format.percent(fraction, digits: 1)).font(Type.mono(9)).foregroundStyle(Theme.muted)
            }
            .frame(width: 72, alignment: .trailing)
            Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.faint)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background((hovering || highlighted) ? Theme.line.opacity(0.4) : .clear)
        .contentShape(Rectangle())
        .onHover { inside in hovering = inside; onHover(inside) }
        .onTapGesture { open() }
        .contextMenu {
            if !item.isAggregate {
                Button("Open") { open() }
                Button("Reveal in Finder") { EngineActions.reveal(item.path) }
            }
        }
    }
}

// MARK: - Live scan

struct LensScanProgress: View {
    let session: LensStore.Session
    @ObservedObject private var store = LensStore.shared

    var body: some View {
        let _ = store.revision
        let live = session.live
        let rate = session.rateHistory.suffix(6).reduce(0, +) / Double(max(1, min(6, session.rateHistory.count)))
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                ProgressView().controlSize(.regular)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Mapping \(SpacePaths.display(session.root))").font(Type.display(22)).foregroundStyle(Theme.ink)
                    Text(Format.abbreviated(live.current)).font(Type.mono(10)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Button("Cancel") { store.cancel(session.root) }.buttonStyle(EditorialButtonStyle(kind: .secondary))
            }
            TileGrid(minWidth: 150) {
                StatTile(label: "Found", value: Format.bytes(live.bytes), tint: Theme.accent, history: session.bytesHistory, icon: "internaldrive")
                StatTile(label: "Files", value: Format.count(live.files), icon: "doc.on.doc")
                StatTile(label: "Folders", value: Format.count(live.folders), icon: "folder")
                StatTile(label: "Speed", value: Format.count(Int(rate)), unit: "files/s", history: session.rateHistory, icon: "speedometer")
                StatTile(label: "Elapsed", value: String(format: "%.0f s", session.elapsed), icon: "timer")
                StatTile(label: "Unreadable", value: Format.count(live.unreadable), tint: live.unreadable > 0 ? Theme.warning : Theme.ink, icon: "lock")
            }
            Card("Throughput", trailing: "files per second") {
                LiveChart(series: [.init(values: session.rateHistory, color: Theme.accent, label: "files/s")], capacity: 120, height: 120)
            }
            Text(session.root == "/" ? (session.elevated ? "Scanning as administrator, so system folders are measured too. Folders macOS privacy-protects (Mail, Messages…) still need Full Disk Access; system volumes are counted once." : "Scanning the whole disk reads every folder you can access. Grant Full Disk Access for complete results; system volumes are counted once (APFS firmlinks are not double-counted).") : "Every folder is read once; afterwards drilling into any sub-folder is instant.")
                .font(Type.text(11)).foregroundStyle(Theme.muted)
        }
    }
}

// MARK: - Largest files

struct SpaceLensLargestScreen: View {
    let path: String
    @ObservedObject private var store = LensStore.shared
    @EnvironmentObject private var nav: Navigator
    @State private var selection = Set<String>()
    @State private var byDate = false
    @State private var busy = false
    @State private var failures: [(path: String, reason: String)] = []

    var body: some View {
        let _ = store.revision
        let files = store.largest(under: path)
        let rows = byDate ? files.sorted { ($0.modified ?? .distantFuture) < ($1.modified ?? .distantFuture) } : files
        let chosen = files.filter { selection.contains($0.path) }
        ScreenScaffold("Largest Files", subtitle: SpacePaths.display(path)) {
            Toggle("Oldest first", isOn: $byDate).toggleStyle(EditorialToggleStyle())
        } content: {
            TileGrid {
                StatTile(label: "Files", value: Format.count(files.count), icon: "doc.on.doc")
                StatTile(label: "Total", value: Format.bytes(files.reduce(0) { $0 + $1.bytes }), tint: Theme.accent, icon: "internaldrive")
                StatTile(label: "Biggest", value: Format.bytes(files.first?.bytes ?? 0), detail: files.first?.name)
            }
            if store.session(covering: path) == nil {
                EmptyPanel(icon: "scope", title: "Not scanned", message: "Open this folder in Space Lens first.", actionTitle: "Scan") { nav.push(.space(.lens(path))) }
            }
            SelectionBar(
                selectedCount: chosen.count, totalCount: files.count, selectedBytes: chosen.reduce(0) { $0 + $1.bytes },
                actionTitle: "Move to Trash", busy: busy,
                onSelectAll: { selection = Set(files.filter { SpaceSafety.canRemove($0.path) }.map(\.path)) },
                onSelectNone: { selection = [] },
                action: {
                    busy = true
                    let items = chosen.map { SpaceFile(path: $0.path, bytes: $0.bytes, modified: $0.modified) }
                    Task {
                        let summary = await SpaceStore.shared.trash(items, title: "Space Lens: removed large files")
                        failures = summary.failures
                        selection = []
                        busy = false
                    }
                }
            )
            FailureList(failures: failures)
            LazyVStack(spacing: 4) {
                ForEach(rows) { file in
                    CheckRow(
                        isOn: Binding(get: { selection.contains(file.path) }, set: { on in if on { selection.insert(file.path) } else { selection.remove(file.path) } }),
                        title: file.name,
                        subtitle: "\(file.kind.title) · \(Format.abbreviated((file.path as NSString).deletingLastPathComponent)) · changed \(Format.relative(file.modified))",
                        value: Format.bytes(file.bytes),
                        onOpen: { nav.push(.space(.fileDetail(file.path))) },
                        onReveal: { EngineActions.reveal(file.path) }
                    )
                }
            }
        }
    }
}

// MARK: - File types

struct SpaceLensTypesScreen: View {
    let path: String
    @ObservedObject private var store = LensStore.shared
    @EnvironmentObject private var nav: Navigator

    var body: some View {
        let _ = store.revision
        let item = store.item(path)
        let files = store.largest(under: path)
        ScreenScaffold("File Types", subtitle: SpacePaths.display(path)) {
            EmptyView()
        } content: {
            if let item {
                let kinds = LensKind.allCases
                    .map { (kind: $0, bytes: $0.rawValue < item.kindBytes.count ? item.kindBytes[$0.rawValue] : 0) }
                    .filter { $0.bytes > 0 }
                    .sorted { $0.bytes > $1.bytes }
                Card("Space by kind", trailing: Format.bytes(item.bytes)) {
                    StackedBar(segments: kinds.map { .init(label: $0.kind.title, value: Double($0.bytes), color: LensColors.kind($0.kind), text: Format.bytes($0.bytes)) })
                    let peak = Double(kinds.first?.bytes ?? 1)
                    ForEach(kinds, id: \.kind) { entry in
                        BarRow(label: entry.kind.title, value: Double(entry.bytes), total: peak,
                               valueText: "\(Format.bytes(entry.bytes)) · \(Format.percent(Double(entry.bytes) / Double(max(item.bytes, 1)), digits: 1))",
                               tint: LensColors.kind(entry.kind))
                    }
                }
                ForEach(kinds, id: \.kind) { entry in
                    let examples = files.filter { $0.kind == entry.kind }.prefix(6)
                    if !examples.isEmpty {
                        Card(entry.kind.title, trailing: "largest examples") {
                            ForEach(Array(examples)) { file in
                                BarRow(label: file.name, value: Double(file.bytes), total: Double(examples.first?.bytes ?? 1), valueText: Format.bytes(file.bytes), tint: LensColors.kind(entry.kind)) {
                                    nav.push(.space(.fileDetail(file.path)))
                                }
                            }
                        }
                    }
                }
            } else {
                EmptyPanel(icon: "scope", title: "Not scanned", message: "Open this folder in Space Lens first.", actionTitle: "Scan") { nav.push(.space(.lens(path))) }
            }
        }
    }
}

// MARK: - File detail

struct SpaceFileDetailScreen: View {
    let path: String
    @ObservedObject private var store = SpaceStore.shared
    @EnvironmentObject private var nav: Navigator
    @State private var detail: SpaceFileDetail?
    @State private var state: LoadState = .idle
    @State private var dimensions: String?
    @State private var failures: [(path: String, reason: String)] = []

    var body: some View {
        ScreenScaffold((path as NSString).lastPathComponent, subtitle: Format.abbreviated(path)) {
            Button("Open") { EngineActions.open(path) }.buttonStyle(EditorialButtonStyle(kind: .secondary))
            Button("Reveal in Finder") { EngineActions.reveal(path) }.buttonStyle(EditorialButtonStyle(kind: .ghost))
        } content: {
            RefreshLine(state: state) { Task { await load() } }
            if case .failed(let message) = state { ErrorPanel(message: message) }
            if let d = detail {
                let f = d.file
                TileGrid {
                    StatTile(label: "Size on disk", value: Format.bytes(f.bytes), detail: f.isDirectory ? "\(Format.count(f.files)) files" : nil, tint: Theme.accent, icon: "internaldrive")
                    StatTile(label: "Modified", value: Format.relative(f.modified), detail: Format.date(f.modified), icon: "pencil")
                    StatTile(label: "Created", value: Format.relative(f.created), detail: Format.date(f.created), icon: "calendar")
                    StatTile(label: "Last opened", value: Format.relative(f.accessed), detail: Format.date(f.accessed), icon: "eye")
                }
                HStack(alignment: .top, spacing: 16) {
                    if !f.isDirectory, f.kind == .images {
                        Card("Preview") { SpaceThumbnail(path: path, size: 200) }
                    }
                    Card("Information") {
                        KeyValueRow(key: "Kind", value: d.typeDescription)
                        KeyValueRow(key: "Category", value: f.isDirectory ? "Folder" : f.kind.title)
                        KeyValueRow(key: "Type identifier", value: d.uti, mono: true)
                        if let dimensions { KeyValueRow(key: "Dimensions", value: dimensions, mono: true) }
                        KeyValueRow(key: "Bytes", value: Format.count(Int(clamping: f.bytes)), mono: true)
                        KeyValueRow(key: "Added to folder", value: Format.date(f.added))
                        KeyValueRow(key: "Location", value: Format.abbreviated((path as NSString).deletingLastPathComponent), mono: true)
                        KeyValueRow(key: "Package", value: d.isPackage ? "Yes" : "No")
                        KeyValueRow(key: "Hidden", value: d.isHidden ? "Yes" : "No")
                    }
                    Card("Permissions") {
                        KeyValueRow(key: "Mode", value: d.permissions, mono: true)
                        KeyValueRow(key: "Owner", value: d.owner, mono: true)
                        KeyValueRow(key: "Group", value: d.group, mono: true)
                        KeyValueRow(key: "Writable by you", value: d.isWritable ? "Yes" : "No")
                    }
                }
                if f.isDirectory {
                    NavRow(icon: "circle.hexagongrid", title: "Open in Space Lens", subtitle: "Browse this folder's contents by size", value: Format.bytes(f.bytes), route: .space(.lens(path)))
                }
                Card("Actions") {
                    HStack(spacing: 10) {
                        Button("Copy Path") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(path, forType: .string)
                            ToastCenter.shared.show("Path copied")
                        }
                        .buttonStyle(EditorialButtonStyle(kind: .secondary))
                        Button("Show Parent in Lens") { nav.push(.space(.lens((path as NSString).deletingLastPathComponent))) }
                            .buttonStyle(EditorialButtonStyle(kind: .secondary))
                        Spacer()
                        if let reason = SpaceSafety.refusal(path) {
                            RiskBadge(text: "Protected: \(reason)", tint: Theme.danger)
                        } else {
                            ConfirmButton(
                                title: "Move to Trash",
                                message: "\(f.name) (\(Format.bytes(f.bytes))) will be moved to the Trash. You can restore it from the Trash until it is emptied.",
                                kind: .destructive
                            ) { trash(f) }
                        }
                    }
                }
                FailureList(failures: failures)
            } else if state.isLoading {
                LoadingPanel(text: "Reading file information")
            }
        }
        .task(id: path) { await load() }
    }

    private func load() async {
        state = .loading("Reading attributes…")
        let p = path
        let result = await engine { SpaceFileDetail.load(p) }
        let dims = await engine { SpaceThumb.dimensions(p) }
        if let result {
            detail = result
            dimensions = result.file.kind == .images ? dims : nil
            state = .loaded(Date())
        } else {
            state = .failed("This item no longer exists or cannot be read.")
        }
    }

    private func trash(_ f: SpaceFile) {
        Task {
            let summary = await store.trash([f], title: "Moved \(f.name) to Trash")
            failures = summary.failures
            if summary.failures.isEmpty { nav.pop() }
        }
    }
}


// MARK: - Smaller items

/// The entries folded into a folder's "smaller items", measured on demand so
/// they can be reviewed and removed one by one.
struct SpaceLensSmallScreen: View {
    let path: String
    @ObservedObject private var store = LensStore.shared
    @EnvironmentObject private var nav: Navigator
    @State private var items: [LensItem] = []
    @State private var state: LoadState = .idle
    @State private var selection = Set<String>()
    @State private var busy = false
    @State private var failures: [(path: String, reason: String)] = []

    var body: some View {
        let _ = store.revision
        let chosen = items.filter { selection.contains($0.path) }
        ScreenScaffold("Smaller Items", subtitle: SpacePaths.display(path)) {
            Button("Reveal Folder") { EngineActions.reveal(path) }.buttonStyle(EditorialButtonStyle(kind: .ghost))
            RefreshLine(state: state) { Task { await load() } }
        } content: {
            TileGrid {
                StatTile(label: "Items", value: Format.count(items.count), detail: "\(items.filter(\.isDirectory).count) folders", icon: "list.bullet")
                StatTile(label: "Total", value: Format.bytes(items.reduce(0) { $0 + $1.bytes }), tint: Theme.accent, icon: "internaldrive")
                StatTile(label: "Largest", value: Format.bytes(items.first?.bytes ?? 0), detail: items.first?.name)
            }
            Text("Space Lens keeps the biggest items of every folder in its map and groups the rest. They are listed and measured here so you can remove any of them.")
                .font(Type.text(11)).foregroundStyle(Theme.muted)
            SelectionBar(
                selectedCount: chosen.count, totalCount: items.count, selectedBytes: chosen.reduce(0) { $0 + $1.bytes },
                actionTitle: "Move to Trash", busy: busy,
                onSelectAll: { selection = Set(items.filter { SpaceSafety.canRemove($0.path) }.map(\.path)) },
                onSelectNone: { selection = [] },
                action: {
                    busy = true
                    let targets = chosen
                    Task {
                        let summary = await store.remove(targets, title: "Space Lens: removed small items")
                        failures = summary.failures
                        selection = []
                        await load()
                        busy = false
                    }
                }
            )
            FailureList(failures: failures)
            if state.isLoading && items.isEmpty {
                LoadingPanel(text: "Measuring grouped items…")
            } else if items.isEmpty {
                EmptyPanel(icon: "checkmark.circle", title: "Nothing grouped here", message: "Every item of this folder is shown in the map.")
            }
            LazyVStack(spacing: 4) {
                ForEach(items, id: \.path) { item in
                    CheckRow(
                        isOn: Binding(get: { selection.contains(item.path) }, set: { on in if on { selection.insert(item.path) } else { selection.remove(item.path) } }),
                        title: item.name,
                        subtitle: (item.isDirectory ? "Folder · \(Format.count(item.files)) files" : item.kind.title) + " · changed \(Format.relative(item.modified))",
                        value: Format.bytes(item.bytes),
                        onOpen: { nav.push(.space(item.isDirectory ? .lens(item.path) : .fileDetail(item.path))) },
                        onReveal: { EngineActions.reveal(item.path) }
                    )
                }
            }
        }
        .task(id: path) { await load() }
    }

    private func load() async {
        guard let folder = store.item(path) else {
            state = .failed("Open this folder in Space Lens first.")
            return
        }
        state = .loading("Measuring…")
        items = await engine { LensScanner.foldedItems(of: folder) }
        selection.formIntersection(items.map(\.path))
        state = .loaded(Date())
    }
}
