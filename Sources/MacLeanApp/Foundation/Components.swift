import MacLeanCore
import SwiftUI

// MARK: - Screen scaffold (header with back + breadcrumbs)

/// Standard screen frame. Shows a back button and breadcrumb trail whenever
/// the screen sits above its section root.
struct ScreenScaffold<Actions: View, Content: View>: View {
    let title: String
    var subtitle: String? = nil
    var scrolls: Bool = true
    var systemPane: SystemPane? = nil
    @ViewBuilder var actions: () -> Actions
    @ViewBuilder var content: () -> Content
    @EnvironmentObject private var nav: Navigator

    init(
        _ title: String,
        subtitle: String? = nil,
        scrolls: Bool = true,
        systemPane: SystemPane? = nil,
        @ViewBuilder actions: @escaping () -> Actions = { EmptyView() },
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.scrolls = scrolls
        self.systemPane = systemPane
        self.actions = actions
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Hairline()
            if scrolls {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) { content() }
                        .padding(.horizontal, 28)
                        .padding(.vertical, 22)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            } else {
                VStack(alignment: .leading, spacing: 16) { content() }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 18)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .background(Theme.paper)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if nav.canGoBack {
                    Button {
                        nav.pop()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left").font(.system(size: 11, weight: .bold))
                            Text("Back").font(Type.text(12, weight: .medium))
                        }
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.accent.opacity(0.1)))
                    }
                    .buttonStyle(.plain)
                    .help("Back (⌘[ or Esc)")
                    breadcrumbs
                } else {
                    Text(nav.section.title.uppercased())
                        .font(Type.label)
                        .tracking(1.1)
                        .foregroundStyle(Theme.faint)
                }
                Spacer()
                if let pane = systemPane ?? SystemPane.forRoute(nav.path.last, section: nav.section) {
                    SystemSettingsLink(pane: pane)
                }
            }
            HStack(alignment: .bottom, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(Type.display(28))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(Type.text(12))
                            .foregroundStyle(Theme.muted)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 12)
                HStack(spacing: 8) { actions() }
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 34)
        .padding(.bottom, 14)
    }

    private var breadcrumbs: some View {
        HStack(spacing: 4) {
            crumb(nav.section.title, index: -1)
            ForEach(Array(nav.path.dropLast().enumerated()), id: \.offset) { item in
                Image(systemName: "chevron.right").font(.system(size: 8)).foregroundStyle(Theme.faint)
                crumb(item.element.title, index: item.offset)
            }
        }
        .padding(.leading, 6)
    }

    private func crumb(_ text: String, index: Int) -> some View {
        Button {
            nav.pop(toIndex: index)
        } label: {
            Text(text)
                .font(Type.text(11))
                .foregroundStyle(Theme.muted)
                .lineLimit(1)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Containers

struct Card<Content: View>: View {
    var title: String? = nil
    var trailing: String? = nil
    var padding: CGFloat = 16
    @ViewBuilder var content: () -> Content

    init(_ title: String? = nil, trailing: String? = nil, padding: CGFloat = 16, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.trailing = trailing
        self.padding = padding
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if title != nil || trailing != nil {
                HStack {
                    if let title {
                        Text(title.uppercased())
                            .font(Type.label)
                            .tracking(1.1)
                            .foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    if let trailing {
                        Text(trailing)
                            .font(Type.mono(10))
                            .foregroundStyle(Theme.faint)
                    }
                }
            }
            content()
        }
        .padding(padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.canvas))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line, lineWidth: 1))
    }
}

struct SectionHeader: View {
    let title: String
    var detail: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title.uppercased())
                .font(Type.label)
                .tracking(1.2)
                .foregroundStyle(Theme.muted)
            Spacer()
            if let detail {
                Text(detail).font(Type.mono(10)).foregroundStyle(Theme.faint)
            }
        }
        .padding(.top, 4)
    }
}

/// Responsive grid of equal-width tiles.
struct TileGrid<Content: View>: View {
    var minWidth: CGFloat = 170
    @ViewBuilder var content: () -> Content

    init(minWidth: CGFloat = 170, @ViewBuilder content: @escaping () -> Content) {
        self.minWidth = minWidth
        self.content = content
    }

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: minWidth), spacing: 12)], alignment: .leading, spacing: 12) {
            content()
        }
    }
}

