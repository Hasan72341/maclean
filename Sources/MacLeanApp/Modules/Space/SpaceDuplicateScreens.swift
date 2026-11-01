import MacLeanCore
import SwiftUI

// MARK: - Duplicates

struct SpaceDuplicatesScreen: View {
    @ObservedObject private var store = SpaceStore.shared
    @EnvironmentObject private var nav: Navigator
    @ObservedObject private var sel = SpaceDupSelection.shared
    @State private var busy = false
    @State private var failures: [(path: String, reason: String)] = []
    @State private var search = ""

    var body: some View {
        let groups = filtered
        let wasted = store.duplicates.reduce(Int64(0)) { $0 + $1.wastedBytes }
        let selectedBytes = selectedFiles.reduce(Int64(0)) { $0 + $1.bytes }
        ScreenScaffold("Duplicates", subtitle: "Byte-identical files found by size + SHA-256") {
            SpaceRootPicker(roots: $store.dupRoots)
            Card {
                HStack(spacing: 14) {
                    Text("MIN SIZE").font(Type.label).tracking(1).foregroundStyle(Theme.muted)
                    Slider(value: $store.dupMinMB, in: 0.1...500).frame(maxWidth: 260)
                    Text(Format.bytes(Int64(store.dupMinMB * 1_048_576))).font(Type.mono(11, weight: .semibold)).frame(width: 80, alignment: .leading)
                    Spacer()
                    Button("Find Duplicates") { Task { sel.selection = []; await store.scanDuplicates() } }
                        .buttonStyle(EditorialButtonStyle(kind: .primary))
                        .disabled(store.dupState.isLoading || store.dupRoots.isEmpty)
                }
            }
            RefreshLine(state: store.dupState) { Task { sel.selection = []; await store.scanDuplicates() } }
            if store.dupState.isLoading {
                LoadingPanel(text: "Finding duplicates", detail: "Grouping by size, then hashing candidates in \(store.dupRoots.count) folder(s)")
            }
            if store.dupState.loadedAt != nil {
                TileGrid {
                    StatTile(label: "Groups", value: Format.count(store.duplicates.count), icon: "square.on.square")
                    StatTile(label: "Duplicate files", value: Format.count(store.duplicates.reduce(0) { $0 + $1.paths.count }), icon: "doc.on.doc")
                    StatTile(label: "Reclaimable", value: Format.bytes(wasted), detail: "keeping one copy each", tint: Theme.accent, icon: "arrow.uturn.backward.circle")
                    StatTile(label: "Selected", value: Format.bytes(selectedBytes), detail: "\(sel.selection.count) files", tint: Theme.warning, icon: "checkmark.square")
                }
                if store.duplicates.isEmpty {
                    EmptyPanel(icon: "checkmark.seal", title: "No duplicates", message: "No identical files over \(Format.bytes(Int64(store.dupMinMB * 1_048_576))) in the chosen folders.")
                } else {
                    Card("Auto-select") {
                        HStack(spacing: 10) {
                            Button("Keep newest, select others") { sel.selection = store.duplicateCopies(keepNewest: true) }
                                .buttonStyle(EditorialButtonStyle(kind: .secondary))
                            Button("Keep oldest, select others") { sel.selection = store.duplicateCopies(keepNewest: false) }
                                .buttonStyle(EditorialButtonStyle(kind: .secondary))
                            Button("Clear") { sel.selection = [] }.buttonStyle(EditorialButtonStyle(kind: .ghost))
                            Spacer()
                            SearchField(text: $search, prompt: "Filter by name").frame(maxWidth: 220)
                        }
                    }
                    if !failures.isEmpty { FailureList(failures: failures) }
                    SelectionBar(
                        selectedCount: sel.selection.count,
                        totalCount: store.duplicates.reduce(0) { $0 + $1.paths.count },
                        selectedBytes: selectedBytes,
                        actionTitle: "Move to Trash",
                        confirmMessage: allCopiesWarning ?? "Selected copies are moved to the Trash. At least one copy of each group is kept unless you selected every copy.",
                        busy: busy,
                        onSelectAll: { sel.selection = store.duplicateCopies(keepNewest: true) },
                        onSelectNone: { sel.selection = [] },
                        action: trash
                    )
                    LazyVStack(spacing: 8) {
                        ForEach(groups.prefix(500), id: \.hash) { group in
                            let picked = group.paths.filter { sel.selection.contains($0) }.count
                            NavRow(
                                icon: SpaceKind.classify((group.paths[0] as NSString).pathExtension.lowercased()).icon,
                                title: (group.paths[0] as NSString).lastPathComponent,
                                subtitle: "\(group.paths.count) copies × \(Format.bytes(group.size)) · \(picked) selected · \(Format.abbreviated((group.paths[0] as NSString).deletingLastPathComponent))",
                                value: Format.bytes(group.wastedBytes),
                                route: .space(.duplicateGroup(group.hash))
                            )
                        }
                    }
                }
            } else if store.dupState == .idle {
                EmptyPanel(icon: "square.on.square", title: "Find identical files", message: "Choose folders above, then start the scan. Files are compared by full SHA-256 hash.")
            }
        }
    }

