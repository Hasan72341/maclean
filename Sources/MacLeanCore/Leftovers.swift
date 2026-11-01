import Foundation
import Security

// MARK: - App identity

/// Everything that can name an app's files on disk.
public struct AppIdentity: Sendable, Equatable {
    /// Main bundle ID first, then IDs of embedded helpers, XPC services,
    /// login items, extensions and nested apps.
    public let bundleIDs: [String]
    /// Display name, bundle name and executable name (deduplicated).
    public let names: [String]
    public let executable: String?
    public let teamID: String?

    public init(bundleIDs: [String], names: [String], executable: String?, teamID: String?) {
        self.bundleIDs = bundleIDs
        self.names = names
        self.executable = executable
        self.teamID = teamID
    }

    public var mainID: String? { bundleIDs.first }

    public static func read(appPath: String, name: String, bundleID: String?, fileManager: FileManager = .default) -> AppIdentity {
        let appURL = URL(fileURLWithPath: appPath)
        let info = PlistReader.dictionary(at: appURL.appendingPathComponent("Contents/Info.plist")) ?? [:]
        let main = bundleID ?? PlistReader.string("CFBundleIdentifier", in: info)
        let executable = PlistReader.string("CFBundleExecutable", in: info)

        var ids: [String] = []
        func addID(_ id: String?) {
            guard let id, id.split(separator: ".").count >= 2,
                  !ids.contains(where: { $0.caseInsensitiveCompare(id) == .orderedSame }) else { return }
            ids.append(id)
        }
        addID(main)
        for nested in nestedBundleIDs(in: appURL, fileManager: fileManager) { addID(nested) }

        var names: [String] = []
        func addName(_ value: String?) {
            guard let value else { return }
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            guard trimmed.count >= 3, !genericNames.contains(trimmed.lowercased()),
                  !names.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else { return }
            names.append(trimmed)
        }
        addName(name)
        addName(PlistReader.string("CFBundleName", in: info))
        addName(PlistReader.string("CFBundleDisplayName", in: info))
        addName(executable)
        addName(name.replacingOccurrences(of: " ", with: ""))

        return AppIdentity(bundleIDs: ids, names: names, executable: executable, teamID: teamIdentifier(appPath))
    }

    /// Names too generic to match a folder by name alone.
    static let genericNames: Set<String> = [
        "app", "apps", "application", "helper", "updater", "update", "agent", "launcher", "setup",
        "installer", "uninstaller", "google", "microsoft", "adobe", "apple", "mozilla", "jetbrains",
        "default", "data", "cache", "caches", "logs", "temp", "tmp", "common", "shared", "electron",
    ]

    public static func nestedBundleIDs(in appURL: URL, fileManager: FileManager) -> [String] {
        let contents = appURL.appendingPathComponent("Contents")
        let folders = ["Library/LoginItems", "XPCServices", "PlugIns", "Helpers", "Library/LaunchServices",
                       "Library/SystemExtensions", "Extensions", "MacOS", "Frameworks"]
        var out: [String] = []
        for folder in folders {
            let dir = contents.appendingPathComponent(folder)
            guard let entries = try? fileManager.contentsOfDirectory(atPath: dir.path) else { continue }
            for entry in entries {
                let ext = (entry as NSString).pathExtension
                guard ["app", "xpc", "appex", "systemextension", "bundle"].contains(ext) || folder == "Frameworks" && ext == "app" else { continue }
                let plist = dir.appendingPathComponent(entry).appendingPathComponent("Contents/Info.plist")
                if let id = PlistReader.string("CFBundleIdentifier", in: PlistReader.dictionary(at: plist) ?? [:]) {
                    out.append(id)
                }
            }
        }
        // Electron-style helpers live inside Frameworks/*.framework/Helpers or Frameworks/*.app.
        if let frameworks = try? fileManager.contentsOfDirectory(atPath: contents.appendingPathComponent("Frameworks").path) {
            for entry in frameworks where entry.hasSuffix(".app") {
                let plist = contents.appendingPathComponent("Frameworks/\(entry)/Contents/Info.plist")
                if let id = PlistReader.string("CFBundleIdentifier", in: PlistReader.dictionary(at: plist) ?? [:]) { out.append(id) }
            }
        }
        return out
    }