// MARK: - Numbers

struct StatTile: View {
    let label: String
    let value: String
    var unit: String? = nil
    var detail: String? = nil
    var tint: Color = Theme.ink
    var history: [Double]? = nil
    var icon: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let icon {
                    Image(systemName: icon).font(.system(size: 11)).foregroundStyle(tint == Theme.ink ? Theme.muted : tint)
                }
                Text(label.uppercased())
                    .font(Type.label)
                    .tracking(1)
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .foregroundStyle(tint)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .contentTransition(.numericText())
                if let unit {
                    Text(unit).font(Type.text(11)).foregroundStyle(Theme.muted)
                }
            }
            if let detail {
                Text(detail).font(Type.text(11)).foregroundStyle(Theme.faint).lineLimit(1)
            }
            if let history, history.count > 1 {
                Sparkline(values: history, tint: tint == Theme.ink ? Theme.accent : tint)
                    .frame(height: 24)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.canvas))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line, lineWidth: 1))
        .animation(.easeOut(duration: 0.3), value: value)
    }
}

struct KeyValueRow: View {
    let key: String
    let value: String
    var mono: Bool = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(key).font(Type.text(12)).foregroundStyle(Theme.muted)
            Spacer(minLength: 16)
            Text(value)
                .font(mono ? Type.mono(11) : Type.text(12, weight: .medium))
                .foregroundStyle(Theme.ink)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
                .monospacedDigit()
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Charts

/// Real-time area/line chart. Values are plotted left (old) to right (new)
/// inside a fixed `capacity` window so the graph scrolls as samples arrive.
struct LiveChart: View {
    struct Series {
        var values: [Double]
        var color: Color
        var label: String
        var fill: Bool = true
    }

    let series: [Series]
    var maxValue: Double? = nil
    var capacity: Int = SystemMonitor.historyLength
    var format: (Double) -> String = { String(format: "%.0f", $0) }
    var height: CGFloat = 140

    var body: some View {
        let peak = max(maxValue ?? (series.flatMap(\.values).max() ?? 1) * 1.15, 0.0001)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 14) {
                ForEach(Array(series.enumerated()), id: \.offset) { item in
                    HStack(spacing: 5) {
                        Circle().fill(item.element.color).frame(width: 7, height: 7)
                        Text(item.element.label).font(Type.text(11)).foregroundStyle(Theme.muted)
                        Text(format(item.element.values.last ?? 0))
                            .font(Type.mono(11, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                            .monospacedDigit()
                    }
                }
                Spacer()
                Text("max \(format(peak))").font(Type.mono(9)).foregroundStyle(Theme.faint)
            }
            Canvas { context, size in
                // Grid
                for step in 1...3 {
                    let y = size.height * CGFloat(step) / 4
                    var grid = Path()
                    grid.move(to: CGPoint(x: 0, y: y))
                    grid.addLine(to: CGPoint(x: size.width, y: y))
                    context.stroke(grid, with: .color(Theme.line.opacity(0.7)), style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                }
                let stepX = size.width / CGFloat(max(1, capacity - 1))
                for entry in series {
                    let values = Array(entry.values.suffix(capacity))
                    guard values.count > 1 else { continue }
                    let offset = CGFloat(capacity - values.count) * stepX
                    var line = Path()
                    for (index, value) in values.enumerated() {
                        let x = offset + CGFloat(index) * stepX
                        let y = size.height - CGFloat(min(1, max(0, value / peak))) * size.height
                        if index == 0 { line.move(to: CGPoint(x: x, y: y)) } else { line.addLine(to: CGPoint(x: x, y: y)) }
                    }
                    if entry.fill {
                        var area = line
                        area.addLine(to: CGPoint(x: size.width, y: size.height))
                        area.addLine(to: CGPoint(x: offset, y: size.height))
                        area.closeSubpath()
                        context.fill(area, with: .linearGradient(
                            Gradient(colors: [entry.color.opacity(0.35), entry.color.opacity(0.02)]),
                            startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)
                        ))
                    }
                    context.stroke(line, with: .color(entry.color), style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))
                }
            }
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.paper.opacity(0.6)))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}

struct Sparkline: View {
    let values: [Double]
    var tint: Color = Theme.accent
    var maxValue: Double? = nil

