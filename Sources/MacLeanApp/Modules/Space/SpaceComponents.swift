import AppKit
import MacLeanCore
import SwiftUI

// MARK: - Selectable file list

enum SpaceSort: String, CaseIterable, Identifiable {
    case size = "Size", name = "Name", date = "Modified", path = "Location"
    var id: String { rawValue }
}

/// Searchable, sortable, selectable list of files with a confirmed removal.
struct SpaceFileList: View {
    let files: [SpaceFile]
    var title: String = "Files"
    var actionTitle: String = "Move to Trash"
    var activityTitle: String = "Moved files to Trash"
    var confirmMessage: String? = nil
    var preselect: ((SpaceFile) -> Bool)? = nil
    var badge: ((SpaceFile) -> (String, Color)?)? = nil
    var detail: ((SpaceFile) -> String)? = nil
    var showSizes: Bool = true
    var remove: (([SpaceFile]) async -> RemovalSummary)? = nil
    var secondaryTitle: String? = nil
    var secondaryMessage: String? = nil
    var secondary: (([SpaceFile]) async -> RemovalSummary)? = nil

    @ObservedObject private var store = SpaceStore.shared
    @EnvironmentObject private var nav: Navigator
    @State private var selection = Set<String>()
    @State private var search = ""
    @State private var sort: SpaceSort = .size
    @State private var initialized = false
    @State private var busy = false
    @State private var failures: [(path: String, reason: String)] = []
    @State private var limit = 400

    private var visible: [SpaceFile] {
        let q = search.lowercased()
        let filtered = q.isEmpty ? files : files.filter { $0.path.lowercased().contains(q) }
        switch sort {
        case .size: return filtered.sorted { $0.bytes > $1.bytes }
        case .name: return filtered.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .date: return filtered.sorted { ($0.modified ?? .distantPast) < ($1.modified ?? .distantPast) }
        case .path: return filtered.sorted { $0.path < $1.path }
        }
    }

    private var selectedFiles: [SpaceFile] { files.filter { selection.contains($0.path) } }

    var body: some View {
        let shown = visible
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                SectionHeader(title: title, detail: "\(Format.count(shown.count)) items · \(Format.bytes(shown.reduce(0) { $0 + $1.bytes }))")
                Spacer()
                Picker("Sort", selection: $sort) {
                    ForEach(SpaceSort.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .frame(width: 120)
                SearchField(text: $search, prompt: "Filter by name or path")
                    .frame(maxWidth: 240)
            }
            if !failures.isEmpty { FailureList(failures: failures) }
            if shown.isEmpty {
                EmptyPanel(icon: "checkmark.circle", title: search.isEmpty ? "Nothing here" : "No matches", message: search.isEmpty ? "No items match this view." : "Try a different filter.")
            } else {
                SelectionBar(
                    selectedCount: selection.count,
                    totalCount: files.count,
                    selectedBytes: selectedFiles.reduce(0) { $0 + $1.bytes },
                    actionTitle: actionTitle,
                    confirmMessage: confirmMessage,
                    busy: busy,
                    onSelectAll: { selection = Set(shown.filter { SpaceSafety.canRemove($0.path) }.map(\.path)) },
                    onSelectNone: { selection = [] },
                    action: { run(remove ?? { await store.trash($0, title: activityTitle) }) }
                )
                if let secondaryTitle, let secondary {
                    HStack {
                        Spacer()
                        ConfirmButton(
                            title: secondaryTitle,
                            message: secondaryMessage ?? "",
                            kind: .secondary,
                            disabled: selection.isEmpty || busy
                        ) { run(secondary) }
                    }
                }
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(shown.prefix(limit)) { file in
                        row(file)
                        Divider().opacity(0.4)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.canvas))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
                if shown.count > limit {
                    Button("Show \(min(400, shown.count - limit)) more (\(Format.count(shown.count - limit)) hidden)") { limit += 400 }
                        .buttonStyle(EditorialButtonStyle(kind: .inline))
                }
            }
        }
        .onAppear(perform: initialize)
        .onChange(of: files.count) { _ in
            selection = selection.intersection(Set(files.map(\.path)))
        }
    }

    private func initialize() {
        guard !initialized else { return }
        initialized = true
        if let preselect {
            selection = Set(files.filter { preselect($0) && SpaceSafety.canRemove($0.path) }.map(\.path))
        }
    }

    private func row(_ file: SpaceFile) -> some View {
        let refusal = SpaceSafety.refusal(file.path)
        let b = refusal != nil ? ("Protected", Theme.danger) : badge?(file)
        return CheckRow(
            isOn: Binding(
                get: { selection.contains(file.path) },
                set: { on in
                    guard refusal == nil else { return }
                    if on { selection.insert(file.path) } else { selection.remove(file.path) }
                }
            ),
            title: file.name,
            subtitle: detail?(file) ?? defaultDetail(file),
            value: showSizes ? Format.bytes(file.bytes) : nil,
            badge: b?.0,
            badgeTint: b?.1 ?? Theme.warning,
            onOpen: {
                nav.push(.space(file.isDirectory ? .lens(file.path) : .fileDetail(file.path)))
            },
            onReveal: { EngineActions.reveal(file.path) }
        )
    }

    private func defaultDetail(_ file: SpaceFile) -> String {
        var parts = [Format.abbreviated((file.path as NSString).deletingLastPathComponent)]
        if let m = file.modified { parts.append("modified \(Format.relative(m))") }
        if file.isDirectory, file.files > 1 { parts.append("\(Format.count(file.files)) files") }
        if !file.note.isEmpty { parts.append(file.note) }
        return parts.joined(separator: " · ")
    }

    private func run(_ action: @escaping ([SpaceFile]) async -> RemovalSummary) {
        let chosen = selectedFiles
        busy = true
        Task {
            let summary = await action(chosen)
            failures = summary.failures
            let failed = Set(summary.failures.map(\.path))
            selection = selection.filter { failed.contains($0) }
            busy = false
        }
    }
}