    /// Team identifier from the code signature, if the app is signed by a developer.
    public static func teamIdentifier(_ path: String) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any],
              let team = dict[kSecCodeInfoTeamIdentifier as String] as? String,
              team.count == 10 else { return nil }
        return team
    }
}

// MARK: - Locations

/// One place in ~/Library where apps leave files, and how entries there are named.
public struct LeftoverLocation: Sendable {
    public enum Naming: Sendable {
        /// Entry is `<bundleID>` plus an optional suffix (`.plist`, `.savedState`, `.<host-uuid>.plist`).
        case bundleID
        /// Like `.bundleID`, and also `group.<id>` or `<TEAMID>.<id>`.
        case groupContainer
        /// Entry is named after the app or its executable.
        case name
        /// Crash and hang reports: `<Executable>_<date>…` or `<Executable>-<date>…`.
        case crashReport
        /// A bundle whose Info.plist CFBundleIdentifier belongs to the app.
        case bundleInside
        /// A launchd plist; only a leftover when its program no longer exists.
        case launchItem
        /// A privileged helper tool; only a leftover when no launch daemon uses it.
        case helperTool
    }

    public let title: String
    public let relative: String
    public let naming: [Naming]
    /// Whether matches here are pre-selected when uninstalling.
    public let autoselect: Bool

    public init(_ title: String, _ relative: String, _ naming: [Naming], autoselect: Bool = true) {
        self.title = title
        self.relative = relative
        self.naming = naming
        self.autoselect = autoselect
    }
}

/// A group of leftovers that belongs to one app that is no longer installed.
public struct LeftoverGroup: Sendable, Identifiable, Hashable {
    public enum Confidence: Int, Sendable, Comparable, Hashable {
        case low = 0, medium = 1, high = 2
        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
        public var title: String {
            switch self {
            case .high: return "High"
            case .medium: return "Medium"
            case .low: return "Low"
            }
        }
    }

    public let appID: String
    public let displayName: String
    public let items: [Artifact]
    public let confidence: Confidence
    public let reasons: [String]
    public let vendorInstalled: Bool
    public let trashedApp: String?

    public init(appID: String, displayName: String, items: [Artifact], confidence: Confidence, reasons: [String], vendorInstalled: Bool, trashedApp: String?) {
        self.appID = appID
        self.displayName = displayName
        self.items = items
        self.confidence = confidence
        self.reasons = reasons
        self.vendorInstalled = vendorInstalled
        self.trashedApp = trashedApp
    }

    public var id: String { appID }
    public var bytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
    public var files: Int { items.reduce(0) { $0 + $1.files } }
    public var newest: Date? { items.compactMap(\.modified).max() }
    public var locations: [String] { Array(Set(items.map(\.group))).sorted() }
}

public enum Leftovers {
    /// Per-user places apps write to. Mail, Messages, Keychains, Photos,
    /// iCloud Drive and cookies of Safari are deliberately absent.
    public static let userLocations: [LeftoverLocation] = [
        .init("Application Support", "Library/Application Support", [.bundleID, .name]),
        .init("Caches", "Library/Caches", [.bundleID, .name]),
        .init("Preferences", "Library/Preferences", [.bundleID]),
        .init("Preferences (ByHost)", "Library/Preferences/ByHost", [.bundleID]),
        .init("Saved state", "Library/Saved Application State", [.bundleID]),
        .init("Sandbox container", "Library/Containers", [.bundleID]),
        .init("Group container", "Library/Group Containers", [.groupContainer], autoselect: false),
        .init("Application scripts", "Library/Application Scripts", [.groupContainer]),
        .init("HTTP storage", "Library/HTTPStorages", [.bundleID]),
        .init("WebKit data", "Library/WebKit", [.bundleID]),
        .init("Cookies", "Library/Cookies", [.bundleID]),
        .init("Logs", "Library/Logs", [.bundleID, .name]),
        .init("Crash reports", "Library/Logs/DiagnosticReports", [.crashReport]),
        .init("Crash reporter", "Library/Application Support/CrashReporter", [.crashReport]),
        .init("Recent documents list", "Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments", [.bundleID]),
        .init("Internet plug-in", "Library/Internet Plug-Ins", [.bundleInside]),
        .init("Preference pane", "Library/PreferencePanes", [.bundleInside]),
        .init("Quick Look plug-in", "Library/QuickLook", [.bundleInside]),
        .init("Spotlight importer", "Library/Spotlight", [.bundleInside]),
        .init("Service", "Library/Services", [.bundleInside]),
        .init("Screen saver", "Library/Screen Savers", [.bundleInside]),
        .init("Autosave", "Library/Autosave Information", [.bundleID], autoselect: false),
        .init("Cached updates (Sparkle)", "Library/Caches/org.sparkle-project.Sparkle", [.bundleID]),
    ]