    var body: some View {
        Canvas { context, size in
            guard values.count > 1 else { return }
            let peak = max(maxValue ?? (values.max() ?? 1), 0.0001)
            let stepX = size.width / CGFloat(values.count - 1)
            var path = Path()
            for (index, value) in values.enumerated() {
                let point = CGPoint(x: CGFloat(index) * stepX, y: size.height - CGFloat(min(1, value / peak)) * size.height)
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            var area = path
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.addLine(to: CGPoint(x: 0, y: size.height))
            area.closeSubpath()
            context.fill(area, with: .color(tint.opacity(0.15)))
            context.stroke(path, with: .color(tint), lineWidth: 1.2)
        }
    }
}

struct RingGauge: View {
    let value: Double
    var label: String
    var caption: String? = nil
    var tint: Color = Theme.accent
    var size: CGFloat = 120
    var lineWidth: CGFloat = 10

    var body: some View {
        ZStack {
            Circle().stroke(Theme.line, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(1, max(0, value)))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 2) {
                Text(label)
                    .font(.system(size: size * 0.2, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.ink)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                if let caption {
                    Text(caption.uppercased()).font(Type.mono(9)).tracking(0.8).foregroundStyle(Theme.muted)
                }
            }
        }
        .frame(width: size, height: size)
        .animation(.easeOut(duration: 0.5), value: value)
    }
}

/// Horizontal bar for proportional values with label and number.
struct BarRow: View {
    let label: String
    let value: Double
    let total: Double
    var valueText: String
    var tint: Color = Theme.accent
    var action: (() -> Void)? = nil

    var body: some View {
        let content = VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(label).font(Type.text(12)).foregroundStyle(Theme.ink).lineLimit(1)
                Spacer()
                Text(valueText).font(Type.mono(11)).foregroundStyle(Theme.muted).monospacedDigit()
                if action != nil {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.faint)
                }
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.line.opacity(0.6))
                    Capsule().fill(tint).frame(width: max(2, proxy.size.width * CGFloat(total > 0 ? min(1, value / total) : 0)))
                }
            }
            .frame(height: 6)
        }
        .contentShape(Rectangle())
        if let action {
            Button(action: action) { content }.buttonStyle(.plain)
        } else {
            content
        }
    }
}

/// Single stacked bar with legend, e.g. memory composition.
struct StackedBar: View {
    struct Segment: Identifiable {
        var label: String
        var value: Double
        var color: Color
        var text: String
        var id: String { label }
    }

    let segments: [Segment]
    var total: Double? = nil

    var body: some View {
        let sum = max(total ?? segments.reduce(0) { $0 + $1.value }, 0.0001)
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { proxy in
                HStack(spacing: 1) {
                    ForEach(segments) { segment in
                        Rectangle().fill(segment.color)
                            .frame(width: max(0, proxy.size.width * CGFloat(segment.value / sum)))
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(height: 14)
            .background(Theme.line.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            FlowLegend(segments: segments)
        }
        .animation(.easeOut(duration: 0.4), value: segments.map(\.value))
    }

    private struct FlowLegend: View {
        let segments: [Segment]
        var body: some View {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)], alignment: .leading, spacing: 6) {
                ForEach(segments) { segment in
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2).fill(segment.color).frame(width: 9, height: 9)
                        Text(segment.label).font(Type.text(11)).foregroundStyle(Theme.muted)
                        Text(segment.text).font(Type.mono(11, weight: .semibold)).foregroundStyle(Theme.ink)
                    }
                }
            }
        }
    }
}

// MARK: - Rows

