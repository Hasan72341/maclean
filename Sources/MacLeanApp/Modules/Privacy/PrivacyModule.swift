import MacLeanCore
import SwiftUI

enum PrivacyRoute: Hashable {
    case group(String)
    case artifact(String)
    case allItems
    case browsers
    case browser(String)
    case browserCategory(String, String)
    case recentItems
    case permissions
    case permissionService(String)
    case permissionClient(String)
    case savedState
    case savedStateDetail(String)
    case quarantineEvents
    case quarantineAgent(String)
    case shellHistory
    case shellHistoryFile(String)
    case clipboard
    case wifiNetworks
    case quickLookCache
    case result
    case commandOutput
}

enum PrivacyModule {
    @MainActor @ViewBuilder
    static func root() -> some View {
        PrivacyOverviewScreen()
    }

    @MainActor @ViewBuilder
    static func destination(_ route: PrivacyRoute) -> some View {
        switch route {
        case .group(let name): PrivacyArtifactListScreen(mode: .group(name))
        case .artifact(let path): PrivacyArtifactDetailScreen(path: path)
        case .allItems: PrivacyArtifactListScreen(mode: .all)
        case .browsers: PrivacyBrowsersScreen()
        case .browser(let name): PrivacyBrowserScreen(name: name)
        case .browserCategory(let browser, let category): PrivacyArtifactListScreen(mode: .browserCategory(browser, category))
        case .recentItems: PrivacyArtifactListScreen(mode: .group("Recent items"))
        case .permissions: PrivacyPermissionsScreen()
        case .permissionService(let service): PrivacyPermissionServiceScreen(service: service)
        case .permissionClient(let client): PrivacyPermissionClientScreen(client: client)
        case .savedState: PrivacySavedStateScreen()
        case .savedStateDetail(let path): PrivacySavedStateDetailScreen(path: path)
        case .quarantineEvents: PrivacyQuarantineScreen()
        case .quarantineAgent(let agent): PrivacyQuarantineAgentScreen(agent: agent)
        case .shellHistory: PrivacyShellHistoryScreen()
        case .shellHistoryFile(let path): PrivacyShellFileScreen(path: path)
        case .clipboard: PrivacyClipboardScreen()
        case .wifiNetworks: PrivacyWifiScreen()
        case .quickLookCache: PrivacyQuickLookScreen()
        case .result: PrivacyResultScreen()
        case .commandOutput: PrivacyCommandOutputScreen()
        }
    }

    static func title(_ route: PrivacyRoute) -> String {
        switch route {
        case .group(let name): return name
        case .artifact(let path): return (path as NSString).lastPathComponent
        case .allItems: return "All Privacy Items"
        case .browsers: return "Browsers"
        case .browser(let name): return name
        case .browserCategory(let browser, let category): return "\(browser) · \(category)"
        case .recentItems: return "Recent Items"
        case .permissions: return "App Permissions"
        case .permissionService(let service): return PrivacyTCC.names[service] ?? service.replacingOccurrences(of: "kTCCService", with: "")
        case .permissionClient(let client): return (client as NSString).lastPathComponent
        case .savedState: return "Saved App State"
        case .savedStateDetail(let path): return ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        case .quarantineEvents: return "Download History"
        case .quarantineAgent(let agent): return agent
        case .shellHistory: return "Shell History"
        case .shellHistoryFile(let path): return (path as NSString).lastPathComponent
        case .clipboard: return "Clipboard"
        case .wifiNetworks: return "Wi-Fi Networks"
        case .quickLookCache: return "Quick Look Cache"
        case .result: return "Clean Result"
        case .commandOutput: return "Command Output"
        }
    }
}