    /// System-wide and launchd locations checked for removed apps. Items here
    /// are root-owned more often than not; removal then needs administrator rights.
    public static let systemLocations: [LeftoverLocation] = [
        .init("System Application Support", "/Library/Application Support", [.bundleID], autoselect: false),
        .init("System Caches", "/Library/Caches", [.bundleID], autoselect: false),
        .init("System Preferences", "/Library/Preferences", [.bundleID], autoselect: false),
        .init("System Logs", "/Library/Logs", [.bundleID], autoselect: false),
        .init("Launch agent", "Library/LaunchAgents", [.launchItem]),
        .init("Launch agent (all users)", "/Library/LaunchAgents", [.launchItem], autoselect: false),
        .init("Launch daemon", "/Library/LaunchDaemons", [.launchItem], autoselect: false),
        .init("Privileged helper", "/Library/PrivilegedHelperTools", [.helperTool], autoselect: false),
    ]

    static func directory(_ location: LeftoverLocation, home: URL) -> URL {
        location.relative.hasPrefix("/") ? URL(fileURLWithPath: location.relative) : home.appendingPathComponent(location.relative)
    }

    /// Programs a launchd plist would run.
    static func launchPrograms(_ plist: [String: Any]) -> [String] {
        var out: [String] = []
        if let program = plist["Program"] as? String { out.append(program) }
        if let args = plist["ProgramArguments"] as? [String], let first = args.first { out.append(first) }
        return out.filter { $0.hasPrefix("/") }
    }

    static let suffixes = [".plist", ".savedState", ".binarycookies", ".sfl4", ".sfl3", ".sfl2", ".sfl", ".lockfile", ".log"]

    static func stem(_ name: String) -> String {
        var value = name
        for suffix in suffixes where value.hasSuffix(suffix) {
            value = String(value.dropLast(suffix.count))
            break
        }
        return value
    }

    static func isTeamPrefix(_ value: Substring) -> Bool {
        value.count == 10 && value.allSatisfy { $0.isUppercase || $0.isNumber }
    }

    /// Strips `group.` and `<TEAMID>.` prefixes.
    static func groupStem(_ name: String) -> (stem: String, team: String?) {
        var value = stem(name)
        if value.hasPrefix("group.") { value = String(value.dropFirst(6)) }
        let parts = value.split(separator: ".", maxSplits: 1)
        if parts.count == 2, isTeamPrefix(parts[0]) {
            return (String(parts[1]), String(parts[0]))
        }
        return (value, nil)
    }

    /// Does `candidate` (an entry stem) belong to `id`? Exact or `id.<more>`.
    static func belongs(_ candidate: String, to id: String) -> Bool {
        let c = candidate.lowercased(), i = id.lowercased()
        return c == i || c.hasPrefix(i + ".")
    }

    /// How `candidate` relates to `id`: the same ID, or a longer one
    /// (`<id>.<more>`). Whether a longer ID is the app's own data or a
    /// separate product is decided by asking the system (`isOtherApp`), not
    /// by a list of known suffixes.
    enum Relation { case exact, longer }

    static func relation(_ candidate: String, to id: String) -> Relation? {
        let c = candidate.lowercased(), i = id.lowercased()
        if c == i { return .exact }
        return c.hasPrefix(i + ".") ? .longer : nil
    }

    // MARK: Leftovers of an installed app

