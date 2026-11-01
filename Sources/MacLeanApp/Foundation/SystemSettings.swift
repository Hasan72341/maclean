import AppKit
import SwiftUI

/// Deep links into System Settings. Pane identifiers are the bundle IDs of
/// the System Settings extensions shipped with macOS 13+ and the privacy
/// anchors exposed by the Privacy & Security extension.
enum SystemPane: Hashable {
    case privacy(Anchor)
    case privacySecurity
    case fileVault
    case loginItems
    case extensions
    case softwareUpdate
    case battery
    case network
    case wifi
    case bluetooth
    case storage
    case spotlight
    case timeMachine
    case startupDisk
    case usersGroups
    case sharing
    case notifications(bundleID: String?)
    case general
    case about
    case profiles
    case systemExtensions

    enum Anchor: String, CaseIterable {
        case fullDiskAccess = "Privacy_AllFiles"
        case accessibility = "Privacy_Accessibility"
        case inputMonitoring = "Privacy_ListenEvent"
        case screenRecording = "Privacy_ScreenCapture"
        case camera = "Privacy_Camera"
        case microphone = "Privacy_Microphone"
        case automation = "Privacy_Automation"
        case contacts = "Privacy_Contacts"
        case calendars = "Privacy_Calendars"
        case reminders = "Privacy_Reminders"
        case photos = "Privacy_Photos"
        case media = "Privacy_Media"
        case speech = "Privacy_SpeechRecognition"
        case filesAndFolders = "Privacy_FilesAndFolders"
        case developerTools = "Privacy_DevTools"
        case appManagement = "Privacy_AppBundles"
        case appData = "Privacy_AppContainer"
        case bluetooth = "Privacy_Bluetooth"
        case location = "Privacy_LocationServices"
        case motion = "Privacy_Motion"
        case focus = "Privacy_Focus"
        case homeKit = "Privacy_HomeKit"
        case remoteDesktop = "Privacy_RemoteDesktop"
        case pasteboard = "Privacy_Pasteboard"
        case audioCapture = "Privacy_AudioCapture"

        var title: String {
            switch self {
            case .fullDiskAccess: return "Full Disk Access"
            case .accessibility: return "Accessibility"
            case .inputMonitoring: return "Input Monitoring"
            case .screenRecording: return "Screen & System Audio Recording"
            case .camera: return "Camera"
            case .microphone: return "Microphone"
            case .automation: return "Automation"
            case .contacts: return "Contacts"
            case .calendars: return "Calendars"
            case .reminders: return "Reminders"
            case .photos: return "Photos"
            case .media: return "Media & Apple Music"
            case .speech: return "Speech Recognition"
            case .filesAndFolders: return "Files & Folders"
            case .developerTools: return "Developer Tools"
            case .appManagement: return "App Management"
            case .appData: return "App Data"
            case .bluetooth: return "Bluetooth"
            case .location: return "Location Services"
            case .motion: return "Motion & Fitness"
            case .focus: return "Focus"
            case .homeKit: return "Home"
            case .remoteDesktop: return "Remote Desktop"
            case .pasteboard: return "Paste from Other Apps"
            case .audioCapture: return "System Audio Recording"
            }
        }
    }

    /// Pane identifier used by System Settings on macOS 13 and later.
    private var modernID: String {
        switch self {
        case .privacy, .privacySecurity, .fileVault: return "com.apple.settings.PrivacySecurity.extension"
        case .loginItems, .extensions: return "com.apple.LoginItems-Settings.extension"
        case .softwareUpdate: return "com.apple.Software-Update-Settings.extension"
        case .battery: return "com.apple.Battery-Settings.extension"
        case .network: return "com.apple.Network-Settings.extension"
        case .wifi: return "com.apple.wifi-settings-extension"
        case .bluetooth: return "com.apple.BluetoothSettings"
        case .storage: return "com.apple.settings.Storage"
        case .spotlight: return "com.apple.Spotlight-Settings.extension"
        case .timeMachine: return "com.apple.Time-Machine-Settings.extension"
        case .startupDisk: return "com.apple.Startup-Disk-Settings.extension"
        case .usersGroups: return "com.apple.Users-Groups-Settings.extension"
        case .sharing: return "com.apple.Sharing-Settings.extension"
        case .notifications: return "com.apple.Notifications-Settings.extension"
        case .general: return "com.apple.systempreferences.GeneralSettings"
        case .about: return "com.apple.SystemProfiler.AboutExtension"
        case .profiles: return "com.apple.Profiles-Settings.extension"
        case .systemExtensions: return "com.apple.SystemExtensions-Settings.extension"
        }
    }

