import MacLeanCore
import SwiftUI

/// Shared inputs of every Lens chart.
struct LensChartInput {
    let item: LensItem
    let revision: Int
    let size: CGSize
}

// MARK: - Layout cache

/// Layouts are pure functions of (folder, tree revision, size); hovering
/// re-renders the view many times a second, so they are cached.
@MainActor
final class LensLayoutCache {
    static let shared = LensLayoutCache()
    private var storage: [String: Any] = [:]
    private var order: [String] = []

    func value<T>(_ key: String, build: () -> T) -> T {
        if let hit = storage[key] as? T { return hit }
        let made = build()
        storage[key] = made
        order.append(key)
        if order.count > 24 { storage[order.removeFirst()] = nil }
        return made
    }

    static func key(_ style: String, _ input: LensChartInput) -> String {
        "\(style)|\(input.item.path)|\(input.revision)|\(Int(input.size.width))x\(Int(input.size.height))"
    }
}

// MARK: - Sunburst

struct LensSunburst: View {
    let item: LensItem
    let revision: Int
    @Binding var hovered: LensItem?
    var onOpen: (LensItem) -> Void
    var onUp: (() -> Void)?

    static let rings = 4

    struct Arc {
        let item: LensItem
        let depth: Int
        let start: Double
        let end: Double
        let color: Color
    }

    struct Geometry {
        let center: CGPoint
        let inner: CGFloat
        let ring: CGFloat
        let arcs: [Arc]
    }

    static func layout(_ item: LensItem, size: CGSize) -> Geometry {
        let radius = min(size.width, size.height) / 2 - 4
        let inner = radius * 0.27
        let ring = (radius - inner) / CGFloat(rings)
        var arcs: [Arc] = []
        func add(_ parent: LensItem, depth: Int, start: Double, end: Double, inherited: Color?) {
            let total = Double(max(parent.bytes, 1))
            var angle = start
            for (index, child) in parent.children.enumerated() where child.bytes > 0 {
                let span = (end - start) * Double(child.bytes) / total
                defer { angle += span }
                if span < 0.006 { continue }
                let color = inherited ?? LensColors.child(child, index: index)
                arcs.append(Arc(item: child, depth: depth, start: angle, end: angle + span, color: child.isAggregate ? Theme.faint : color))
                if depth < rings, child.isDirectory, !child.children.isEmpty {
                    add(child, depth: depth + 1, start: angle, end: angle + span, inherited: color)
                }
            }
        }
        add(item, depth: 1, start: 0, end: 2 * .pi, inherited: nil)
        return Geometry(center: CGPoint(x: size.width / 2, y: size.height / 2), inner: inner, ring: ring, arcs: arcs)
    }

    static func hit(_ point: CGPoint, in geometry: Geometry) -> Arc? {
        let dx = point.x - geometry.center.x, dy = point.y - geometry.center.y
        let r = hypot(dx, dy)
        guard r >= geometry.inner else { return nil }
        let depth = Int((r - geometry.inner) / geometry.ring) + 1
        guard depth <= rings else { return nil }
        var angle = atan2(dy, dx) + .pi / 2
        if angle < 0 { angle += 2 * .pi }
        return geometry.arcs.first { $0.depth == depth && angle >= $0.start && angle < $0.end }
    }