    /// Every user-library leftover of an app, used by uninstall and reset.
    public static func find(
        for identity: AppIdentity,
        appName: String,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default,
        isOtherApp: @Sendable (String) -> Bool = { SystemRegistry.shared.isRegisteredApp($0) }
    ) -> [Artifact] {
        var out: [Artifact] = []
        var seen = Set<String>()
        for location in userLocations {
            let dir = home.appendingPathComponent(location.relative)
            guard let entries = try? fileManager.contentsOfDirectory(atPath: dir.path) else { continue }
            for entry in entries {
                guard let reason = match(entry, in: dir, location: location, identity: identity, isOtherApp: isOtherApp) else { continue }
                let path = dir.appendingPathComponent(entry).path
                guard seen.insert(path).inserted else { continue }
                // Name-only matches are listed but never pre-selected.
                let auto = location.autoselect && reason != .name
                if let artifact = ArtifactBuilder.make(
                    path: path,
                    allowedRoot: dir.path,
                    group: location.title,
                    detail: "\(appName) · \(reason.text)",
                    risk: .caution,
                    autoselect: auto,
                    fileManager: fileManager
                ) {
                    out.append(artifact)
                }
            }
        }
        return removeNested(out)
    }

    /// Drops items that sit inside another item of the same list.
    static func removeNested(_ items: [Artifact]) -> [Artifact] {
        let paths = Set(items.map(\.path))
        return items.filter { item in
            var current = (item.path as NSString).deletingLastPathComponent
            while current.count > 1 {
                if paths.contains(current) { return false }
                current = (current as NSString).deletingLastPathComponent
            }
            return true
        }
    }

    enum MatchReason: Equatable {
        case bundleID, helperID, name, crashReport, plugin
        var text: String {
            switch self {
            case .bundleID: return "named after its bundle ID"
            case .helperID: return "named after an embedded helper or extension"
            case .name: return "named after the app"
            case .crashReport: return "crash or hang report"
            case .plugin: return "plug-in installed by the app"
            }
        }
    }

    /// Matches an entry stem against the app's IDs. A longer ID belongs to the
    /// app unless the system has a different app registered under it (e.g.
    /// `com.vendor.app.lite` installed next to `com.vendor.app`).
    static func idReason(_ stem: String, identity: AppIdentity, isOtherApp: (String) -> Bool) -> MatchReason? {
        var best: MatchReason?
        for (index, id) in identity.bundleIDs.enumerated() {
            guard let rel = relation(stem, to: id) else { continue }
            let reason: MatchReason = index == 0 ? .bundleID : .helperID
            if rel == .exact { return reason }
            if best == nil || (best == .helperID && reason == .bundleID) { best = reason }
        }
        guard let best else { return nil }
        // The longest prefix that is a registered app of its own wins.
        let own = Set(identity.bundleIDs.map { $0.lowercased() })
        var comps = stem.split(separator: ".").map(String.init)
        while comps.count > 2 {
            let candidate = comps.joined(separator: ".")
            if own.contains(candidate.lowercased()) { break }
            if isOtherApp(candidate) { return nil }
            comps.removeLast()
        }
        return best
    }

    static func match(_ entry: String, in dir: URL, location: LeftoverLocation, identity: AppIdentity, isOtherApp: (String) -> Bool = { _ in false }) -> MatchReason? {
        guard !entry.hasPrefix(".") else { return nil }
        for naming in location.naming {
            switch naming {
            case .bundleID, .groupContainer:
                let s = naming == .groupContainer ? groupStem(entry).stem : stem(entry)
                if let reason = idReason(s, identity: identity, isOtherApp: isOtherApp) { return reason }
                // Team-prefixed containers (`UBF8T346G9.Office`) are shared by the
                // developer's other apps and are only matched through the ID above.
            case .name:
                if identity.names.contains(where: { $0.caseInsensitiveCompare(entry) == .orderedSame }) { return .name }
            case .crashReport:
                guard let exe = identity.executable, exe.count >= 3 else { continue }
                let lower = entry.lowercased(), e = exe.lowercased()
                let isReport = ["ips", "crash", "diag", "spin", "hang", "plist", "cpu_resource"].contains((entry as NSString).pathExtension.lowercased())
                if isReport, lower.hasPrefix(e + "_") || lower.hasPrefix(e + "-") || lower.hasPrefix(e + ".") { return .crashReport }
            case .bundleInside:
                let plist = dir.appendingPathComponent(entry).appendingPathComponent("Contents/Info.plist")
                if let id = PlistReader.string("CFBundleIdentifier", in: PlistReader.dictionary(at: plist) ?? [:]),
                   identity.bundleIDs.contains(where: { belongs(id, to: $0) }) {
                    return .plugin
                }
            case .launchItem, .helperTool:
                continue // handled by the uninstaller's own launchd matching
            }
        }
        return nil
    }