    /// Classic preference-pane identifier, still routed by System Settings
    /// when a pane was renamed or is missing on a given macOS version.
    private var legacyID: String? {
        switch self {
        case .privacy, .privacySecurity, .fileVault: return "com.apple.preference.security"
        case .loginItems: return "com.apple.preferences.users"
        case .extensions, .systemExtensions: return "com.apple.preferences.extensions"
        case .softwareUpdate: return "com.apple.preferences.softwareupdate"
        case .battery: return "com.apple.preference.battery"
        case .network, .wifi: return "com.apple.preference.network"
        case .bluetooth: return "com.apple.preferences.Bluetooth"
        case .spotlight: return "com.apple.preference.spotlight"
        case .timeMachine: return "com.apple.prefs.backup"
        case .startupDisk: return "com.apple.preference.startupdisk"
        case .usersGroups: return "com.apple.preferences.users"
        case .sharing: return "com.apple.preferences.sharing"
        case .notifications: return "com.apple.preference.notifications"
        case .general: return "com.apple.preference.general"
        case .profiles: return "com.apple.preferences.configurationprofiles"
        case .storage, .about: return nil
        }
    }

    private var anchor: String? {
        switch self {
        case .privacy(let anchor): return anchor.rawValue
        case .fileVault: return "FileVault"
        default: return nil
        }
    }

    /// The URL for this Mac: the pane ID is checked against the panes this
    /// macOS version actually ships, and an anchor is only appended when the
    /// Privacy & Security extension knows it. Unknown panes fall back to the
    /// classic ID, then to System Settings itself.
    var urlString: String {
        let base = "x-apple.systempreferences:"
        let catalog = SettingsCatalog.shared
        var pane: String
        if catalog.hasPane(modernID) {
            pane = modernID
        } else if let legacyID {
            pane = legacyID
        } else {
            return base
        }
        if let anchor, catalog.privacyAnchorKnown(anchor) || !catalog.canInspectPrivacy {
            pane += "?" + anchor
        }
        if case .notifications(let id) = self, let id, !id.isEmpty, pane == modernID {
            pane += "?id=" + id
        }
        return base + pane
    }

    /// Where the link lands, as the user sees it in System Settings.
    var path: String {
        switch self {
        case .privacy(let anchor): return "Privacy & Security › \(anchor.title)"
        case .privacySecurity: return "Privacy & Security"
        case .fileVault: return "Privacy & Security › FileVault"
        case .loginItems: return "General › Login Items & Extensions"
        case .extensions: return "General › Login Items & Extensions › Extensions"
        case .softwareUpdate: return "General › Software Update"
        case .battery: return "Battery"
        case .network: return "Network"
        case .wifi: return "Wi-Fi"
        case .bluetooth: return "Bluetooth"
        case .storage: return "General › Storage"
        case .spotlight: return "Spotlight"
        case .timeMachine: return "General › Time Machine"
        case .startupDisk: return "General › Startup Disk"
        case .usersGroups: return "Users & Groups"
        case .sharing: return "General › Sharing"
        case .notifications(let id): return id == nil ? "Notifications" : "Notifications › this app"
        case .general: return "General"
        case .about: return "General › About"
        case .profiles: return "General › Device Management"
        case .systemExtensions: return "General › Login Items & Extensions › System Extensions"
        }
    }

    var shortTitle: String {
        switch self {
        case .privacy(let anchor): return anchor.title
        default: return path.components(separatedBy: " › ").last ?? path
        }
    }

    var icon: String {
        switch self {
        case .privacy, .privacySecurity, .fileVault: return "hand.raised"
        case .battery: return "battery.75percent"
        case .network, .wifi: return "network"
        case .bluetooth: return "dot.radiowaves.left.and.right"
        case .storage, .startupDisk: return "internaldrive"
        case .spotlight: return "magnifyingglass"
        case .timeMachine: return "clock.arrow.circlepath"
        case .notifications: return "bell.badge"
        case .softwareUpdate: return "arrow.down.circle"
        default: return "gearshape"
        }
    }

    @MainActor
    func open() {
        guard let url = URL(string: urlString) else { return }
        if !NSWorkspace.shared.open(url), let fallback = URL(string: "x-apple.systempreferences:") {
            NSWorkspace.shared.open(fallback)
        }
    }