/// Tappable row that pushes a route (or runs an action).
struct NavRow: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    var value: String? = nil
    var tint: Color = Theme.accent
    var route: Route? = nil
    var action: (() -> Void)? = nil
    @EnvironmentObject private var nav: Navigator
    @State private var hovering = false

    var body: some View {
        Button {
            if let route { nav.push(route) } else { action?() }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(width: 32, height: 32)
                    .background(RoundedRectangle(cornerRadius: 8).fill(tint.opacity(0.12)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(Type.text(13, weight: .medium)).foregroundStyle(Theme.ink).lineLimit(1)
                    if let subtitle {
                        Text(subtitle).font(Type.text(11)).foregroundStyle(Theme.muted).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if let value {
                    Text(value).font(Type.mono(12, weight: .semibold)).foregroundStyle(Theme.ink).monospacedDigit()
                }
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.faint)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 9).fill(hovering ? Theme.line.opacity(0.45) : Theme.canvas))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.line, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Checkbox row for selectable engine items.
struct CheckRow: View {
    @Binding var isOn: Bool
    let title: String
    var subtitle: String? = nil
    var value: String? = nil
    var badge: String? = nil
    var badgeTint: Color = Theme.warning
    var onOpen: (() -> Void)? = nil
    var onReveal: (() -> Void)? = nil
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Button { isOn.toggle() } label: {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .font(.system(size: 15))
                    .foregroundStyle(isOn ? Theme.accent : Theme.faint)
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).font(Type.text(12, weight: .medium)).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.middle)
                    if let badge { RiskBadge(text: badge, tint: badgeTint) }
                }
                if let subtitle {
                    Text(subtitle).font(Type.mono(10)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            if let value {
                Text(value).font(Type.mono(11, weight: .semibold)).foregroundStyle(Theme.ink).monospacedDigit()
            }
            if let onReveal, hovering {
                Button(action: onReveal) { Image(systemName: "magnifyingglass") }
                    .buttonStyle(.plain).foregroundStyle(Theme.muted).help("Reveal in Finder")
            }
            if let onOpen {
                Button(action: onOpen) {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain).foregroundStyle(Theme.faint).help("Details")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 7).fill(hovering ? Theme.line.opacity(0.4) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { onOpen?() }
    }
}

struct RiskBadge: View {
    let text: String
    var tint: Color = Theme.warning

    var body: some View {
        Text(text.uppercased())
            .font(Type.mono(8, weight: .bold))
            .tracking(0.6)
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 3).fill(tint.opacity(0.13)))
    }
}

// MARK: - Selection toolbar + destructive confirm

/// Inline selection header. While anything is selected it also drives the
/// floating `SelectionDock` at the bottom of the window, so the action stays
/// in reach however far the list is scrolled.
struct SelectionBar: View {
    let selectedCount: Int
    let totalCount: Int
    let selectedBytes: Int64
    var actionTitle: String = "Remove Selected"
    var confirmMessage: String? = nil
    var busy: Bool = false
    var onSelectAll: () -> Void
    var onSelectNone: () -> Void
    var action: () -> Void
    @State private var confirming = false
    @State private var id = UUID()
    @ObservedObject private var dock = SelectionDock.shared

    private var entry: SelectionDock.Entry {
        SelectionDock.Entry(
            id: id,
            selected: selectedCount,
            total: totalCount,
            bytes: selectedBytes,
            title: actionTitle,
            message: confirmMessage ?? "Selected items are moved to the Trash unless stated otherwise. Each path is re-validated by the engine before removal.",
            busy: busy
        )
    }

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 1) {
                Text("\(Format.count(selectedCount)) of \(Format.count(totalCount)) selected")
                    .font(Type.text(12, weight: .medium)).foregroundStyle(Theme.ink)
                Text(Format.bytes(selectedBytes))
                    .font(Type.mono(11, weight: .semibold)).foregroundStyle(Theme.accent).monospacedDigit()
            }
            Button("All", action: onSelectAll).buttonStyle(EditorialButtonStyle(kind: .ghost))
            Button("None", action: onSelectNone).buttonStyle(EditorialButtonStyle(kind: .ghost)).disabled(selectedCount == 0)
            Spacer()
            if busy { ProgressView().controlSize(.small) }
            Button(actionTitle) { confirming = true }
                .buttonStyle(EditorialButtonStyle(kind: .primary))
                .disabled(selectedCount == 0 || busy)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.canvas).shadow(color: .black.opacity(0.08), radius: 8, y: -1))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
        .confirmationDialog(actionTitle + "?", isPresented: $confirming) {
            Button("\(actionTitle) (\(Format.count(selectedCount))\(selectedBytes > 0 ? ", " + Format.bytes(selectedBytes) : ""))", role: .destructive, action: action)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(entry.message)
        }
        .onAppear { dock.update(entry) }
        .onDisappear { dock.remove(id) }
        .onChange(of: entry) { dock.update($0) }
        .onChange(of: dock.command) { command in
            // Commands are handled here so the latest `action` closure (and
            // the latest selection it captures) is the one that runs.
            guard let command, command.target == id else { return }
            switch command.kind {
            case .run: if selectedCount > 0, !busy { action() }
            case .selectAll: onSelectAll()
            case .selectNone: onSelectNone()
            }
        }
    }
}