    // MARK: Leftovers of removed apps

    /// Finds leftovers whose owning app is no longer installed, grouped per app.
    /// - Parameters:
    ///   - installedIDs: bundle IDs of every installed and running app (and their helpers).
    ///   - isInstalled: extra lookup (Launch Services) for IDs not in `installedIDs`.
    public static func orphans(
        installedIDs: Set<String>,
        isInstalled: @Sendable (String) -> Bool = { SystemRegistry.shared.isRegisteredApp($0) },
        includeSystem: Bool = true,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default,
        now: Date = Date()
    ) -> [LeftoverGroup] {
        let known = Set(installedIDs.map { $0.lowercased() })
        let labels = Set(SystemRegistry.shared.liveLaunchLabels(home: home).map { $0.lowercased() })
        let osVendors = SystemRegistry.shared.osNamespaces()
        let knownVendors = Set(known.map(vendor).filter { !sharedNamespaces.contains($0) })
        let trashed = trashedApps(home: home, fileManager: fileManager)

        func ownedByInstalled(_ id: String) -> Bool {
            let lower = id.lowercased()
            if known.contains(lower) { return true }
            if osVendors.contains(vendor(id)) { return true }
            if known.contains(where: { lower.hasPrefix($0 + ".") || $0.hasPrefix(lower + ".") }) { return true }
            if labels.contains(lower) || labels.contains(where: { $0.hasPrefix(lower + ".") }) { return true }
            // `com.vendor.app.helper` data is owned if `com.vendor.app` is registered.
            var comps = id.split(separator: ".").map(String.init)
            while comps.count >= 2 {
                if isInstalled(comps.joined(separator: ".")) { return true }
                comps.removeLast()
                if comps.count == 2 { break }
            }
            return false
        }

        // 1. Collect candidate entries keyed by inferred bundle ID.
        typealias Entry = (path: String, root: String, location: LeftoverLocation, broken: Bool)
        var byID: [String: [Entry]] = [:]
        // Programs referenced by any system launch daemon (keeps their helper tools).
        var daemonPrograms = Set<String>()
        for dir in ["/Library/LaunchDaemons", "/Library/LaunchAgents"] {
            for entry in (try? fileManager.contentsOfDirectory(atPath: dir)) ?? [] where entry.hasSuffix(".plist") {
                daemonPrograms.formUnion(launchPrograms(PlistReader.dictionary(at: URL(fileURLWithPath: "\(dir)/\(entry)")) ?? [:]))
            }
        }
        for location in includeSystem ? userLocations + systemLocations : userLocations {
            let dir = directory(location, home: home)
            guard let entries = try? fileManager.contentsOfDirectory(atPath: dir.path) else { continue }
            for entry in entries where !entry.hasPrefix(".") {
                let path = dir.appendingPathComponent(entry).path
                if location.naming.contains(.launchItem) {
                    guard entry.hasSuffix(".plist") else { continue }
                    let plist = PlistReader.dictionary(at: URL(fileURLWithPath: path)) ?? [:]
                    let programs = launchPrograms(plist)
                    // Only a launch item whose program is gone is a leftover.
                    guard !programs.isEmpty, !programs.contains(where: { fileManager.fileExists(atPath: $0) }) else { continue }
                    let label = PlistReader.string("Label", in: plist) ?? stem(entry)
                    guard let id = candidateID(label, location: location), !ownedByInstalled(id) else { continue }
                    byID[id.lowercased(), default: []].append((path, dir.path, location, true))
                } else if location.naming.contains(.helperTool) {
                    guard !daemonPrograms.contains(path), let id = candidateID(entry, location: location), !ownedByInstalled(id) else { continue }
                    byID[id.lowercased(), default: []].append((path, dir.path, location, true))
                } else if location.naming.contains(where: { $0 == .bundleID || $0 == .groupContainer }) {
                    let raw = location.naming.contains(.groupContainer) ? groupStem(entry).stem : stem(entry)
                    guard let id = candidateID(raw, location: location), !ownedByInstalled(id) else { continue }
                    byID[id.lowercased(), default: []].append((path, dir.path, location, false))
                }
            }
        }

        // 2. Fold helper IDs (`com.foo.app.helper`) into their parent (`com.foo.app`).
        let sortedIDs = byID.keys.sorted { $0.count < $1.count }
        var parent: [String: String] = [:]
        for id in sortedIDs {
            if let root = sortedIDs.first(where: { $0 != id && id.hasPrefix($0 + ".") && parent[$0] == nil }) {
                parent[id] = root
            }
        }
        var merged: [String: [Entry]] = [:]
        for (id, entries) in byID { merged[parent[id] ?? id, default: []].append(contentsOf: entries) }

        // 3. Measure and score each group.
        let frozen = Array(merged)
        let box = LeftoverBox(count: frozen.count)
        DispatchQueue.concurrentPerform(iterations: frozen.count) { index in
            let (id, entries) = frozen[index]
            var seen = Set<String>()
            let items: [Artifact] = removeNested(entries.compactMap { entry in
                guard seen.insert(entry.path).inserted else { return nil }
                return ArtifactBuilder.make(path: entry.path, allowedRoot: entry.root, group: entry.location.title, detail: id, risk: .caution, autoselect: true, fileManager: .default)
            })
            guard !items.isEmpty else { return }
            let broken = entries.filter(\.broken).count
            let system = items.filter { $0.path.hasPrefix("/Library/") }.count
            let trashedApp = trashed[id]
            let vendorInstalled = knownVendors.contains(vendor(id))
            let distinct = Set(items.map(\.group))
            let newest = items.compactMap(\.modified).max()
            let idleDays = newest.map { Int(now.timeIntervalSince($0) / 86_400) }
            let strong: Set<String> = ["Sandbox container", "Application Support", "Saved state", "Preferences"]

            var reasons: [String] = []
            var score = 0
            if let trashedApp { reasons.append("The app is in the Trash (\((trashedApp as NSString).lastPathComponent))"); score += 3 }
            reasons.append("Found in \(distinct.count) location\(distinct.count == 1 ? "" : "s"): \(distinct.sorted().joined(separator: ", "))")
            if distinct.count >= 2 { score += 1 }
            if !distinct.isDisjoint(with: strong) { score += 1 }
            if let idleDays {
                reasons.append(idleDays == 0 ? "Modified today" : "Not modified for \(idleDays) day\(idleDays == 1 ? "" : "s")")
                if idleDays >= 30 { score += 1 }
                if idleDays < 2 { score -= 2 }
            }
            if broken > 0 {
                reasons.append("\(broken) launch item\(broken == 1 ? "" : "s") or helper tool\(broken == 1 ? "" : "s") point at a program that no longer exists")
                score += 2
            }
            if system > 0 {
                reasons.append("\(system) item\(system == 1 ? " is" : "s are") in /Library and may need administrator rights to remove")
            }
            if vendorInstalled {
                reasons.append("Another app from \(vendor(id)) is installed and may share this data")
                score -= 2
            }
            let confidence: LeftoverGroup.Confidence = score >= 3 ? .high : (score >= 1 ? .medium : .low)
            box.set(index, LeftoverGroup(
                appID: id,
                displayName: displayName(for: id, trashedApp: trashedApp, items: items),
                items: items.sorted { $0.bytes > $1.bytes },
                confidence: confidence,
                reasons: reasons,
                vendorInstalled: vendorInstalled,
                trashedApp: trashedApp
            ))
        }
        return box.values.sorted {
            if $0.confidence != $1.confidence { return $0.confidence > $1.confidence }
            return $0.bytes > $1.bytes
        }
    }