    var body: some View {
        GeometryReader { proxy in
            let input = LensChartInput(item: item, revision: revision, size: proxy.size)
            let geometry = LensLayoutCache.shared.value(LensLayoutCache.key("sun", input)) { Self.layout(item, size: proxy.size) }
            ZStack {
                Canvas { ctx, _ in
                    let focus = hovered
                    for arc in geometry.arcs {
                        let r0 = geometry.inner + geometry.ring * CGFloat(arc.depth - 1) + 1
                        let r1 = r0 + geometry.ring - 1.5
                        var path = Path()
                        path.addArc(center: geometry.center, radius: r1, startAngle: .radians(arc.start - .pi / 2), endAngle: .radians(arc.end - .pi / 2), clockwise: false)
                        path.addArc(center: geometry.center, radius: r0, startAngle: .radians(arc.end - .pi / 2), endAngle: .radians(arc.start - .pi / 2), clockwise: true)
                        path.closeSubpath()
                        let related = focus.map { arc.item === $0 || arc.item.path.hasPrefix($0.path + "/") } ?? true
                        let base = 1.0 - 0.17 * Double(arc.depth - 1)
                        ctx.fill(path, with: .color(arc.color.opacity(base * (related ? 1 : 0.35))))
                        ctx.stroke(path, with: .color(Theme.canvas), lineWidth: 1)
                        if let focus, arc.item === focus {
                            ctx.stroke(path, with: .color(Theme.ink), lineWidth: 2)
                        }
                    }
                    for arc in geometry.arcs where arc.depth == 1 && arc.end - arc.start > 0.24 && !arc.item.isAggregate {
                        let mid = (arc.start + arc.end) / 2 - .pi / 2
                        let r = geometry.inner + geometry.ring * 0.5
                        let point = CGPoint(x: geometry.center.x + cos(mid) * r, y: geometry.center.y + sin(mid) * r)
                        let name = arc.item.name.count > 14 ? String(arc.item.name.prefix(13)) + "…" : arc.item.name
                        ctx.draw(Text(name).font(.system(size: 10, weight: .semibold)).foregroundColor(.white), at: point)
                    }
                }
                Circle()
                    .fill(Theme.canvas)
                    .overlay(Circle().stroke(hovered == nil && onUp != nil ? Theme.accent.opacity(0.5) : Theme.line, lineWidth: 1))
                    .frame(width: geometry.inner * 2 - 6, height: geometry.inner * 2 - 6)
                    .position(geometry.center)
                VStack(spacing: 2) {
                    let shown = hovered ?? item
                    Text(Format.bytes(shown.bytes)).font(Type.display(geometry.inner > 70 ? 22 : 16)).foregroundStyle(Theme.ink).monospacedDigit()
                    Text(shown.isAggregate ? shown.name : shown.name).font(Type.text(10, weight: .medium)).foregroundStyle(Theme.muted).lineLimit(2).multilineTextAlignment(.center)
                    if hovered == nil, onUp != nil {
                        Text("click to go up").font(Type.text(9)).foregroundStyle(Theme.faint)
                    } else if let hovered, item.bytes > 0 {
                        Text(Format.percent(Double(hovered.bytes) / Double(item.bytes), digits: 1)).font(Type.mono(10)).foregroundStyle(Theme.accent)
                    }
                }
                .frame(width: geometry.inner * 1.6)
                .position(geometry.center)
                .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    let found = Self.hit(point, in: geometry)?.item
                    if found !== hovered { hovered = found }
                case .ended:
                    hovered = nil
                }
            }
            .gesture(SpatialTapGesture().onEnded { value in
                let dx = value.location.x - geometry.center.x, dy = value.location.y - geometry.center.y
                if hypot(dx, dy) < geometry.inner {
                    onUp?()
                } else if let arc = Self.hit(value.location, in: geometry) {
                    onOpen(arc.item)
                }
            })
        }
    }
}

// MARK: - Bubbles

struct LensBubbles: View {
    let item: LensItem
    let revision: Int
    @Binding var hovered: LensItem?
    var onOpen: (LensItem) -> Void

    struct Bubble {
        let item: LensItem
        let center: CGPoint
        let radius: CGFloat
        let color: Color
        let inner: [(item: LensItem, center: CGPoint, radius: CGFloat)]
    }

