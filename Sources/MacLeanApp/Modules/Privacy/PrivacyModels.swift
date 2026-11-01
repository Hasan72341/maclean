import AppKit
import Foundation
import MacLeanCore

// MARK: - Browser catalog

struct PrivacyBrowserInfo: Sendable, Hashable {
    let name: String
    let bundleID: String
    let processMarker: String
    let icon: String
}

enum PrivacyBrowsers {
    static let all: [PrivacyBrowserInfo] = [
        PrivacyBrowserInfo(name: "Safari", bundleID: "com.apple.Safari", processMarker: "/safari.app/contents/macos/safari", icon: "safari"),
        PrivacyBrowserInfo(name: "Google Chrome", bundleID: "com.google.Chrome", processMarker: "/google chrome.app/contents/macos/", icon: "globe"),
        PrivacyBrowserInfo(name: "Firefox", bundleID: "org.mozilla.firefox", processMarker: "/firefox.app/contents/macos/", icon: "flame"),
        PrivacyBrowserInfo(name: "Microsoft Edge", bundleID: "com.microsoft.edgemac", processMarker: "/microsoft edge.app/contents/macos/", icon: "globe.americas"),
        PrivacyBrowserInfo(name: "Brave", bundleID: "com.brave.Browser", processMarker: "/brave browser.app/contents/macos/", icon: "shield"),
        PrivacyBrowserInfo(name: "Chromium", bundleID: "org.chromium.Chromium", processMarker: "/chromium.app/contents/macos/", icon: "circle.hexagongrid"),
        PrivacyBrowserInfo(name: "Arc", bundleID: "company.thebrowser.Browser", processMarker: "/arc.app/", icon: "rainbow"),
    ]

    static func info(_ name: String) -> PrivacyBrowserInfo? {
        all.first { $0.name == name }
    }

    /// Browser that owns an artifact, derived from the scanner's detail string
    /// ("Google Chrome · Default", "Firefox · abc.default", "Safari").
    static func owner(of artifact: Artifact) -> String? {
        let head = artifact.detail.components(separatedBy: " · ").first ?? artifact.detail
        return all.contains { $0.name == head } ? head : nil
    }

    static func profile(of artifact: Artifact) -> String? {
        let parts = artifact.detail.components(separatedBy: " · ")
        return parts.count > 1 ? parts[1] : nil
    }

    /// Same check as `maclean privacy --apply`: scan process command paths.
    static func runningNames() -> Set<String> {
        let result = ProcessRunner.run("/bin/ps", ["-axo", "comm="], timeout: 10)
        let text = result.stdout.lowercased()
        return Set(all.filter { text.contains($0.processMarker) }.map(\.name))
    }
}

// MARK: - Artifact categories used by browser sub-lists

enum PrivacyCategory: String, CaseIterable, Sendable {
    case history = "History"
    case cookies = "Cookies"
    case cache = "Cache & website data"
    case sessions = "Sessions"
    case autofill = "Autofill & passwords"

    var groups: [String] {
        switch self {
        case .history: return ["Browsing history", "Downloads history"]
        case .cookies: return ["Cookies"]
        case .cache: return ["Website data"]
        case .sessions: return ["Session data"]
        case .autofill: return ["Autofill", "Saved passwords"]
        }
    }

    var icon: String {
        switch self {
        case .history: return "clock.arrow.circlepath"
        case .cookies: return "circle.grid.cross"
        case .cache: return "externaldrive.badge.icloud"
        case .sessions: return "rectangle.stack"
        case .autofill: return "key"
        }
    }

    static func of(_ group: String) -> PrivacyCategory? {
        allCases.first { $0.groups.contains(group) }
    }
}

enum PrivacyGroupStyle {
    static func icon(_ group: String) -> String {
        switch group {
        case "Browsing history": return "clock.arrow.circlepath"
        case "Cookies": return "circle.grid.cross"
        case "Autofill": return "character.cursor.ibeam"
        case "Saved passwords": return "key.fill"
        case "Session data": return "rectangle.stack"
        case "Downloads history": return "arrow.down.circle"
        case "Website data": return "externaldrive.badge.icloud"
        case "Recent items": return "doc.badge.clock"
        default: return "hand.raised"
        }
    }

    /// Groups excluded from "Clean all safe" because removing them loses data
    /// the user typically wants to keep.
    static let unsafeGroups: Set<String> = ["Saved passwords", "Autofill"]

    static func badge(_ artifact: Artifact) -> (String, Bool) {
        if unsafeGroups.contains(artifact.group) { return ("keeps logins", true) }
        switch artifact.risk {
        case .safe: return ("safe", false)
        case .caution: return ("caution", true)
        }
    }
}

// MARK: - Extra datasets

struct PrivacySavedState: Sendable, Hashable, Identifiable {
    var id: String { path }
    let path: String
    let bundleID: String
    let appName: String?
    let bytes: Int64
    let files: Int
    let modified: Date?
}

struct PrivacyQuarantineEvent: Sendable, Hashable, Identifiable {
    let id: String
    let date: Date?
    let agent: String
    let origin: String
    let dataURL: String
}

struct PrivacyQuarantineReport: Sendable {
    var database: String
    var exists: Bool
    var bytes: Int64
    var count: Int
    var agents: [(name: String, count: Int)]
    var hosts: [(name: String, count: Int)]
    var events: [PrivacyQuarantineEvent]
    var error: String?
}