    /// A bundle-ID-shaped name, excluding Apple and MacLean's own data.
    static func candidateID(_ raw: String, location: LeftoverLocation) -> String? {
        let comps = raw.split(separator: ".", omittingEmptySubsequences: false)
        let minimum = location.relative.hasSuffix("Containers") ? 2 : 3
        guard comps.count >= minimum, comps.allSatisfy({ !$0.isEmpty }) else { return nil }
        guard let first = comps.first?.first, first.isLetter else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        guard raw.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        let lower = raw.lowercased()
        let blocked = ["com.apple.", "apple.", "systemgroup.", "group.com.apple.", "org.sparkle-project.", "com.crashlytics", "io.fabric.", "maclean"]
        if blocked.contains(where: { lower.hasPrefix($0) }) || lower.contains("maclean") { return nil }
        // Bare reverse-DNS vendor folders (com.google, org.mozilla) are shared.
        if comps.count == 2, !location.relative.hasSuffix("Containers") { return nil }
        // Sandbox containers of system services use UUID-like or numeric names.
        if comps.last?.allSatisfy({ $0.isNumber }) == true { return nil }
        // Rotated logs, backups and data files (`tool.log.1.gz`) are not IDs.
        let fileWords: Set<String> = ["log", "logs", "gz", "bz2", "xz", "zip", "txt", "tmp", "temp", "bak", "old", "json",
                                      "db", "sqlite", "lock", "pid", "plist", "csv", "out", "err", "crash", "ips", "dat"]
        if comps.dropFirst().contains(where: { fileWords.contains($0.lowercased()) || $0.allSatisfy(\.isNumber) }) { return nil }
        return raw
    }

