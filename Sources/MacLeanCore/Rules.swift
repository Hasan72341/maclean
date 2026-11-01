import Darwin
import Foundation

public enum Location: Sendable {
    case home(String)
    case absolute(String)
    case volumeTrashes
    case containerCaches
    case containerSubpath(String)
}

public enum RuleMode: Sendable {
    case contents
    case whole
    case largeFiles(olderThanDays: Int?)
}

public struct JunkRule: Sendable, Identifiable {
    public let id: String
    public let title: String
    public let category: JunkCategory
    public let location: Location
    public let mode: RuleMode
    public let excludes: [String]
    public let risk: Risk
    public let autoselect: Bool
    public let requiresRoot: Bool
    public let scanOnly: Bool
    public let origin: RuleOrigin

    public init(
        id: String,
        title: String,
        category: JunkCategory,
        location: Location,
        mode: RuleMode,
        excludes: [String] = [],
        risk: Risk = .safe,
        autoselect: Bool = true,
        requiresRoot: Bool = false,
        scanOnly: Bool = false,
        origin: RuleOrigin = .bundled
    ) {
        self.id = id
        self.title = title
        self.category = category
        self.location = location
        self.mode = mode
        self.excludes = excludes
        self.risk = risk
        self.autoselect = autoselect
        self.requiresRoot = requiresRoot
        self.scanOnly = scanOnly
        self.origin = origin
    }

    public func isExcluded(_ name: String) -> Bool {
        excludes.contains { pattern in
            if pattern.hasSuffix("*") {
                return name.hasPrefix(String(pattern.dropLast()))
            }
            return name == pattern
        }
    }

    public var targetsRootItself: Bool {
        if case .whole = mode { return true }
        return false
    }
}

public struct RuleRoots: Sendable {
    public let home: URL
    public let includeSystemPaths: Bool

    public init(home: URL, includeSystemPaths: Bool = true) {
        self.home = home
        self.includeSystemPaths = includeSystemPaths
    }

    public func roots(for rule: JunkRule, fileManager: FileManager = .default) -> [URL] {
        switch rule.location {
        case .home(let relative):
            return [home.appendingPathComponent(relative)]
        case .absolute(let path):
            guard includeSystemPaths else { return [] }
            return [URL(fileURLWithPath: (path as NSString).expandingTildeInPath)]
        case .volumeTrashes:
            guard includeSystemPaths else { return [] }
            guard let names = try? fileManager.contentsOfDirectory(atPath: "/Volumes") else { return [] }
            let uid = getuid()
            return names.sorted().compactMap { name in
                let volume = URL(fileURLWithPath: "/Volumes/\(name)")
                if let values = try? volume.resourceValues(forKeys: [.volumeIsLocalKey]),
                   values.volumeIsLocal == false {
                    return nil
                }
                return volume.appendingPathComponent(".Trashes/\(uid)")
            }
        case .containerCaches:
            return containerRoots(fileManager: fileManager).map {
                $0.appendingPathComponent("Data/Library/Caches")
            }
        case .containerSubpath(let relative):
            return containerRoots(fileManager: fileManager).map {
                $0.appendingPathComponent(relative)
            }
        }
    }

    private func containerRoots(fileManager: FileManager) -> [URL] {
        let base = home.appendingPathComponent("Library/Containers")
        guard let names = try? fileManager.contentsOfDirectory(atPath: base.path) else { return [] }
        return names.sorted().map { base.appendingPathComponent($0) }
    }
}

public enum Rules {
    static let browserCacheNames = [
        "Google",
        "Firefox",
        "BraveSoftware",
        "Microsoft Edge",
        "com.apple.Safari",
        "Company.TheBrowserCompany.Arc",
    ]

    static let developerCacheNames = [
        "org.swift.swiftpm",
        "com.apple.dt.Xcode",
        "Homebrew",
        "com.apple.dt.XCTest",
        "com.apple.SoftwareUpdate",
        "org.sparkle-project.Sparkle",
        "com.openai.chat",
    ]