    /// Maps a TCC service (`kTCCServiceCamera` …) to its Privacy & Security pane.
    static func forService(_ service: String) -> SystemPane {
        let name = service.hasPrefix("kTCCService") ? String(service.dropFirst("kTCCService".count)) : service
        let anchor: Anchor? = {
            switch name {
            case "SystemPolicyAllFiles": return .fullDiskAccess
            case "Accessibility", "PostEvent": return .accessibility
            case "ListenEvent": return .inputMonitoring
            case "ScreenCapture": return .screenRecording
            case "AudioCapture": return .audioCapture
            case "Camera": return .camera
            case "Microphone": return .microphone
            case "AppleEvents": return .automation
            case "AddressBook": return .contacts
            case "Calendar": return .calendars
            case "Reminders": return .reminders
            case "Photos", "PhotosAdd": return .photos
            case "MediaLibrary": return .media
            case "SpeechRecognition": return .speech
            case "SystemPolicyDesktopFolder", "SystemPolicyDocumentsFolder", "SystemPolicyDownloadsFolder",
                 "SystemPolicyNetworkVolumes", "SystemPolicyRemovableVolumes", "FileProviderDomain":
                return .filesAndFolders
            case "SystemPolicyDeveloperFiles", "DeveloperTool": return .developerTools
            case "SystemPolicyAppBundles": return .appManagement
            case "SystemPolicyAppData": return .appData
            case "BluetoothAlways", "BluetoothPeripheral": return .bluetooth
            case "Motion": return .motion
            case "FocusStatus": return .focus
            case "Willow", "HomeKit": return .homeKit
            case "Pasteboard": return .pasteboard
            case "RemoteDesktop": return .remoteDesktop
            case "Location", "LocationServices": return .location
            default: return nil
            }
        }()
        return anchor.map { .privacy($0) } ?? .privacySecurity
    }

    /// The System Settings pane that belongs to a MacLean screen, if any.
    static func forRoute(_ route: Route?, section: AppSection) -> SystemPane? {
        guard let route else {
            switch section {
            case .privacy: return .privacySecurity
            case .space: return .storage
            case .protection: return .privacySecurity
            default: return nil
            }
        }
        switch route {
        case .monitor(let r):
            switch r {
            case .battery, .powerAssertions: return .battery
            case .networkOverview, .interfaceDetail: return .network
            case .diskOverview, .volumes, .volumeDetail: return .storage
            case .systemInfo: return .about
            default: return nil
            }
        case .apps(let r):
            switch r {
            case .loginItems: return .loginItems
            case .extensions, .extensionKind, .extensionDetail: return .extensions
            case .systemUpdates: return .softwareUpdate
            case .orphans, .orphanGroup, .orphanDetail: return .privacy(.fullDiskAccess)
            default: return nil
            }
        case .privacy(let r):
            switch r {
            case .permissions: return .privacySecurity
            case .permissionService(let service): return forService(service)
            case .wifiNetworks: return .wifi
            case .quarantineEvents, .quarantineAgent: return .privacySecurity
            default: return nil
            }
        case .performance(let r):
            switch r {
            case .startupItems, .userAgents, .globalAgents, .launchDaemons, .brokenItems, .runningItems, .loginItems, .startupItemDetail:
                return .loginItems
            case .energy, .sleepAssertions: return .battery
            case .rebuildSpotlight: return .spotlight
            case .snapshots, .thinSnapshots: return .timeMachine
            case .verifyDisk: return .storage
            default: return nil
            }
        case .space(let r):
            switch r {
            case .volumes, .diskActivity, .trash: return .storage
            case .mailAttachments, .mailAccount: return .privacy(.fullDiskAccess)
            default: return nil
            }
        case .protection(let r):
            switch r {
            case .mailTrash, .mailbox, .photosDuplicates, .photoGroup, .photoLibraries, .deletedUsers:
                return .privacy(.fullDiskAccess)
            case .realtime, .watchedPaths: return .loginItems
            default: return nil
            }
        case .settings(let r):
            switch r {
            case .fullDiskAccess: return .privacy(.fullDiskAccess)
            case .permissionsGuide: return .privacySecurity
            default: return nil
            }
        case .cleanup(let r):
            switch r {
            case .trash: return .storage
            default: return nil
            }
        }
    }
}

/// The System Settings panes and Privacy anchors present on this Mac, read
/// once from the Settings extensions shipped with the running macOS.
final class SettingsCatalog: @unchecked Sendable {
    static let shared = SettingsCatalog()

    private let panes: Set<String>
    private let privacyBinary: Data?