/// Floating action dock shared by every selectable list.
@MainActor
final class SelectionDock: ObservableObject {
    static let shared = SelectionDock()

    struct Entry: Equatable {
        let id: UUID
        var selected: Int
        var total: Int
        var bytes: Int64
        var title: String
        var message: String
        var busy: Bool
    }

    struct Command: Equatable {
        enum Kind: Equatable { case run, selectAll, selectNone }
        let target: UUID
        let kind: Kind
        let nonce = UUID()
    }

    @Published private(set) var entries: [UUID: Entry] = [:]
    @Published private(set) var focus: UUID?
    @Published private(set) var command: Command?

    /// The entry the dock shows: the most recently changed list with a selection.
    var active: Entry? {
        guard let focus, let entry = entries[focus], entry.selected > 0 || entry.busy else { return nil }
        return entry
    }

    func update(_ entry: Entry) {
        let old = entries[entry.id]
        guard old != entry else { return }
        entries[entry.id] = entry
        if entry.selected > 0 || entry.busy {
            if old == nil || old?.selected != entry.selected || focus == nil { focus = entry.id }
        } else if focus == entry.id {
            focus = entries.values.first { $0.selected > 0 }?.id
        }
    }

    func send(_ kind: Command.Kind) {
        guard let focus else { return }
        command = Command(target: focus, kind: kind)
    }

    func remove(_ id: UUID) {
        entries[id] = nil
        if focus == id { focus = entries.values.first { $0.selected > 0 }?.id }
    }
}

struct SelectionDockView: View {
    @ObservedObject private var dock = SelectionDock.shared
    @State private var confirming = false

    var body: some View {
        ZStack {
            if let entry = dock.active {
                HStack(spacing: 12) {
                    ZStack {
                        Circle().fill(Theme.accent)
                        Text(Format.count(entry.selected))
                            .font(Type.mono(entry.selected > 999 ? 9 : 11, weight: .bold))
                            .foregroundStyle(Color.white)
                            .minimumScaleFactor(0.6)
                    }
                    .frame(width: 30, height: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(Format.count(entry.selected)) of \(Format.count(entry.total)) selected")
                            .font(Type.text(12, weight: .semibold)).foregroundStyle(Theme.ink)
                        if entry.bytes > 0 {
                            Text(Format.bytes(entry.bytes)).font(Type.mono(11, weight: .semibold)).foregroundStyle(Theme.accent).monospacedDigit()
                        }
                    }
                    Rectangle().fill(Theme.line).frame(width: 1, height: 26)
                    Button("Select all \(Format.count(entry.total))") { dock.send(.selectAll) }
                        .buttonStyle(EditorialButtonStyle(kind: .ghost))
                        .disabled(entry.selected == entry.total || entry.busy)
                    Button("Clear") { dock.send(.selectNone) }
                        .buttonStyle(EditorialButtonStyle(kind: .ghost))
                        .disabled(entry.busy)
                    if entry.busy {
                        ProgressView().controlSize(.small)
                        Text("Working…").font(Type.text(11)).foregroundStyle(Theme.muted)
                    }
                    Button {
                        confirming = true
                    } label: {
                        Label(entry.title, systemImage: SelectionDockView.icon(for: entry.title))
                    }
                    .buttonStyle(EditorialButtonStyle(kind: .primary))
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(entry.busy || entry.selected == 0)
                    .help("\(entry.title) (⌘⌫)")
                }
                .padding(.leading, 10)
                .padding(.trailing, 12)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Theme.canvas)
                        .shadow(color: .black.opacity(0.28), radius: 18, y: 6)
                )
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.accent.opacity(0.55), lineWidth: 1))
                .confirmationDialog(entry.title + "?", isPresented: $confirming) {
                    Button("\(entry.title) (\(Format.count(entry.selected))\(entry.bytes > 0 ? ", " + Format.bytes(entry.bytes) : ""))", role: .destructive) {
                        dock.send(.run)
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text(entry.message)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: dock.active?.id)
        .animation(.easeOut(duration: 0.15), value: dock.active?.selected)
        .padding(.bottom, 14)
    }

    static func icon(for title: String) -> String {
        let t = title.lowercased()
        if t.contains("uninstall") { return "xmark.bin" }
        if t.contains("quit") { return "xmark.octagon" }
        if t.contains("quarantine") { return "shield.lefthalf.filled" }
        if t.contains("reset") { return "arrow.counterclockwise" }
        if t.contains("forget") || t.contains("history") { return "eye.slash" }
        if t.contains("thin") { return "scissors" }
        if t.contains("clean") { return "archivebox" }
        if t.contains("permanent") { return "trash.slash" }
        return "trash"
    }
}