    /// Bundle IDs of every app bundle on this Mac (and their embedded helpers):
    /// a walk of the Applications folders (nested folders included) plus a
    /// Spotlight query, so apps in subfolders, updaters inside Application
    /// Support and developer builds all count as installed.
    public static func installedBundleIDs(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default,
        useSpotlight: Bool = SystemRegistry.spotlightEnabled
    ) -> Set<String> {
        var bundles = Set<String>()
        for root in SystemRegistry.applicationRoots(home: home) {
            walkApps(URL(fileURLWithPath: root), depth: root.hasSuffix("Application Support") ? 4 : 3, into: &bundles, fileManager: fileManager)
        }
        if useSpotlight {
            let result = ProcessRunner.run("/usr/bin/mdfind", ["kMDItemContentType == 'com.apple.application-bundle'"], timeout: 30)
            if result.status == 0 {
                for line in result.stdout.split(separator: "\n") where !line.contains("/.Trash/") {
                    bundles.insert(String(line))
                }
            }
        }
        var ids = Set<String>()
        for path in bundles where !path.contains("/.Trash/") {
            let url = URL(fileURLWithPath: path)
            for id in bundleIDs(ofApp: url, fileManager: fileManager) { ids.insert(id) }
            ids.formUnion(AppIdentity.nestedBundleIDs(in: url, fileManager: fileManager))
        }
        return ids
    }

    /// Bundle IDs of a Mac app (`Contents/Info.plist`), an iOS app run through
    /// PlayCover (`Info.plist` at the root) or an iPhone app installed on
    /// Apple silicon (`Wrapper/*.app/Info.plist`).
    static func bundleIDs(ofApp url: URL, fileManager: FileManager) -> [String] {
        var plists = [url.appendingPathComponent("Contents/Info.plist"), url.appendingPathComponent("Info.plist")]
        let wrapper = url.appendingPathComponent("Wrapper")
        if let inner = try? fileManager.contentsOfDirectory(atPath: wrapper.path) {
            plists += inner.filter { $0.hasSuffix(".app") }.map { wrapper.appendingPathComponent($0).appendingPathComponent("Info.plist") }
        }
        return plists.compactMap { PlistReader.string("CFBundleIdentifier", in: PlistReader.dictionary(at: $0) ?? [:]) }
    }