    private var filtered: [DuplicateGroup] {
        guard !search.isEmpty else { return store.duplicates }
        let q = search.lowercased()
        return store.duplicates.filter { $0.paths.contains { $0.lowercased().contains(q) } }
    }

    private var selectedFiles: [SpaceFile] {
        var out: [SpaceFile] = []
        for g in store.duplicates {
            for p in g.paths where sel.selection.contains(p) {
                out.append(store.dupInfo[p] ?? SpaceFile(path: p, bytes: g.size))
            }
        }
        return out
    }

    private var allCopiesWarning: String? {
        let full = store.duplicates.filter { g in g.paths.allSatisfy { sel.selection.contains($0) } }
        guard !full.isEmpty else { return nil }
        return "Warning: every copy is selected in \(full.count) group(s) — those files will have no remaining copy outside the Trash."
    }

    private func trash() {
        let files = selectedFiles
        busy = true
        Task {
            let summary = await store.trash(files, title: "Duplicate copies moved to Trash")
            failures = summary.failures
            let failed = Set(summary.failures.map(\.path))
            sel.selection = sel.selection.filter { failed.contains($0) }
            busy = false
        }
    }
}

/// Shares the duplicate selection between the list and per-group screens.
@MainActor
final class SpaceDupSelection: ObservableObject {
    static let shared = SpaceDupSelection()
    @Published var selection = Set<String>()

    func set(_ path: String, _ on: Bool) {
        if on { selection.insert(path) } else { selection.remove(path) }
    }
}

struct SpaceDuplicateGroupScreen: View {
    let hash: String
    @ObservedObject private var store = SpaceStore.shared
    @ObservedObject private var shared = SpaceDupSelection.shared
    @EnvironmentObject private var nav: Navigator
    @State private var busy = false
    @State private var failures: [(path: String, reason: String)] = []

    var body: some View {
        ScreenScaffold("Duplicate Group", subtitle: "SHA-256 \(hash.prefix(16))…") {
            if let group = store.duplicateGroup(hash) {
                let files = group.paths.map { store.dupInfo[$0] ?? SpaceFile(path: $0, bytes: group.size) }
                let picked = files.filter { shared.selection.contains($0.path) }
                TileGrid {
                    StatTile(label: "Copies", value: Format.count(group.paths.count), icon: "doc.on.doc")
                    StatTile(label: "File size", value: Format.bytes(group.size), icon: "doc")
                    StatTile(label: "Reclaimable", value: Format.bytes(group.wastedBytes), tint: Theme.accent, icon: "arrow.uturn.backward.circle")
                    StatTile(label: "Selected", value: "\(picked.count)", detail: Format.bytes(picked.reduce(0) { $0 + $1.bytes }), tint: Theme.warning, icon: "checkmark.square")
                }
                if let first = files.first, first.kind == .images {
                    Card("Preview") { SpaceThumbnail(path: first.path, size: 160) }
                }
                Card("Auto-select") {
                    HStack(spacing: 10) {
                        Button("Keep newest") { apply(store.duplicateCopies(keepNewest: true, in: [group]), group) }
                            .buttonStyle(EditorialButtonStyle(kind: .secondary))
                        Button("Keep oldest") { apply(store.duplicateCopies(keepNewest: false, in: [group]), group) }
                            .buttonStyle(EditorialButtonStyle(kind: .secondary))
                        Button("Keep shortest path") {
                            let keep = group.paths.min { $0.count < $1.count }
                            apply(Set(group.paths.filter { $0 != keep && SpaceSafety.canRemove($0) }), group)
                        }
                        .buttonStyle(EditorialButtonStyle(kind: .secondary))
                        Button("Clear") { apply([], group) }.buttonStyle(EditorialButtonStyle(kind: .ghost))
                    }
                }
                if picked.count == files.count {
                    ErrorPanel(message: "Every copy is selected — removing them leaves no copy outside the Trash.")
                }
                FailureList(failures: failures)
                SelectionBar(
                    selectedCount: picked.count, totalCount: files.count,
                    selectedBytes: picked.reduce(0) { $0 + $1.bytes },
                    actionTitle: "Move to Trash", busy: busy,
                    onSelectAll: { apply(Set(group.paths), group) },
                    onSelectNone: { apply([], group) },
                    action: { trash(picked) }
                )
                Card("Copies") {
                    ForEach(files) { f in
                        CheckRow(
                            isOn: Binding(get: { shared.selection.contains(f.path) }, set: { shared.set(f.path, $0) }),
                            title: f.name,
                            subtitle: "\(Format.abbreviated((f.path as NSString).deletingLastPathComponent)) · modified \(Format.date(f.modified)) · created \(Format.date(f.created))",
                            value: Format.bytes(f.bytes),
                            badge: badge(f, files),
                            badgeTint: Theme.success,
                            onOpen: { nav.push(.space(.fileDetail(f.path))) },
                            onReveal: { EngineActions.reveal(f.path) }
                        )
                    }
                }
            } else {
                EmptyPanel(icon: "checkmark.seal", title: "Group resolved", message: "This group no longer has duplicates.")
            }
        }
    }