// MARK: - Progress

struct SpaceProgressPanel: View {
    let title: String
    let info: SpaceProgressInfo?
    var onStop: (() -> Void)? = nil

    var body: some View {
        Card {
            HStack(spacing: 14) {
                ProgressView().controlSize(.regular)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(Type.text(13, weight: .semibold)).foregroundStyle(Theme.ink)
                    if let info {
                        Text("\(Format.count(info.scanned)) items scanned · \(Format.count(info.matched)) found")
                            .font(Type.mono(11, weight: .semibold)).foregroundStyle(Theme.accent).monospacedDigit()
                        if !info.current.isEmpty {
                            Text(Format.abbreviated(info.current)).font(Type.mono(10)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
                        }
                    }
                }
                Spacer()
                if let onStop {
                    Button("Stop", action: onStop).buttonStyle(EditorialButtonStyle(kind: .secondary))
                }
            }
        }
    }
}

// MARK: - Folder chooser

struct SpaceRootPicker: View {
    @Binding var roots: [String]
    var multiple: Bool = true
    @ObservedObject private var store = SpaceStore.shared

    static let presets = ["Downloads", "Documents", "Pictures", "Desktop", "Movies", "Music"]

    var body: some View {
        Card("Folders to scan", trailing: "\(roots.count)") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    ForEach(Self.presets, id: \.self) { name in
                        let path = SpacePaths.url(name).path
                        let on = roots.contains(path)
                        Button {
                            if multiple {
                                if on { roots.removeAll { $0 == path } } else { roots.append(path) }
                            } else {
                                roots = [path]
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                Text(name)
                            }
                            .font(Type.text(11, weight: .medium))
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .background(Capsule().fill(on ? Theme.accent.opacity(0.15) : Theme.line.opacity(0.4)))
                            .foregroundStyle(on ? Theme.accent : Theme.ink)
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                    Button("Choose…") {
                        let picked = store.chooseFolders(multiple: multiple)
                        guard !picked.isEmpty else { return }
                        if multiple {
                            for p in picked where !roots.contains(p) { roots.append(p) }
                        } else {
                            roots = [picked[0]]
                        }
                    }
                    .buttonStyle(EditorialButtonStyle(kind: .secondary))
                }
                ForEach(roots.filter { !Self.presets.map { SpacePaths.url($0).path }.contains($0) }, id: \.self) { path in
                    HStack {
                        Image(systemName: "folder").foregroundStyle(Theme.muted)
                        Text(Format.abbreviated(path)).font(Type.mono(11)).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button { roots.removeAll { $0 == path } } label: { Image(systemName: "xmark.circle") }
                            .buttonStyle(.plain).foregroundStyle(Theme.muted)
                    }
                }
            }
        }
    }
}

// MARK: - Segmented option chips

struct SpaceChips<T: Hashable>: View {
    let label: String
    let options: [(T, String)]
    @Binding var value: T

