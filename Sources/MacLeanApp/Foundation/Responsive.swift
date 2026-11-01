import AppKit
import SwiftUI

// MARK: - Interface size

/// The interface scale (Settings › General › Interface size, ⌘+ / ⌘− / ⌘0).
/// Every `Type` font is multiplied by it.
@MainActor
final class InterfaceScale: ObservableObject {
    static let shared = InterfaceScale()
    static let steps: [Double] = [0.85, 0.9, 1.0, 1.1, 1.2, 1.3]

    @Published var value: Double {
        didSet {
            UserDefaults.standard.set(value, forKey: "ui.scale")
            InterfaceScale.current = CGFloat(value)
        }
    }

    /// Read by `Type` (nonisolated for use in any view builder).
    nonisolated(unsafe) static var current: CGFloat = {
        let stored = UserDefaults.standard.double(forKey: "ui.scale")
        return stored > 0 ? CGFloat(stored) : 1
    }()

    private init() {
        let stored = UserDefaults.standard.double(forKey: "ui.scale")
        value = stored > 0 ? stored : 1
    }

    func bigger() { step(+1) }
    func smaller() { step(-1) }
    func reset() { value = 1 }

    private func step(_ direction: Int) {
        let index = Self.steps.firstIndex { abs($0 - value) < 0.01 } ?? Self.steps.firstIndex(of: 1)!
        let next = min(max(index + direction, 0), Self.steps.count - 1)
        value = Self.steps[next]
    }

    static func label(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }
}

// MARK: - Width classes

/// Width of the detail area, published by the shell so any screen can adapt.
private struct ContentWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1_000
}

private struct SidebarWidthKey: EnvironmentKey { static let defaultValue: CGFloat = 232 }
private struct WindowWidthKey: EnvironmentKey { static let defaultValue: CGFloat = 1_240 }

extension EnvironmentValues {
    var sidebarWidth: CGFloat {
        get { self[SidebarWidthKey.self] }
        set { self[SidebarWidthKey.self] = newValue }
    }

    var windowWidth: CGFloat {
        get { self[WindowWidthKey.self] }
        set { self[WindowWidthKey.self] = newValue }
    }

    var contentWidth: CGFloat {
        get { self[ContentWidthKey.self] }
        set { self[ContentWidthKey.self] = newValue }
    }

    /// Narrow detail area: stack side-by-side panels, tighten padding.
    var isCompactWidth: Bool { contentWidth < 760 }
}

/// HStack when there is room, VStack when the detail area is narrower than
/// `threshold` (both measured in points at the current interface size).
struct AdaptiveStack<Content: View>: View {
    var threshold: CGFloat = 820
    var spacing: CGFloat = 16
    @ViewBuilder var content: () -> Content
    @Environment(\.contentWidth) private var width

    var body: some View {
        let layout = width * 1 >= threshold * InterfaceScale.current
            ? AnyLayout(HStackLayout(alignment: .top, spacing: spacing))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: spacing))
        layout { content() }
    }
}

extension View {
    /// A width that prefers `ideal` but may shrink to 60% of it in narrow windows.
    func flexibleWidth(_ ideal: CGFloat) -> some View {
        frame(minWidth: ideal * 0.6, idealWidth: ideal, maxWidth: ideal)
    }
}

// MARK: - Sidebar

@MainActor
final class SidebarState: ObservableObject {
    static let shared = SidebarState()
    /// User preference: nil = automatic (collapse when the window is narrow).
    @Published var userCollapsed: Bool? {
        didSet {
            if let userCollapsed { UserDefaults.standard.set(userCollapsed, forKey: "ui.sidebarCollapsed") }
            else { UserDefaults.standard.removeObject(forKey: "ui.sidebarCollapsed") }
        }
    }

    private init() {
        userCollapsed = UserDefaults.standard.object(forKey: "ui.sidebarCollapsed") as? Bool
    }

    func collapsed(windowWidth: CGFloat) -> Bool {
        userCollapsed ?? (windowWidth < 980 * InterfaceScale.current)
    }

    func toggle(windowWidth: CGFloat) {
        let now = collapsed(windowWidth: windowWidth)
        userCollapsed = !now
    }
}

// MARK: - Window fitting

/// Makes sure the main window fits the screen it is on (small displays,
/// "Larger Text" scaling), and never starts larger than the visible area.
enum WindowFitter {
    @MainActor static func fit(_ window: NSWindow?) {
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        var frame = window.frame
        let maxWidth = visible.width - 24, maxHeight = visible.height - 24
        guard frame.width > maxWidth || frame.height > maxHeight || !visible.contains(frame) else { return }
        frame.size.width = min(frame.width, maxWidth)
        frame.size.height = min(frame.height, maxHeight)
        frame.origin.x = min(max(frame.origin.x, visible.minX + 12), visible.maxX - frame.width - 12)
        frame.origin.y = min(max(frame.origin.y, visible.minY + 12), visible.maxY - frame.height - 12)
        window.setFrame(frame, display: true, animate: false)
    }

    /// A first-launch size proportional to the screen (88% of it, capped).
    @MainActor static func preferredSize(for screen: NSScreen? = NSScreen.main) -> CGSize {
        guard let visible = screen?.visibleFrame else { return CGSize(width: 1240, height: 800) }
        return CGSize(width: min(1320, max(760, visible.width * 0.88)), height: min(880, max(520, visible.height * 0.88)))
    }
}

/// Captures the hosting NSWindow.
struct WindowAccessor: NSViewRepresentable {
    var onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { if let window = view.window { onWindow(window) } }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