    /// Greedy front packing: each circle goes to the free tangent spot
    /// closest to the centre.
    static func pack(_ radii: [Double]) -> [CGPoint] {
        var points: [CGPoint] = []
        func fits(_ c: CGPoint, _ r: Double, upTo count: Int) -> Bool {
            for j in 0..<count where hypot(c.x - points[j].x, c.y - points[j].y) < radii[j] + r - 0.01 { return false }
            return true
        }
        for (i, r) in radii.enumerated() {
            if i == 0 { points.append(.zero); continue }
            if i == 1 { points.append(CGPoint(x: radii[0] + r, y: 0)); continue }
            var best: CGPoint?
            var bestDistance = Double.infinity
            for a in 0..<i {
                for b in (a + 1)..<i {
                    let p1 = points[a], p2 = points[b]
                    let d1 = radii[a] + r, d2 = radii[b] + r
                    let dx = p2.x - p1.x, dy = p2.y - p1.y
                    let d = hypot(dx, dy)
                    guard d > 0, d <= d1 + d2, d >= abs(d1 - d2) else { continue }
                    let along = (d1 * d1 - d2 * d2 + d * d) / (2 * d)
                    let h = sqrt(max(0, d1 * d1 - along * along))
                    let mx = p1.x + along * dx / d, my = p1.y + along * dy / d
                    for sign in [-1.0, 1.0] {
                        let c = CGPoint(x: mx + sign * h * dy / d, y: my - sign * h * dx / d)
                        let distance = hypot(c.x, c.y)
                        if distance < bestDistance, fits(c, r, upTo: i) {
                            best = c
                            bestDistance = distance
                        }
                    }
                }
            }
            if best == nil {
                let reach = zip(points, radii).map { hypot($0.0.x, $0.0.y) + $0.1 }.max() ?? 0
                best = CGPoint(x: reach + r, y: 0)
            }
            points.append(best!)
        }
        return points
    }

    static func fit(_ radii: [Double], into radius: CGFloat, center: CGPoint) -> [(CGPoint, CGFloat)] {
        let points = pack(radii)
        // Recentre on the bounding circle, then scale into `radius`.
        let minX = zip(points, radii).map { $0.0.x - $0.1 }.min() ?? 0
        let maxX = zip(points, radii).map { $0.0.x + $0.1 }.max() ?? 0
        let minY = zip(points, radii).map { $0.0.y - $0.1 }.min() ?? 0
        let maxY = zip(points, radii).map { $0.0.y + $0.1 }.max() ?? 0
        let cx = (minX + maxX) / 2, cy = (minY + maxY) / 2
        let bound = zip(points, radii).map { hypot($0.0.x - cx, $0.0.y - cy) + $0.1 }.max() ?? 1
        let scale = radius / CGFloat(max(bound, 0.0001))
        return zip(points, radii).map { point, r in
            (CGPoint(x: center.x + (point.x - cx) * scale, y: center.y + (point.y - cy) * scale), CGFloat(r) * scale)
        }
    }

    static func layout(_ item: LensItem, size: CGSize) -> [Bubble] {
        let shown = Array(item.children.filter { $0.bytes > 0 }.prefix(40))
        guard !shown.isEmpty else { return [] }
        let radii = shown.map { sqrt(Double($0.bytes)) }
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let placed = fit(radii, into: min(size.width, size.height) / 2 - 6, center: center)
        return zip(shown.indices, placed).map { index, place in
            let child = shown[index]
            var inner: [(LensItem, CGPoint, CGFloat)] = []
            if child.isDirectory, place.1 > 46 {
                let kids = Array(child.children.filter { $0.bytes > 0 }.prefix(14))
                if !kids.isEmpty {
                    let fitted = fit(kids.map { sqrt(Double($0.bytes)) }, into: place.1 * 0.8, center: place.0)
                    inner = zip(kids, fitted).map { ($0, $1.0, $1.1) }
                }
            }
            return Bubble(item: child, center: place.0, radius: place.1, color: LensColors.child(child, index: index),
                          inner: inner.map { (item: $0.0, center: $0.1, radius: $0.2) })
        }
    }

    static func hit(_ point: CGPoint, in bubbles: [Bubble]) -> LensItem? {
        for bubble in bubbles where hypot(point.x - bubble.center.x, point.y - bubble.center.y) <= bubble.radius {
            for inner in bubble.inner where hypot(point.x - inner.center.x, point.y - inner.center.y) <= inner.radius {
                return inner.item
            }
            return bubble.item
        }
        return nil
    }