/// Button that asks for confirmation before running a destructive action.
struct ConfirmButton: View {
    let title: String
    var message: String
    var kind: EditorialButtonStyle.Kind = .primary
    var disabled: Bool = false
    let action: () -> Void
    @State private var confirming = false

    var body: some View {
        Button(title) { confirming = true }
            .buttonStyle(EditorialButtonStyle(kind: kind))
            .disabled(disabled)
            .confirmationDialog(title + "?", isPresented: $confirming) {
                Button(title, role: .destructive, action: action)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(message)
            }
    }
}

// MARK: - States

struct SearchField: View {
    @Binding var text: String
    var prompt: String = "Filter"

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.faint)
            TextField(prompt, text: $text).textFieldStyle(.plain).font(Type.text(12))
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(Theme.faint)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: 260)
        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.canvas))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line))
    }
}

struct LoadingPanel: View {
    let text: String
    var detail: String? = nil

    var body: some View {
        HStack(spacing: 14) {
            ProgressView().controlSize(.regular)
            VStack(alignment: .leading, spacing: 3) {
                Text(text).font(Type.text(13, weight: .medium)).foregroundStyle(Theme.ink)
                if let detail { Text(detail).font(Type.text(11)).foregroundStyle(Theme.muted) }
            }
            Spacer()
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.canvas))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
    }
}

struct EmptyPanel: View {
    let icon: String
    let title: String
    var message: String? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 28, weight: .light)).foregroundStyle(Theme.faint)
            Text(title).font(Type.text(14, weight: .semibold)).foregroundStyle(Theme.ink)
            if let message {
                Text(message).font(Type.text(12)).foregroundStyle(Theme.muted).multilineTextAlignment(.center).frame(maxWidth: 420)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(EditorialButtonStyle(kind: .primary)).padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.canvas))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
    }
}

struct ErrorPanel: View {
    let message: String
    var retry: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.danger)
            Text(message).font(Type.text(12)).foregroundStyle(Theme.ink).textSelection(.enabled)
            Spacer()
            if let retry { Button("Retry", action: retry) }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.danger.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.danger.opacity(0.35)))
    }
}

/// Lists failures returned by a removal.
struct FailureList: View {
    let failures: [(path: String, reason: String)]

    var body: some View {
        if !failures.isEmpty {
            Card("Not removed", trailing: "\(failures.count)") {
                ForEach(Array(failures.prefix(50).enumerated()), id: \.offset) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Format.abbreviated(item.element.path)).font(Type.mono(10)).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.middle)
                        Text(item.element.reason).font(Type.text(11)).foregroundStyle(Theme.danger)
                    }
                }
            }
        }
    }
}

/// Header line with "scanned x ago" and a refresh button.
struct RefreshLine: View {
    let state: LoadState
    let action: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            switch state {
            case .loading(let text):
                ProgressView().controlSize(.small)
                Text(text).font(Type.text(11)).foregroundStyle(Theme.muted)
            case .loaded(let date):
                Image(systemName: "clock").font(.system(size: 10)).foregroundStyle(Theme.faint)
                Text("Updated \(Format.relative(date))").font(Type.text(11)).foregroundStyle(Theme.muted)
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.danger)
                Text(message).font(Type.text(11)).foregroundStyle(Theme.danger).lineLimit(1)
            case .idle:
                Text("Not scanned yet").font(Type.text(11)).foregroundStyle(Theme.muted)
            }
            Button(state.loadedAt == nil ? "Scan" : "Rescan", action: action)
                .disabled(state.isLoading)
        }
    }
}