    private func badge(_ f: SpaceFile, _ files: [SpaceFile]) -> String? {
        let newest = files.max { ($0.modified ?? .distantPast) < ($1.modified ?? .distantPast) }
        return newest?.path == f.path ? "Newest" : nil
    }

    private func apply(_ set: Set<String>, _ group: DuplicateGroup) {
        for p in group.paths { shared.set(p, set.contains(p)) }
    }

    private func trash(_ files: [SpaceFile]) {
        busy = true
        Task {
            let summary = await store.trash(files, title: "Duplicate copies moved to Trash")
            failures = summary.failures
            for f in files where !summary.failures.contains(where: { $0.path == f.path }) { shared.set(f.path, false) }
            busy = false
        }
    }
}

// MARK: - Similar images

struct SpaceSimilarScreen: View {
    @ObservedObject private var store = SpaceStore.shared

    var body: some View {
        ScreenScaffold("Similar Images", subtitle: "Perceptual-hash clusters of near-identical photos") {
            SpaceRootPicker(roots: $store.similarRoots)
            Card {
                HStack(spacing: 14) {
                    Text("SIMILARITY").font(Type.label).tracking(1).foregroundStyle(Theme.muted)
                    Slider(value: $store.similarDistance, in: 0...20, step: 1).frame(maxWidth: 240)
                    Text("distance ≤ \(Int(store.similarDistance)) · \(strictness)").font(Type.mono(11, weight: .semibold))
                    Spacer()
                    Button("Find Similar") { Task { await store.scanSimilar() } }
                        .buttonStyle(EditorialButtonStyle(kind: .primary))
                        .disabled(store.similarState.isLoading || store.similarRoots.isEmpty)
                }
            }
            RefreshLine(state: store.similarState) { Task { await store.scanSimilar() } }
            if store.similarState.isLoading {
                LoadingPanel(text: "Fingerprinting images", detail: "Up to 8,000 images are hashed; this can take a minute.")
            }
            if store.similarState.loadedAt != nil {
                let photos = store.similar.reduce(0) { $0 + $1.paths.count }
                let extra = store.similar.reduce(Int64(0)) { acc, g in
                    let sizes = g.paths.map { store.similarInfo[$0]?.bytes ?? 0 }
                    return acc + sizes.reduce(0, +) - (sizes.max() ?? 0)
                }
                TileGrid {
                    StatTile(label: "Groups", value: Format.count(store.similar.count), icon: "photo.stack")
                    StatTile(label: "Images", value: Format.count(photos), icon: "photo")
                    StatTile(label: "Total size", value: Format.bytes(store.similar.reduce(0) { $0 + $1.bytes }), icon: "internaldrive")
                    StatTile(label: "Reclaimable", value: Format.bytes(extra), detail: "keeping largest of each", tint: Theme.accent, icon: "arrow.uturn.backward.circle")
                }
                if store.similar.isEmpty {
                    EmptyPanel(icon: "checkmark.seal", title: "No similar images", message: "Try raising the similarity distance.")
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                    ForEach(store.similar.prefix(300), id: \.paths) { group in
                        SpaceSimilarCard(group: group)
                    }
                }
            } else if store.similarState == .idle {
                EmptyPanel(icon: "photo.stack", title: "Find look-alike photos", message: "Bursts, edits and re-saves are grouped by a 64-bit difference hash.")
            }
        }
    }

    private var strictness: String {
        switch Int(store.similarDistance) {
        case 0...3: return "near-exact"
        case 4...9: return "similar"
        default: return "loose"
        }
    }
}

struct SpaceSimilarCard: View {
    let group: SimilarImageGroup
    @EnvironmentObject private var nav: Navigator