    var body: some View {
        GeometryReader { proxy in
            let input = LensChartInput(item: item, revision: revision, size: proxy.size)
            let bubbles = LensLayoutCache.shared.value(LensLayoutCache.key("bub", input)) { Self.layout(item, size: proxy.size) }
            Canvas { ctx, _ in
                let focus = hovered
                for bubble in bubbles {
                    let rect = CGRect(x: bubble.center.x - bubble.radius, y: bubble.center.y - bubble.radius, width: bubble.radius * 2, height: bubble.radius * 2)
                    let circle = Path(ellipseIn: rect)
                    let active = focus.map { bubble.item === $0 || $0.path.hasPrefix(bubble.item.path + "/") } ?? false
                    ctx.fill(circle, with: .radialGradient(
                        Gradient(colors: [bubble.color.opacity(active ? 0.55 : 0.32), bubble.color.opacity(active ? 0.3 : 0.14)]),
                        center: CGPoint(x: rect.midX - bubble.radius * 0.3, y: rect.midY - bubble.radius * 0.3),
                        startRadius: 0, endRadius: bubble.radius * 1.4))
                    ctx.stroke(circle, with: .color(bubble.color.opacity(active ? 1 : 0.7)), lineWidth: active ? 2.5 : 1.2)
                    for inner in bubble.inner {
                        let r = CGRect(x: inner.center.x - inner.radius, y: inner.center.y - inner.radius, width: inner.radius * 2, height: inner.radius * 2)
                        let isFocus = focus.map { inner.item === $0 } ?? false
                        ctx.fill(Path(ellipseIn: r), with: .color(bubble.color.opacity(isFocus ? 0.75 : 0.38)))
                        if isFocus { ctx.stroke(Path(ellipseIn: r), with: .color(Theme.ink), lineWidth: 1.5) }
                    }
                    guard bubble.radius > 26, !bubble.item.isAggregate || bubble.radius > 40 else { continue }
                    let labelY = bubble.inner.isEmpty ? bubble.center.y : bubble.center.y + bubble.radius * 0.62
                    let name = bubble.item.name.count > 18 ? String(bubble.item.name.prefix(17)) + "…" : bubble.item.name
                    let size = min(13, max(9, bubble.radius / 6))
                    ctx.draw(Text(name).font(.system(size: size, weight: .semibold)).foregroundColor(Theme.ink),
                             at: CGPoint(x: bubble.center.x, y: labelY - (bubble.radius > 40 ? size * 0.6 : 0)))
                    if bubble.radius > 40 {
                        ctx.draw(Text(Format.bytes(bubble.item.bytes)).font(.system(size: size - 1, design: .monospaced)).foregroundColor(Theme.muted),
                                 at: CGPoint(x: bubble.center.x, y: labelY + size * 0.75))
                    }
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    let found = Self.hit(point, in: bubbles)
                    if found !== hovered { hovered = found }
                case .ended: hovered = nil
                }
            }
            .gesture(SpatialTapGesture().onEnded { value in
                if let found = Self.hit(value.location, in: bubbles) { onOpen(found) }
            })
        }
    }
}

// MARK: - Treemap

struct LensTreemapChart: View {
    let item: LensItem
    let revision: Int
    @Binding var hovered: LensItem?
    var onOpen: (LensItem) -> Void

    struct Cell {
        let item: LensItem
        let rect: CGRect
        let color: Color
        let level: Int
    }

    /// Squarified treemap (Bruls, Huizing, van Wijk).
    static func squarify(_ values: [Double], in rect: CGRect) -> [CGRect] {
        let total = values.reduce(0, +)
        guard total > 0, rect.width > 1, rect.height > 1 else { return values.map { _ in .zero } }
        let areas = values.map { $0 / total * Double(rect.width * rect.height) }
        var rects = [CGRect](repeating: .zero, count: values.count)
        var remaining = rect
        var i = 0
        func worst(_ row: [Double], _ side: Double) -> Double {
            let s = row.reduce(0, +)
            guard s > 0, let mx = row.max(), let mn = row.min(), mn > 0 else { return .infinity }
            return max(side * side * mx / (s * s), (s * s) / (side * side * mn))
        }
        while i < areas.count {
            let side = Double(min(remaining.width, remaining.height))
            var row = [areas[i]]
            var j = i + 1
            while j < areas.count, worst(row + [areas[j]], side) <= worst(row, side) {
                row.append(areas[j])
                j += 1
            }
            let sum = row.reduce(0, +)
            if remaining.width >= remaining.height {
                let width = CGFloat(sum / Double(max(remaining.height, 1)))
                var y = remaining.minY
                for k in i..<j {
                    let h = CGFloat(areas[k] / Double(max(width, 0.0001)))
                    rects[k] = CGRect(x: remaining.minX, y: y, width: width, height: h)
                    y += h
                }
                remaining = CGRect(x: remaining.minX + width, y: remaining.minY, width: max(0, remaining.width - width), height: remaining.height)
            } else {
                let height = CGFloat(sum / Double(max(remaining.width, 1)))
                var x = remaining.minX
                for k in i..<j {
                    let w = CGFloat(areas[k] / Double(max(height, 0.0001)))
                    rects[k] = CGRect(x: x, y: remaining.minY, width: w, height: height)
                    x += w
                }
                remaining = CGRect(x: remaining.minX, y: remaining.minY + height, width: remaining.width, height: max(0, remaining.height - height))
            }
            i = j
        }
        return rects
    }

