import Foundation

/// Where a resolved rule came from.
public enum RuleOrigin: String, Codable, Sendable {
    case bundled
    case edited
    case custom
}

/// User changes layered on top of a bundled rule. `nil` keeps the bundled value.
public struct RuleOverride: Codable, Sendable, Equatable {
    public var enabled: Bool?
    public var title: String?
    public var risk: Risk?
    public var autoselect: Bool?
    public var excludes: [String]?
    public var olderThanDays: Int?

    public init(
        enabled: Bool? = nil,
        title: String? = nil,
        risk: Risk? = nil,
        autoselect: Bool? = nil,
        excludes: [String]? = nil,
        olderThanDays: Int? = nil
    ) {
        self.enabled = enabled
        self.title = title
        self.risk = risk
        self.autoselect = autoselect
        self.excludes = excludes
        self.olderThanDays = olderThanDays
    }

    public var isEmpty: Bool {
        enabled == nil && title == nil && risk == nil && autoselect == nil && excludes == nil && olderThanDays == nil
    }
}

public enum CustomRuleMode: String, Codable, CaseIterable, Sendable {
    case contents
    case whole
    case largeFiles

    public var title: String {
        switch self {
        case .contents: return "Each entry inside the folder"
        case .whole: return "The folder as a whole"
        case .largeFiles: return "Large files inside (report only)"
        }
    }
}

/// A rule the user defined. Always home-relative, never needs root.
public struct CustomRule: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var category: JunkCategory
    /// Path relative to the home folder, e.g. `Library/Caches/com.example.app`.
    public var relativePath: String
    public var mode: CustomRuleMode
    public var olderThanDays: Int?
    public var excludes: [String]
    public var risk: Risk
    public var autoselect: Bool
    public var enabled: Bool
    public var created: Date

    public init(
        id: String = "custom-" + UUID().uuidString.prefix(8).lowercased(),
        title: String = "",
        category: JunkCategory = .system,
        relativePath: String = "",
        mode: CustomRuleMode = .contents,
        olderThanDays: Int? = nil,
        excludes: [String] = [],
        risk: Risk = .caution,
        autoselect: Bool = false,
        enabled: Bool = true,
        created: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.category = category
        self.relativePath = relativePath
        self.mode = mode
        self.olderThanDays = olderThanDays
        self.excludes = excludes
        self.risk = risk
        self.autoselect = autoselect
        self.enabled = enabled
        self.created = created
    }

    func junkRule() -> JunkRule {
        let mode: RuleMode
        switch self.mode {
        case .contents: mode = .contents
        case .whole: mode = .whole
        case .largeFiles: mode = .largeFiles(olderThanDays: olderThanDays)
        }
        return JunkRule(
            id: id,
            title: title,
            category: category,
            location: .home(relativePath),
            mode: mode,
            excludes: excludes,
            risk: risk,
            autoselect: self.mode == .largeFiles ? false : autoselect,
            requiresRoot: false,
            scanOnly: self.mode == .largeFiles,
            origin: .custom
        )
    }
}

public enum RuleBookError: LocalizedError, Equatable {
    case emptyTitle
    case emptyPath
    case outsideHome(String)
    case protectedLocation(String)
    case tooShallow(String)
    case duplicateID(String)
    case unknownRule(String)
    case badFile(String)

    public var errorDescription: String? {
        switch self {
        case .emptyTitle: return "Give the rule a name."
        case .emptyPath: return "Choose a folder for the rule."
        case .outsideHome(let path): return "\(path) is outside your home folder. Custom rules can only target folders inside your home folder."
        case .protectedLocation(let path): return "\(path) is a protected location (personal data, keychains, mail, cloud documents or a top-level folder) and cannot be cleaned by a custom rule."
        case .tooShallow(let path): return "\(path) is too close to your home folder for this mode. Pick a more specific subfolder."
        case .duplicateID(let id): return "A rule with id \(id) already exists."
        case .unknownRule(let id): return "No rule with id \(id)."
        case .badFile(let reason): return "The rules file could not be read: \(reason)"
        }
    }
}

/// Persistent store of rule edits and custom rules, shared by the app and the CLI.
/// Stored at `~/Library/Application Support/MacLean/rules.json`
/// (override with `MACLEAN_RULES_FILE`).
public final class RuleBook: @unchecked Sendable {
    public struct File: Codable, Sendable, Equatable {
        public var version: Int = 1
        public var overrides: [String: RuleOverride] = [:]
        public var custom: [CustomRule] = []
        public init() {}
    }

    public static let shared = RuleBook()

    public let url: URL
    private let lock = NSLock()
    private var file: File
    private var cache: [JunkRule]?