    static let devRules: [JunkRule] = [
        JunkRule(
            id: "xcode-derived-data",
            title: "Xcode DerivedData",
            category: .dev,
            location: .home("Library/Developer/Xcode/DerivedData"),
            mode: .contents
        ),
        JunkRule(
            id: "xcode-archives",
            title: "Xcode Archives",
            category: .dev,
            location: .home("Library/Developer/Xcode/Archives"),
            mode: .contents,
            risk: .caution,
            autoselect: false
        ),
        JunkRule(
            id: "ios-device-support",
            title: "iOS DeviceSupport",
            category: .dev,
            location: .home("Library/Developer/Xcode/iOS DeviceSupport"),
            mode: .contents,
            risk: .caution,
            autoselect: false
        ),
        JunkRule(
            id: "watchos-device-support",
            title: "watchOS DeviceSupport",
            category: .dev,
            location: .home("Library/Developer/Xcode/watchOS DeviceSupport"),
            mode: .contents,
            risk: .caution,
            autoselect: false
        ),
        JunkRule(
            id: "tvos-device-support",
            title: "tvOS DeviceSupport",
            category: .dev,
            location: .home("Library/Developer/Xcode/tvOS DeviceSupport"),
            mode: .contents,
            risk: .caution,
            autoselect: false
        ),
        JunkRule(
            id: "visionos-device-support",
            title: "visionOS DeviceSupport",
            category: .dev,
            location: .home("Library/Developer/Xcode/visionOS DeviceSupport"),
            mode: .contents,
            risk: .caution,
            autoselect: false
        ),
        JunkRule(
            id: "simulator-caches",
            title: "CoreSimulator caches",
            category: .dev,
            location: .home("Library/Developer/CoreSimulator/Caches"),
            mode: .contents
        ),
        JunkRule(
            id: "swiftpm-cache",
            title: "Swift Package Manager cache",
            category: .dev,
            location: .home("Library/Caches/org.swift.swiftpm"),
            mode: .contents
        ),
        JunkRule(
            id: "xcode-caches",
            title: "Xcode caches",
            category: .dev,
            location: .home("Library/Caches/com.apple.dt.Xcode"),
            mode: .contents
        ),
        JunkRule(
            id: "homebrew-cache",
            title: "Homebrew downloads",
            category: .dev,
            location: .home("Library/Caches/Homebrew"),
            mode: .contents
        ),
        JunkRule(
            id: "npm-cache",
            title: "npm cache",
            category: .dev,
            location: .home(".npm/_cacache"),
            mode: .whole
        ),
        JunkRule(
            id: "gradle-cache",
            title: "Gradle cache",
            category: .dev,
            location: .home(".gradle/caches"),
            mode: .whole,
            risk: .caution,
            autoselect: false
        ),
        JunkRule(
            id: "cargo-cache",
            title: "Cargo registry cache",
            category: .dev,
            location: .home(".cargo/registry/cache"),
            mode: .whole
        ),
    ]

    static let browserRules: [JunkRule] = [
        JunkRule(
            id: "chrome-cache",
            title: "Google Chrome caches",
            category: .browser,
            location: .home("Library/Caches/Google/Chrome"),
            mode: .contents
        ),
        JunkRule(
            id: "firefox-cache",
            title: "Firefox caches",
            category: .browser,
            location: .home("Library/Caches/Firefox"),
            mode: .contents
        ),
        JunkRule(
            id: "safari-cache",
            title: "Safari caches",
            category: .browser,
            location: .home("Library/Caches/com.apple.Safari"),
            mode: .contents
        ),
        JunkRule(
            id: "edge-cache",
            title: "Microsoft Edge caches",
            category: .browser,
            location: .home("Library/Caches/Microsoft Edge"),
            mode: .contents
        ),
        JunkRule(
            id: "brave-cache",
            title: "Brave caches",
            category: .browser,
            location: .home("Library/Caches/BraveSoftware"),
            mode: .contents
        ),
        JunkRule(
            id: "arc-cache",
            title: "Arc caches",
            category: .browser,
            location: .home("Library/Caches/Company.TheBrowserCompany.Arc"),
            mode: .contents
        ),
    ]