    var body: some View {
        Button { nav.push(.space(.similarGroup(group.paths[0]))) } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 4) {
                    ForEach(group.paths.prefix(3), id: \.self) { SpaceThumbnail(path: $0, size: 64) }
                }
                Text((group.paths[0] as NSString).lastPathComponent).font(Type.text(12, weight: .medium)).foregroundStyle(Theme.ink).lineLimit(1)
                Text("\(group.paths.count) images · \(Format.bytes(group.bytes))").font(Type.mono(10)).foregroundStyle(Theme.muted)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.canvas))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
        }
        .buttonStyle(.plain)
    }
}

struct SpaceSimilarGroupScreen: View {
    let key: String
    @ObservedObject private var store = SpaceStore.shared
    @EnvironmentObject private var nav: Navigator
    @State private var selection = Set<String>()
    @State private var busy = false
    @State private var failures: [(path: String, reason: String)] = []

    var body: some View {
        ScreenScaffold("Similar Group") {
            if let group = store.similarGroup(key) {
                let files = group.paths.map { store.similarInfo[$0] ?? SpaceFile(path: $0, bytes: 0) }
                let picked = files.filter { selection.contains($0.path) }
                let keep = files.max { $0.bytes < $1.bytes }
                TileGrid {
                    StatTile(label: "Images", value: Format.count(files.count), icon: "photo.stack")
                    StatTile(label: "Group size", value: Format.bytes(group.bytes), icon: "internaldrive")
                    StatTile(label: "Best copy", value: keep.map { Format.bytes($0.bytes) } ?? "—", detail: keep?.name, tint: Theme.success, icon: "star")
                    StatTile(label: "Selected", value: Format.bytes(picked.reduce(0) { $0 + $1.bytes }), detail: "\(picked.count) images", tint: Theme.accent, icon: "checkmark.square")
                }
                HStack(spacing: 10) {
                    Button("Keep largest, select others") { selection = Set(files.filter { $0.path != keep?.path && SpaceSafety.canRemove($0.path) }.map(\.path)) }
                        .buttonStyle(EditorialButtonStyle(kind: .secondary))
                    Button("Keep newest, select others") {
                        let newest = files.max { ($0.modified ?? .distantPast) < ($1.modified ?? .distantPast) }
                        selection = Set(files.filter { $0.path != newest?.path && SpaceSafety.canRemove($0.path) }.map(\.path))
                    }
                    .buttonStyle(EditorialButtonStyle(kind: .secondary))
                }
                FailureList(failures: failures)
                SelectionBar(
                    selectedCount: picked.count, totalCount: files.count,
                    selectedBytes: picked.reduce(0) { $0 + $1.bytes },
                    actionTitle: "Move to Trash",
                    confirmMessage: picked.count == files.count ? "Every image in this group is selected." : nil,
                    busy: busy,
                    onSelectAll: { selection = Set(files.map(\.path)) },
                    onSelectNone: { selection = [] },
                    action: { trash(picked) }
                )
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 12)], spacing: 12) {
                    ForEach(files) { f in
                        let on = selection.contains(f.path)
                        VStack(alignment: .leading, spacing: 6) {
                            ZStack(alignment: .topLeading) {
                                SpaceThumbnail(path: f.path, size: 176)
                                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 18)).foregroundStyle(on ? Theme.accent : .white)
                                    .shadow(radius: 2).padding(6)
                            }
                            .onTapGesture { if on { selection.remove(f.path) } else { selection.insert(f.path) } }
                            Text(f.name).font(Type.text(11, weight: .medium)).lineLimit(1).truncationMode(.middle)
                            Text("\(Format.bytes(f.bytes)) · \(Format.relative(f.modified))").font(Type.mono(10)).foregroundStyle(Theme.muted)
                            HStack(spacing: 8) {
                                Button("Details") { nav.push(.space(.fileDetail(f.path))) }.buttonStyle(EditorialButtonStyle(kind: .inline))
                                Button("Reveal") { EngineActions.reveal(f.path) }.buttonStyle(EditorialButtonStyle(kind: .inline))
                                if f.path == keep?.path { RiskBadge(text: "Largest", tint: Theme.success) }
                            }
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 10).fill(on ? Theme.accent.opacity(0.08) : Theme.canvas))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(on ? Theme.accent : Theme.line))
                    }
                }
            } else {
                EmptyPanel(icon: "checkmark.seal", title: "Group resolved", message: "Fewer than two images remain in this group.")
            }
        }
    }

    private func trash(_ files: [SpaceFile]) {
        busy = true
        Task {
            let summary = await store.trash(files, title: "Similar images moved to Trash")
            failures = summary.failures
            selection = Set(summary.failures.map(\.path))
            busy = false
        }
    }
}