    public init(url: URL? = nil) {
        if let url {
            self.url = url
        } else if let env = ProcessInfo.processInfo.environment["MACLEAN_RULES_FILE"], !env.isEmpty {
            self.url = URL(fileURLWithPath: (env as NSString).expandingTildeInPath)
        } else {
            self.url = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/MacLean/rules.json")
        }
        self.file = Self.read(self.url) ?? File()
    }

    private static func read(_ url: URL) -> File? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(File.self, from: data)
    }

    // MARK: Reading

    public var snapshot: File {
        lock.lock(); defer { lock.unlock() }
        return file
    }

    public var customRules: [CustomRule] { snapshot.custom }

    public func override(for id: String) -> RuleOverride? {
        snapshot.overrides[id]
    }

    public func isEnabled(_ id: String) -> Bool {
        let state = snapshot
        if let custom = state.custom.first(where: { $0.id == id }) { return custom.enabled }
        return state.overrides[id]?.enabled ?? true
    }

    public func isCustom(_ id: String) -> Bool {
        snapshot.custom.contains { $0.id == id }
    }

    public func bundled(id: String) -> JunkRule? {
        Rules.bundled.first { $0.id == id }
    }

    /// Every rule with edits applied, including disabled ones.
    public func resolvedRules() -> [JunkRule] {
        lock.lock(); defer { lock.unlock() }
        if let cache { return cache }
        let resolved = Rules.bundled.map { Self.apply(file.overrides[$0.id], to: $0) }
            + file.custom.map { $0.junkRule() }
        cache = resolved
        return resolved
    }

    /// Rules the scanner runs: resolved and enabled.
    public func activeRules() -> [JunkRule] {
        let state = snapshot
        return resolvedRules().filter { rule in
            if let custom = state.custom.first(where: { $0.id == rule.id }) { return custom.enabled }
            return state.overrides[rule.id]?.enabled ?? true
        }
    }

    public static func apply(_ override: RuleOverride?, to rule: JunkRule) -> JunkRule {
        guard let override, !override.isEmpty else { return rule }
        var mode = rule.mode
        if case .largeFiles = rule.mode, let days = override.olderThanDays {
            mode = .largeFiles(olderThanDays: days > 0 ? days : nil)
        }
        let isOnlyToggle = override.title == nil && override.risk == nil && override.autoselect == nil
            && override.excludes == nil && override.olderThanDays == nil
        return JunkRule(
            id: rule.id,
            title: override.title.flatMap { $0.isEmpty ? nil : $0 } ?? rule.title,
            category: rule.category,
            location: rule.location,
            mode: mode,
            excludes: override.excludes ?? rule.excludes,
            risk: override.risk ?? rule.risk,
            autoselect: rule.scanOnly ? rule.autoselect : (override.autoselect ?? rule.autoselect),
            requiresRoot: rule.requiresRoot,
            scanOnly: rule.scanOnly,
            origin: isOnlyToggle ? .bundled : .edited
        )
    }

    // MARK: Writing

    public func setOverride(_ override: RuleOverride?, for id: String) throws {
        guard bundled(id: id) != nil else { throw RuleBookError.unknownRule(id) }
        try mutate { file in
            if let override, !override.isEmpty {
                file.overrides[id] = override
            } else {
                file.overrides[id] = nil
            }
        }
    }

    public func setEnabled(_ enabled: Bool, for id: String) throws {
        if isCustom(id) {
            try mutate { file in
                if let index = file.custom.firstIndex(where: { $0.id == id }) { file.custom[index].enabled = enabled }
            }
        } else {
            var current = override(for: id) ?? RuleOverride()
            current.enabled = enabled ? nil : false
            try setOverride(current, for: id)
        }
    }

    /// Adds or replaces a custom rule after validating it.
    public func upsert(_ rule: CustomRule, home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        var rule = rule
        rule.title = rule.title.trimmingCharacters(in: .whitespacesAndNewlines)
        rule.relativePath = try Self.validate(rule, home: home)
        rule.excludes = rule.excludes.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if Rules.bundled.contains(where: { $0.id == rule.id }) { throw RuleBookError.duplicateID(rule.id) }
        try mutate { file in
            if let index = file.custom.firstIndex(where: { $0.id == rule.id }) {
                file.custom[index] = rule
            } else {
                file.custom.append(rule)
            }
        }
    }

    public func deleteCustom(id: String) throws {
        guard isCustom(id) else { throw RuleBookError.unknownRule(id) }
        try mutate { $0.custom.removeAll { $0.id == id } }
    }

    public func resetOverrides() throws {
        try mutate { $0.overrides = [:] }
    }

    public func resetAll() throws {
        try mutate { $0 = File() }
    }

    public func reload() {
        lock.lock()
        file = Self.read(url) ?? File()
        cache = nil
        lock.unlock()
    }

    public func exportData() throws -> Data {
        try Self.encode(snapshot)
    }

    /// Replaces the rule book with an exported file. Every custom rule is validated.
    public func importData(_ data: Data, home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let incoming: File
        do {
            incoming = try decoder.decode(File.self, from: data)
        } catch {
            throw RuleBookError.badFile(error.localizedDescription)
        }
        var cleaned = File()
        cleaned.overrides = incoming.overrides.filter { id, _ in Rules.bundled.contains { $0.id == id } }
        for var rule in incoming.custom {
            rule.relativePath = try Self.validate(rule, home: home)
            cleaned.custom.append(rule)
        }
        try mutate { $0 = cleaned }
    }

    private func mutate(_ change: (inout File) -> Void) throws {
        lock.lock()
        var next = file
        change(&next)
        let data: Data
        do {
            data = try Self.encode(next)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            lock.unlock()
            throw error
        }
        file = next
        cache = nil
        lock.unlock()
    }

    private static func encode(_ file: File) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(file)
    }

    // MARK: Validation

    /// Folders a custom rule may never target (relative to home).
    static let protectedExact: Set<String> = [
        "", "Library", "Library/Application Support", "Library/Containers", "Library/Group Containers",
        "Library/Caches", "Library/Logs", "Library/Preferences", "Library/Developer",
        "Documents", "Desktop", "Downloads", "Pictures", "Music", "Movies", "Public", "Applications",
        "Library/CloudStorage", "Library/Mobile Documents",
    ]

    /// Subtrees a custom rule may never touch (relative to home).
    static let protectedPrefixes: [String] = [
        "Library/Keychains", "Library/Mail", "Library/Messages", "Library/Mobile Documents",
        "Library/CloudStorage", "Library/Preferences", "Library/Accounts", "Library/Cookies",
        "Library/Safari", "Library/Calendars", "Library/Reminders", "Library/Photos",
        "Library/IdentityServices", "Library/Application Support/AddressBook",
        "Library/Application Support/MacLean", "Pictures/Photos Library.photoslibrary",
        ".ssh", ".gnupg", ".aws", ".kube", ".config/gcloud", ".Trash",
    ]

    /// Normalises a user-entered path (absolute, `~/…`, or home-relative) into a
    /// home-relative path and rejects anything outside home or protected.
    public static func normalize(_ input: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw RuleBookError.emptyPath }
        let homePath = PathCanon.resolve(home.standardizedFileURL.path)
        var absolute: String
        if trimmed.hasPrefix("~") {
            absolute = home.path + String(trimmed.dropFirst())
        } else if trimmed.hasPrefix("/") {
            absolute = trimmed
        } else {
            absolute = home.appendingPathComponent(trimmed).path
        }
        if absolute.contains("/../") || absolute.hasSuffix("/..") { throw RuleBookError.outsideHome(trimmed) }
        absolute = URL(fileURLWithPath: absolute).standardizedFileURL.path
        // Resolve symlinks when the path exists so a link cannot escape home.
        let canonical = FileManager.default.fileExists(atPath: absolute) ? PathCanon.resolve(absolute) : absolute
        let rawHome = home.standardizedFileURL.path
        let relative: String
        if canonical == homePath || canonical == rawHome {
            relative = ""
        } else if canonical.hasPrefix(homePath + "/") {
            relative = String(canonical.dropFirst(homePath.count + 1))
        } else if canonical.hasPrefix(rawHome + "/") {
            relative = String(canonical.dropFirst(rawHome.count + 1))
        } else {
            throw RuleBookError.outsideHome(trimmed)
        }
        return relative.hasSuffix("/") ? String(relative.dropLast()) : relative
    }

    /// Validates a custom rule and returns its normalised home-relative path.
    public static func validate(_ rule: CustomRule, home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> String {
        guard !rule.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RuleBookError.emptyTitle }
        let relative = try normalize(rule.relativePath, home: home)
        let display = "~/" + relative
        let lower = relative.lowercased()
        if protectedPrefixes.contains(where: { lower == $0.lowercased() || lower.hasPrefix($0.lowercased() + "/") }) {
            throw RuleBookError.protectedLocation(display)
        }
        if rule.mode != .largeFiles, protectedExact.contains(where: { $0.lowercased() == lower }) {
            throw RuleBookError.protectedLocation(display)
        }
        let depth = relative.split(separator: "/").count
        switch rule.mode {
        case .largeFiles:
            if depth < 1 { throw RuleBookError.tooShallow(display) }
        case .contents:
            // One level is allowed only for dot-folders such as ~/.npm or ~/.gradle.
            if depth < 2, !(depth == 1 && relative.hasPrefix(".")) { throw RuleBookError.tooShallow(display) }
        case .whole:
            if depth < 2 { throw RuleBookError.tooShallow(display) }
        }
        return relative
    }
}
