import MacLeanCore
import SwiftUI

enum AppsRoute: Hashable {
    case allApps
    case appDetail(String)
    case appAnatomy(String)
    case uninstallPlan(String)
    case uninstallResult(String)
    case appReset(String)
    case unusedApps
    case largeApps
    case recentApps
    case vendors
    case vendorDetail(String)
    case appStoreApps
    case otherApps
    case architectures
    case architectureGroup(String)
    case orphans
    case orphanGroup(String)
    case orphanDetail(String)
    case extensions
    case extensionKind(String)
    case extensionDetail(String)
    case runningApps
    case loginItems
    case systemUpdates
}

enum AppsModule {
    @MainActor @ViewBuilder
    static func root() -> some View {
        AppsOverviewScreen()
    }

    @MainActor @ViewBuilder
    static func destination(_ route: AppsRoute) -> some View {
        switch route {
        case .allApps: AppsListScreen(kind: .all)
        case .appDetail(let path): AppsDetailScreen(path: path)
        case .appAnatomy(let path): AppsAnatomyScreen(path: path)
        case .uninstallPlan(let path): AppsUninstallPlanScreen(path: path)
        case .uninstallResult(let path): AppsUninstallResultScreen(path: path)
        case .appReset(let path): AppsResetScreen(path: path)
        case .unusedApps: AppsUnusedScreen()
        case .largeApps: AppsListScreen(kind: .large)
        case .recentApps: AppsListScreen(kind: .recent)
        case .vendors: AppsVendorsScreen()
        case .vendorDetail(let vendor): AppsListScreen(kind: .vendor(vendor))
        case .appStoreApps: AppsListScreen(kind: .appStore)
        case .otherApps: AppsListScreen(kind: .other)
        case .architectures: AppsArchitecturesScreen()
        case .architectureGroup(let arch): AppsListScreen(kind: .architecture(arch))
        case .orphans: AppsOrphansScreen()
        case .orphanGroup(let id): AppsOrphanGroupScreen(appID: id)
        case .orphanDetail(let path): AppsOrphanDetailScreen(path: path)
        case .extensions: AppsExtensionsScreen(kind: nil)
        case .extensionKind(let kind): AppsExtensionsScreen(kind: kind)
        case .extensionDetail(let path): AppsExtensionDetailScreen(path: path)
        case .runningApps: AppsRunningScreen()
        case .loginItems: AppsLoginItemsScreen()
        case .systemUpdates: AppsUpdatesScreen()
        }
    }

    static func title(_ route: AppsRoute) -> String {
        switch route {
        case .allApps: return "All Applications"
        case .appDetail(let path): return AppsNames.appName(path)
        case .appAnatomy(let path): return "\(AppsNames.appName(path)) Bundle"
        case .uninstallPlan(let path): return "Uninstall \(AppsNames.appName(path))"
        case .uninstallResult: return "Uninstall Result"
        case .appReset(let path): return "Reset \(AppsNames.appName(path))"
        case .unusedApps: return "Unused Apps"
        case .largeApps: return "Large Apps"
        case .recentApps: return "Recently Installed"
        case .vendors: return "Vendors"
        case .vendorDetail(let vendor): return vendor
        case .appStoreApps: return "App Store Apps"
        case .otherApps: return "Other Sources"
        case .architectures: return "Architectures"
        case .architectureGroup(let arch): return arch
        case .orphans: return "Leftovers"
        case .orphanGroup(let id): return MainActor.assumeIsolated { AppsStore.shared.orphanGroup(id)?.displayName } ?? id
        case .orphanDetail(let path): return (path as NSString).lastPathComponent
        case .extensions: return "Extensions"
        case .extensionKind(let kind): return kind
        case .extensionDetail(let path): return ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        case .runningApps: return "Running Apps"
        case .loginItems: return "Launch Items"
        case .systemUpdates: return "System Updates"
        }
    }
}

enum AppsNames {
    static func appName(_ path: String) -> String {
        ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }
}