    private init() {
        let root = URL(fileURLWithPath: "/System/Library/ExtensionKit/Extensions")
        var found = Set<String>()
        var privacy: Data?
        let entries = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for appex in entries where appex.pathExtension == "appex" {
            let plistURL = appex.appendingPathComponent("Contents/Info.plist")
            guard let data = try? Data(contentsOf: plistURL),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) else { continue }
            var strings = Set<String>()
            Self.collect(plist, into: &strings)
            found.formUnion(strings)
            if strings.contains("com.apple.settings.PrivacySecurity.extension"),
               let dict = plist as? [String: Any],
               (dict["CFBundleIdentifier"] as? String)?.contains("PrivacySecurity") == true || appex.lastPathComponent.hasPrefix("SecurityPrivacy"),
               let exe = dict["CFBundleExecutable"] as? String {
                privacy = Self.bundleText(appex, executable: exe)
            }
        }
        panes = found
        privacyBinary = privacy
    }

    /// The extension's executable plus its resources (anchor lists such as
    /// TCCServiceList.plist and search terms live there, not in the binary).
    private static func bundleText(_ appex: URL, executable: String) -> Data {
        var data = Data()
        if let exe = try? Data(contentsOf: appex.appendingPathComponent("Contents/MacOS/\(executable)"), options: .mappedIfSafe) {
            data.append(exe)
        }
        let resources = appex.appendingPathComponent("Contents/Resources")
        let fm = FileManager.default
        if let walker = fm.enumerator(at: resources, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) {
            for case let url as URL in walker {
                // One localization is enough; anchors are not translated.
                if url.pathExtension == "lproj", !["en.lproj", "Base.lproj"].contains(url.lastPathComponent) {
                    walker.skipDescendants(); continue
                }
                guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                      values.isRegularFile == true, (values.fileSize ?? 0) < 4_000_000,
                      ["plist", "searchTerms", "strings", "json", "loctable"].contains(url.pathExtension),
                      let chunk = try? Data(contentsOf: url) else { continue }
                if url.pathExtension == "plist" || url.pathExtension == "searchTerms",
                   let parsed = try? PropertyListSerialization.propertyList(from: chunk, format: nil) {
                    var strings = Set<String>()
                    collectAll(parsed, into: &strings)
                    data.append(strings.joined(separator: "\n").data(using: .utf8) ?? Data())
                } else {
                    data.append(chunk)
                }
            }
        }
        return data
    }

    private static func collectAll(_ value: Any, into out: inout Set<String>) {
        if let string = value as? String { out.insert(string) }
        else if let dict = value as? [String: Any] { for (k, v) in dict { out.insert(k); collectAll(v, into: &out) } }
        else if let array = value as? [Any] { for v in array { collectAll(v, into: &out) } }
    }

    private static func collect(_ value: Any, into out: inout Set<String>) {
        if let string = value as? String, string.hasPrefix("com.apple.") {
            out.insert(string)
        } else if let dict = value as? [String: Any] {
            for (key, inner) in dict {
                if key.hasPrefix("com.apple.") { out.insert(key) }
                collect(inner, into: &out)
            }
        } else if let array = value as? [Any] {
            for inner in array { collect(inner, into: &out) }
        }
    }

    /// When the catalog cannot be read (sandboxing, unusual layout), every
    /// pane is assumed present so links still work.
    func hasPane(_ id: String) -> Bool { panes.isEmpty || panes.contains(id) }

    var canInspectPrivacy: Bool { privacyBinary != nil }

    func privacyAnchorKnown(_ anchor: String) -> Bool {
        guard let privacyBinary, let needle = anchor.data(using: .utf8) else { return true }
        return privacyBinary.range(of: needle) != nil
    }

    var summary: String { "\(panes.count) pane IDs, privacy anchors \(canInspectPrivacy ? "readable" : "assumed")" }
}

/// Small header link: "System Settings › Battery".
struct SystemSettingsLink: View {
    let pane: SystemPane
    var compact = true
    @State private var hovering = false

    var body: some View {
        Button { pane.open() } label: {
            HStack(spacing: 5) {
                Image(systemName: "gearshape").font(.system(size: 10, weight: .semibold))
                Text(compact ? "System Settings › \(pane.shortTitle)" : "Open System Settings › \(pane.path)")
                    .font(Type.text(11, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "arrow.up.forward").font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(hovering ? Theme.accent : Theme.muted)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.line.opacity(hovering ? 0.6 : 0.35)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Opens System Settings › \(pane.path)")
    }
}