    static func walkApps(_ dir: URL, depth: Int, into bundles: inout Set<String>, fileManager: FileManager) {
        guard depth > 0, let entries = try? fileManager.contentsOfDirectory(atPath: dir.path) else { return }
        for entry in entries where !entry.hasPrefix(".") {
            let url = dir.appendingPathComponent(entry)
            if entry.hasSuffix(".app") {
                bundles.insert(url.path)
            } else {
                var isDir: ObjCBool = false
                if fileManager.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue,
                   (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
                   !["bundle", "framework", "plugin", "appex", "xpc", "photoslibrary", "musiclibrary"].contains(url.pathExtension) {
                    walkApps(url, depth: depth - 1, into: &bundles, fileManager: fileManager)
                }
            }
        }
    }

    /// Reverse-DNS prefixes used by many unrelated developers (code hosts,
    /// frameworks, placeholder domains). They never identify one vendor.
    static let sharedNamespaces: Set<String> = [
        "com.github", "io.github", "com.gitlab", "io.gitlab", "org.github", "com.electron", "org.electron",
        "com.electronjs", "com.example", "com.company", "com.yourcompany", "org.example", "com.tauri", "dev.tauri",
        "com.flutter", "io.flutter", "org.qt-project", "com.unity3d", "com.unity", "org.python", "org.webkit",
        "com.apple", "local.oa", "com.mycompany", "com.facebook.react", "org.chromium",
    ]

    static func vendor(_ id: String) -> String {
        id.lowercased().split(separator: ".").prefix(2).joined(separator: ".")
    }

    /// Apps sitting in the Trash, by lowercased bundle ID.
    static func trashedApps(home: URL, fileManager: FileManager) -> [String: String] {
        let trash = home.appendingPathComponent(".Trash")
        guard let entries = try? fileManager.contentsOfDirectory(atPath: trash.path) else { return [:] }
        var out: [String: String] = [:]
        for entry in entries where entry.hasSuffix(".app") {
            let path = trash.appendingPathComponent(entry).path
            for id in bundleIDs(ofApp: URL(fileURLWithPath: path), fileManager: fileManager) { out[id.lowercased()] = path }
        }
        return out
    }

    static func displayName(for id: String, trashedApp: String?, items: [Artifact]) -> String {
        if let trashedApp { return ((trashedApp as NSString).lastPathComponent as NSString).deletingPathExtension }
        // Sandbox containers record the app's display name.
        for item in items where item.group == "Sandbox container" {
            let meta = URL(fileURLWithPath: item.path).appendingPathComponent(".com.apple.containermanagerd.metadata.plist")
            if let dict = PlistReader.dictionary(at: meta),
               let inner = dict["MCMMetadataInfo"] as? [String: Any],
               let name = inner["CFBundleDisplayName"] as? String ?? inner["CFBundleName"] as? String, !name.isEmpty {
                return name
            }
        }
        // Preferences often record the app's name.
        for item in items where item.group == "Preferences" {
            if let dict = PlistReader.dictionary(at: URL(fileURLWithPath: item.path)),
               let name = (dict["CFBundleName"] ?? dict["AppName"] ?? dict["ApplicationName"]) as? String,
               name.count >= 2, name.count <= 40 {
                return name
            }
        }
        let comps = id.split(separator: ".").map(String.init)
        let generic: Set<String> = ["app", "desktop", "mac", "macos", "osx", "client", "application", "main", "electron", "ios", "global", "dev", "beta", "release", "stable", "helper", "launcher", "preview"]
        var words: [String] = []
        if let last = comps.last {
            var index = comps.count - 1
            // Skip generic tails: `com.figma.desktop` → Figma, `com.openai.chat` → Openai Chat.
            while index > 0, generic.contains(comps[index].lowercased()) { index -= 1 }
            var core = comps[index]
            if index > 0, core.count <= 2 { core = comps[index - 1] } // `jan.ai.app` → Jan
            words.append(core)
            if index != comps.count - 1, !generic.contains(last.lowercased()) { words.append(last) }
        }
        let spaced = words.joined(separator: " ").replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        var out = ""
        for (i, ch) in spaced.enumerated() {
            if i > 0, ch.isUppercase, let prev = out.last, prev.isLowercase { out.append(" ") }
            out.append(ch)
        }
        return out.prefix(1).uppercased() + out.dropFirst()
    }
}

private final class LeftoverBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [LeftoverGroup?]
    init(count: Int) { storage = Array(repeating: nil, count: count) }
    func set(_ index: Int, _ value: LeftoverGroup) { lock.lock(); storage[index] = value; lock.unlock() }
    var values: [LeftoverGroup] { lock.lock(); defer { lock.unlock() }; return storage.compactMap { $0 } }
}

extension LeftoverLocation.Naming: Equatable {}
