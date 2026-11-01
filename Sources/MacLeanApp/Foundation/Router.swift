import SwiftUI

/// Top-level sidebar sections. Each section owns its own back stack, so
/// switching sections and coming back restores where you were.
enum AppSection: String, CaseIterable, Identifiable, Hashable {
    case dashboard
    case cleanup
    case apps
    case privacy
    case performance
    case space
    case protection
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: return "Dashboard"
        case .cleanup: return "Cleanup"
        case .apps: return "Applications"
        case .privacy: return "Privacy"
        case .performance: return "Performance"
        case .space: return "Space & Files"
        case .protection: return "Protection"
        case .settings: return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .dashboard: return "gauge.with.dots.needle.67percent"
        case .cleanup: return "archivebox"
        case .apps: return "square.stack.3d.up"
        case .privacy: return "hand.raised"
        case .performance: return "speedometer"
        case .space: return "internaldrive"
        case .protection: return "shield.lefthalf.filled"
        case .settings: return "gearshape"
        }
    }

    var group: String {
        switch self {
        case .dashboard: return "Overview"
        case .cleanup, .apps, .privacy: return "Clean"
        case .performance, .space: return "Speed & Space"
        case .protection: return "Security"
        case .settings: return "App"
        }
    }
}

/// Every pushable screen in the app. Each module defines its own route enum in
/// `Modules/<Module>/` and the `<Module>Module` namespace that renders it.
enum Route: Hashable {
    case monitor(MonitorRoute)
    case cleanup(CleanupRoute)
    case apps(AppsRoute)
    case privacy(PrivacyRoute)
    case performance(PerformanceRoute)
    case space(SpaceRoute)
    case protection(ProtectionRoute)
    case settings(SettingsRoute)

    var title: String {
        switch self {
        case .monitor(let route): return MonitorModule.title(route)
        case .cleanup(let route): return CleanupModule.title(route)
        case .apps(let route): return AppsModule.title(route)
        case .privacy(let route): return PrivacyModule.title(route)
        case .performance(let route): return PerformanceModule.title(route)
        case .space(let route): return SpaceModule.title(route)
        case .protection(let route): return ProtectionModule.title(route)
        case .settings(let route): return SettingsModule.title(route)
        }
    }
}

@MainActor
final class Navigator: ObservableObject {
    static let shared = Navigator()

    @Published var section: AppSection = .dashboard
    @Published private(set) var stacks: [AppSection: [Route]] = [:]

    var path: [Route] { stacks[section] ?? [] }
    var canGoBack: Bool { !path.isEmpty }

    func push(_ route: Route) {
        stacks[section, default: []].append(route)
    }

    func pop() {
        guard var stack = stacks[section], !stack.isEmpty else { return }
        stack.removeLast()
        stacks[section] = stack
    }

    func popToRoot() {
        stacks[section] = []
    }

    /// Pops so that `index` (0-based position in `path`) is the top screen.
    /// `-1` means the section root.
    func pop(toIndex index: Int) {
        guard var stack = stacks[section] else { return }
        let keep = max(0, min(stack.count, index + 1))
        stack.removeLast(stack.count - keep)
        stacks[section] = stack
    }

    /// Jump to another section, optionally pushing one screen onto its root.
    func go(_ section: AppSection, _ route: Route? = nil) {
        self.section = section
        if let route {
            stacks[section] = [route]
        }
    }
}

/// Renders the root of the active section.
struct SectionRootView: View {
    let section: AppSection

    var body: some View {
        switch section {
        case .dashboard: MonitorModule.root()
        case .cleanup: CleanupModule.root()
        case .apps: AppsModule.root()
        case .privacy: PrivacyModule.root()
        case .performance: PerformanceModule.root()
        case .space: SpaceModule.root()
        case .protection: ProtectionModule.root()
        case .settings: SettingsModule.root()
        }
    }
}

/// Renders any pushed route.
struct RouteView: View {
    let route: Route

    var body: some View {
        switch route {
        case .monitor(let route): MonitorModule.destination(route)
        case .cleanup(let route): CleanupModule.destination(route)
        case .apps(let route): AppsModule.destination(route)
        case .privacy(let route): PrivacyModule.destination(route)
        case .performance(let route): PerformanceModule.destination(route)
        case .space(let route): SpaceModule.destination(route)
        case .protection(let route): ProtectionModule.destination(route)
        case .settings(let route): SettingsModule.destination(route)
        }
    }
}