    static let systemRules: [JunkRule] = [
        JunkRule(
            id: "user-caches",
            title: "User caches",
            category: .system,
            location: .home("Library/Caches"),
            mode: .contents,
            excludes: browserCacheNames + developerCacheNames
        ),
        JunkRule(
            id: "user-logs",
            title: "User logs and diagnostics",
            category: .system,
            location: .home("Library/Logs"),
            mode: .contents
        ),
        JunkRule(
            id: "saved-application-state",
            title: "Saved application state",
            category: .system,
            location: .home("Library/Saved Application State"),
            mode: .contents
        ),
        JunkRule(
            id: "crash-reporter",
            title: "Crash reporter data",
            category: .system,
            location: .home("Library/Application Support/CrashReporter"),
            mode: .contents
        ),
        JunkRule(
            id: "mail-downloads",
            title: "Mail downloads",
            category: .system,
            location: .home("Library/Containers/com.apple.mail/Data/Library/Mail Downloads"),
            mode: .contents
        ),
        JunkRule(
            id: "ios-backups",
            title: "iOS device backups",
            category: .system,
            location: .home("Library/Application Support/MobileSync/Backup"),
            mode: .contents,
            risk: .caution,
            autoselect: false
        ),
        JunkRule(
            id: "system-logs",
            title: "System logs",
            category: .system,
            location: .absolute("/Library/Logs"),
            mode: .contents,
            risk: .caution,
            autoselect: false,
            requiresRoot: true
        ),
        JunkRule(
            id: "system-caches",
            title: "System caches",
            category: .system,
            location: .absolute("/Library/Caches"),
            mode: .contents,
            risk: .caution,
            autoselect: false,
            requiresRoot: true
        ),
        JunkRule(
            id: "sandbox-container-caches",
            title: "Sandbox container caches",
            category: .system,
            location: .containerCaches,
            mode: .contents
        ),
        JunkRule(
            id: "sandbox-autosave",
            title: "Sandbox autosave information",
            category: .system,
            location: .containerSubpath("Data/Library/Autosave Information"),
            mode: .contents,
            risk: .caution,
            autoselect: false
        ),
        JunkRule(
            id: "simulator-runtimes",
            title: "Unused simulator runtimes",
            category: .dev,
            location: .home("Library/Developer/CoreSimulator/Profiles/Runtimes"),
            mode: .contents,
            risk: .caution,
            autoselect: false
        ),
        JunkRule(
            id: "xcode-previews",
            title: "Xcode preview caches",
            category: .dev,
            location: .home("Library/Developer/Xcode/UserData/Previews"),
            mode: .contents
        ),
    ]

    static let trashRules: [JunkRule] = [
        JunkRule(
            id: "user-trash",
            title: "User Trash",
            category: .trash,
            location: .home(".Trash"),
            mode: .contents
        ),
        JunkRule(
            id: "volume-trashes",
            title: "Mounted volume Trash bins",
            category: .trash,
            location: .volumeTrashes,
            mode: .contents
        ),
    ]

    static let largeRules: [JunkRule] = [
        JunkRule(
            id: "large-downloads",
            title: "Large files in Downloads",
            category: .large,
            location: .home("Downloads"),
            mode: .largeFiles(olderThanDays: nil),
            risk: .caution,
            autoselect: false,
            scanOnly: true
        ),
        JunkRule(
            id: "large-desktop",
            title: "Large files on Desktop",
            category: .large,
            location: .home("Desktop"),
            mode: .largeFiles(olderThanDays: nil),
            risk: .caution,
            autoselect: false,
            scanOnly: true
        ),
        JunkRule(
            id: "large-documents",
            title: "Large files in Documents",
            category: .large,
            location: .home("Documents"),
            mode: .largeFiles(olderThanDays: nil),
            risk: .caution,
            autoselect: false,
            scanOnly: true
        ),
        JunkRule(
            id: "large-movies",
            title: "Large files in Movies",
            category: .large,
            location: .home("Movies"),
            mode: .largeFiles(olderThanDays: nil),
            risk: .caution,
            autoselect: false,
            scanOnly: true
        ),
    ]