    var body: some View {
        HStack(spacing: 6) {
            Text(label.uppercased()).font(Type.label).tracking(1).foregroundStyle(Theme.muted)
            ForEach(Array(options.enumerated()), id: \.offset) { item in
                let on = item.element.0 == value
                Button { value = item.element.0 } label: {
                    Text(item.element.1)
                        .font(Type.text(11, weight: .medium))
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(Capsule().fill(on ? Theme.ink : Theme.line.opacity(0.4)))
                        .foregroundStyle(on ? Theme.paper : Theme.ink)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Treemap

struct SpaceTreemapItem: Identifiable {
    var id: String
    var label: String
    var bytes: Int64
    var color: Color
    var action: (() -> Void)?
}

enum SpaceTreemapLayout {
    /// Binary-split treemap: halves the items by weight and splits along the longer side.
    static func layout(_ values: [Double], in rect: CGRect) -> [CGRect] {
        guard !values.isEmpty else { return [] }
        if values.count == 1 { return [rect] }
        let total = values.reduce(0, +)
        guard total > 0 else { return values.map { _ in .zero } }
        var acc = 0.0
        var split = 1
        for (i, v) in values.enumerated() {
            acc += v
            if acc >= total / 2 { split = max(1, min(values.count - 1, i + 1)); break }
        }
        let left = Array(values[..<split]), right = Array(values[split...])
        let fraction = left.reduce(0, +) / total
        let a: CGRect, b: CGRect
        if rect.width >= rect.height {
            let w = rect.width * fraction
            a = CGRect(x: rect.minX, y: rect.minY, width: w, height: rect.height)
            b = CGRect(x: rect.minX + w, y: rect.minY, width: rect.width - w, height: rect.height)
        } else {
            let h = rect.height * fraction
            a = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: h)
            b = CGRect(x: rect.minX, y: rect.minY + h, width: rect.width, height: rect.height - h)
        }
        return layout(left, in: a) + layout(right, in: b)
    }
}

struct SpaceTreemap: View {
    let items: [SpaceTreemapItem]
    var height: CGFloat = 260
    @State private var hovered: String?

    var body: some View {
        GeometryReader { proxy in
            let rects = SpaceTreemapLayout.layout(items.map { Double(max($0.bytes, 1)) }, in: CGRect(origin: .zero, size: proxy.size))
            ZStack(alignment: .topLeading) {
                ForEach(Array(zip(items, rects)), id: \.0.id) { item, rect in
                    block(item, rect)
                }
            }
        }
        .frame(height: height)
    }

    private func block(_ item: SpaceTreemapItem, _ rect: CGRect) -> some View {
        let inner = rect.insetBy(dx: 1.5, dy: 1.5)
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6)
                .fill(item.color.opacity(hovered == item.id ? 0.55 : 0.32))
            RoundedRectangle(cornerRadius: 6).stroke(item.color.opacity(0.6), lineWidth: 1)
            if inner.width > 60 && inner.height > 30 {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.label).font(Type.text(11, weight: .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                    Text(Format.bytes(item.bytes)).font(Type.mono(10)).foregroundStyle(Theme.muted)
                }
                .padding(6)
            }
        }
        .frame(width: max(0, inner.width), height: max(0, inner.height))
        .offset(x: inner.minX, y: inner.minY)
        .contentShape(Rectangle())
        .onHover { hovered = $0 ? item.id : (hovered == item.id ? nil : hovered) }
        .onTapGesture { item.action?() }
        .help("\(item.label) — \(Format.bytes(item.bytes))")
    }
}

enum SpacePalette {
    static let colors: [Color] = [Theme.accent, Theme.info, Theme.success, Theme.warning, Color(nsColor: .systemPurple), Theme.danger, Color(nsColor: .systemTeal), Color(nsColor: .systemPink)]
    static func color(_ index: Int) -> Color { colors[index % colors.count] }
}

// MARK: - Thumbnail

struct SpaceThumbnail: View {
    let path: String
    var size: CGFloat = 140
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(Theme.line.opacity(0.4))
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Image(systemName: "photo").foregroundStyle(Theme.faint)
            }
        }
        .frame(width: size, height: size)
        .task(id: path) {
            let p = path
            let px = Int(size * 2)
            if let data = await engine(priority: .utility, { SpaceThumb.make(p, maxPixels: px) }) {
                image = NSImage(data: data)
            }
        }
    }
}