struct PrivacyShellFile: Sendable, Hashable, Identifiable {
    var id: String { path }
    let name: String
    let path: String
    let shell: String
    let exists: Bool
    let bytes: Int64
    let lines: Int
    let modified: Date?
}

struct PrivacyShellInsight: Sendable {
    var topCommands: [(name: String, count: Int)]
    var first: Date?
    var last: Date?
    var timestamped: Int
    var uniqueCommands: Int
}

struct PrivacyWifiReport: Sendable {
    var device: String?
    var current: String?
    var networks: [String]
    var raw: String
    var error: String?
}

struct PrivacyQuickLookReport: Sendable {
    var path: String?
    var bytes: Int64
    var files: Int
    var modified: Date?
    var generators: Int
}

struct PrivacyPasteboardType: Sendable, Hashable, Identifiable {
    var id: String { type }
    let type: String
    let bytes: Int
}

struct PrivacyCommandOutput: Sendable {
    var title: String
    var command: String
    var status: Int32
    var output: String
    var date = Date()
}

struct PrivacyCleanResult: Sendable {
    var title: String
    var date: Date
    var removed: Int
    var bytes: Int64
    var failures: [PrivacyFailure]
    var detail: String
}

struct PrivacyFailure: Sendable, Hashable {
    let path: String
    let reason: String
}

// MARK: - TCC service names

enum PrivacyTCC {
    static let names: [String: String] = [
        "kTCCServiceCamera": "Camera",
        "kTCCServiceMicrophone": "Microphone",
        "kTCCServiceScreenCapture": "Screen Recording",
        "kTCCServiceAccessibility": "Accessibility",
        "kTCCServiceSystemPolicyAllFiles": "Full Disk Access",
        "kTCCServiceSystemPolicyDesktopFolder": "Desktop Folder",
        "kTCCServiceSystemPolicyDocumentsFolder": "Documents Folder",
        "kTCCServiceSystemPolicyDownloadsFolder": "Downloads Folder",
        "kTCCServiceSystemPolicyNetworkVolumes": "Network Volumes",
        "kTCCServiceSystemPolicyRemovableVolumes": "Removable Volumes",
        "kTCCServiceSystemPolicyAppBundles": "App Management",
        "kTCCServiceSystemPolicyAppData": "App Data",
        "kTCCServiceAddressBook": "Contacts",
        "kTCCServiceCalendar": "Calendars",
        "kTCCServiceReminders": "Reminders",
        "kTCCServicePhotos": "Photos",
        "kTCCServicePhotosAdd": "Photos (Add Only)",
        "kTCCServiceListenEvent": "Input Monitoring",
        "kTCCServicePostEvent": "Synthetic Input",
        "kTCCServiceAppleEvents": "Automation",
        "kTCCServiceBluetoothAlways": "Bluetooth",
        "kTCCServiceSpeechRecognition": "Speech Recognition",
        "kTCCServiceMediaLibrary": "Media & Apple Music",
        "kTCCServiceDeveloperTool": "Developer Tools",
        "kTCCServiceLocation": "Location",
        "kTCCServiceFocusStatus": "Focus Status",
        "kTCCServiceUbiquity": "iCloud",
        "kTCCServiceLiverpool": "Location (system)",
        "kTCCServiceFileProviderDomain": "File Provider",
        "kTCCServiceFileProviderPresence": "File Provider Presence",
        "kTCCServiceWebBrowserPublicKeyCredential": "Passkeys",
        "kTCCServiceSystemPolicySysAdminFiles": "Admin Files",
        "kTCCServiceEndpointSecurityClient": "Endpoint Security",
    ]

    static func name(_ service: String) -> String {
        if let known = names[service] { return known }
        let trimmed = service.hasPrefix("kTCCService") ? String(service.dropFirst("kTCCService".count)) : service
        return trimmed.isEmpty ? service : trimmed
    }

    static func icon(_ service: String) -> String {
        switch service {
        case "kTCCServiceCamera": return "camera"
        case "kTCCServiceMicrophone": return "mic"
        case "kTCCServiceScreenCapture": return "rectangle.dashed.badge.record"
        case "kTCCServiceAccessibility": return "accessibility"
        case "kTCCServiceSystemPolicyAllFiles": return "internaldrive"
        case "kTCCServiceAddressBook": return "person.crop.circle"
        case "kTCCServiceCalendar": return "calendar"
        case "kTCCServiceReminders": return "checklist"
        case "kTCCServicePhotos", "kTCCServicePhotosAdd": return "photo"
        case "kTCCServiceListenEvent", "kTCCServicePostEvent": return "keyboard"
        case "kTCCServiceAppleEvents": return "applescript"
        case "kTCCServiceBluetoothAlways": return "wave.3.right"
        case "kTCCServiceLocation", "kTCCServiceLiverpool": return "location"
        default:
            return service.contains("SystemPolicy") ? "folder" : "lock.shield"
        }
    }

    static func authText(_ value: Int) -> String {
        switch value {
        case 0: return "Denied"
        case 1: return "Unknown"
        case 2: return "Allowed"
        case 3: return "Limited"
        default: return "State \(value)"
        }
    }

    static func appName(_ client: String) -> String {
        if client.hasPrefix("/") {
            return (client as NSString).lastPathComponent
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: client) {
            return url.deletingPathExtension().lastPathComponent
        }
        return client
    }
}