    static func layout(_ item: LensItem, size: CGSize) -> [Cell] {
        let shown = Array(item.children.filter { $0.bytes > 0 }.prefix(60))
        let rects = squarify(shown.map { Double($0.bytes) }, in: CGRect(origin: .zero, size: size))
        var cells: [Cell] = []
        for (index, child) in shown.enumerated() {
            let rect = rects[index]
            let color = LensColors.child(child, index: index)
            cells.append(Cell(item: child, rect: rect, color: color, level: 0))
            guard child.isDirectory, rect.width > 70, rect.height > 46 else { continue }
            let body = CGRect(x: rect.minX + 3, y: rect.minY + 18, width: rect.width - 6, height: rect.height - 21)
            let kids = Array(child.children.filter { $0.bytes > 0 }.prefix(40))
            let inner = squarify(kids.map { Double($0.bytes) }, in: body)
            for (k, kid) in kids.enumerated() where inner[k].width >= 3 && inner[k].height >= 3 {
                cells.append(Cell(item: kid, rect: inner[k], color: color, level: 1))
            }
        }
        return cells
    }

    static func hit(_ point: CGPoint, in cells: [Cell]) -> LensItem? {
        cells.last { $0.rect.contains(point) && $0.level == 1 }?.item ?? cells.first { $0.rect.contains(point) }?.item
    }

    var body: some View {
        GeometryReader { proxy in
            let input = LensChartInput(item: item, revision: revision, size: proxy.size)
            let cells = LensLayoutCache.shared.value(LensLayoutCache.key("tree", input)) { Self.layout(item, size: proxy.size) }
            Canvas { ctx, _ in
                let focus = hovered
                for cell in cells {
                    let rect = cell.rect.insetBy(dx: 1, dy: 1)
                    guard rect.width > 0, rect.height > 0 else { continue }
                    let shape = Path(roundedRect: rect, cornerRadius: cell.level == 0 ? 5 : 2)
                    let isFocus = focus.map { cell.item === $0 } ?? false
                    if cell.level == 0 {
                        ctx.fill(shape, with: .color(cell.color.opacity(cell.item.isDirectory && cell.rect.height > 46 ? 0.2 : 0.55)))
                        ctx.stroke(shape, with: .color(isFocus ? Theme.ink : cell.color.opacity(0.8)), lineWidth: isFocus ? 2 : 1)
                        if rect.width > 46, rect.height > 16 {
                            let name = cell.item.name
                            ctx.draw(Text("\(name)  \(Format.bytes(cell.item.bytes))").font(.system(size: 10, weight: .semibold)).foregroundColor(Theme.ink),
                                     in: CGRect(x: rect.minX + 5, y: rect.minY + 2, width: rect.width - 10, height: 14))
                        }
                    } else {
                        let shade = cell.item.isDirectory ? 0.7 : 0.48
                        ctx.fill(shape, with: .color(cell.color.opacity(isFocus ? 0.95 : shade)))
                        if isFocus { ctx.stroke(shape, with: .color(Theme.ink), lineWidth: 1.5) }
                        if rect.width > 54, rect.height > 16 {
                            ctx.draw(Text(cell.item.name).font(.system(size: 9, weight: .medium)).foregroundColor(.white),
                                     in: CGRect(x: rect.minX + 3, y: rect.minY + 2, width: rect.width - 6, height: 12))
                        }
                    }
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    let found = Self.hit(point, in: cells)
                    if found !== hovered { hovered = found }
                case .ended: hovered = nil
                }
            }
            .gesture(SpatialTapGesture().onEnded { value in
                if let found = Self.hit(value.location, in: cells) { onOpen(found) }
            })
        }
    }
}