    static let aiRules: [JunkRule] = [
        JunkRule(
            id: "ollama-models",
            title: "Ollama local models",
            category: .ai,
            location: .home(".ollama/models"),
            mode: .whole,
            risk: .caution,
            autoselect: false
        ),
        JunkRule(
            id: "huggingface-cache",
            title: "Hugging Face model cache",
            category: .ai,
            location: .home(".cache/huggingface"),
            mode: .whole,
            risk: .caution,
            autoselect: false
        ),
        JunkRule(
            id: "torch-cache",
            title: "PyTorch model cache",
            category: .ai,
            location: .home(".cache/torch"),
            mode: .whole,
            risk: .caution,
            autoselect: false
        ),
        JunkRule(
            id: "whisper-cache",
            title: "Whisper model cache",
            category: .ai,
            location: .home(".cache/whisper"),
            mode: .whole,
            risk: .caution,
            autoselect: false
        ),
        JunkRule(
            id: "lmstudio-models",
            title: "LM Studio local models",
            category: .ai,
            location: .home(".lmstudio/models"),
            mode: .whole,
            risk: .caution,
            autoselect: false
        ),
        JunkRule(
            id: "cursor-cache",
            title: "Cursor cache",
            category: .ai,
            location: .home("Library/Application Support/Cursor/Cache"),
            mode: .contents
        ),
        JunkRule(
            id: "cursor-cached-data",
            title: "Cursor cached data",
            category: .ai,
            location: .home("Library/Application Support/Cursor/CachedData"),
            mode: .contents
        ),
        JunkRule(
            id: "claude-cache",
            title: "Claude desktop cache",
            category: .ai,
            location: .home("Library/Application Support/Claude/Cache"),
            mode: .contents
        ),
        JunkRule(
            id: "chatgpt-cache",
            title: "ChatGPT desktop cache",
            category: .ai,
            location: .home("Library/Caches/com.openai.chat"),
            mode: .contents
        ),
    ]

    static let updateRules: [JunkRule] = [
        JunkRule(
            id: "softwareupdate-cache",
            title: "macOS software update cache",
            category: .updates,
            location: .home("Library/Caches/com.apple.SoftwareUpdate"),
            mode: .contents
        ),
        JunkRule(
            id: "sparkle-cache",
            title: "Sparkle updater cache",
            category: .updates,
            location: .home("Library/Caches/org.sparkle-project.Sparkle"),
            mode: .contents
        ),
        JunkRule(
            id: "system-updates",
            title: "Downloaded system updates",
            category: .updates,
            location: .absolute("/Library/Updates"),
            mode: .contents,
            risk: .caution,
            autoselect: false,
            requiresRoot: true
        ),
    ]

    /// The rules shipped with the engine, before any user edits.
    public static let bundled: [JunkRule] = devRules + browserRules + systemRules
        + aiRules + updateRules + trashRules + largeRules

    /// Enabled rules with user edits applied, plus enabled custom rules.
    public static var all: [JunkRule] { RuleBook.shared.activeRules() }

    /// Every rule including disabled ones, with user edits applied.
    public static var resolved: [JunkRule] { RuleBook.shared.resolvedRules() }

    /// Resolves a rule (edited, custom or disabled) so items scanned earlier can
    /// still be validated against their roots.
    public static func rule(id: String) -> JunkRule? {
        resolved.first { $0.id == id }
    }
}
